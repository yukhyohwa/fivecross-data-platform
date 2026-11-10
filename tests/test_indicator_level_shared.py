"""指标打通（层级共享，Option A）：来源 SQL 为 通用/项目 的派生指标跟随 SQL 层级对齐共享共建。

- 通用级来源 SQL → 全体用户可见（share_role=level、source_level=通用），持 analysis_edit 可共建；
- 项目级来源 SQL → 按游戏家族（family_key）同族可见，需传 game；
- 个人级来源 SQL / 无来源 / 来源文件缺失 → 保持 owner + 分享机制隔离。
"""
import pytest

from backend.ide_app.services import db_service
from backend.ide_app.services.db_service import _conn


def _uid(seeded, key: str) -> str:
    val = seeded[key]
    return val["id"] if isinstance(val, dict) else val


def _insert(uid: str, metric_id: str, name: str, source_sql: str = "", status: str = "draft") -> int:
    c = _conn()
    cur = c.execute(
        "INSERT INTO indicators (user_id, metric_id, metric_name, metric_alias, status,"
        " definition, canonical_sql, source_sql) VALUES (?,?,?,?,?,?,?,?)",
        (uid, metric_id, name, "", status, "", "SELECT 1", source_sql),
    )
    c.commit()
    return cur.lastrowid


@pytest.fixture()
def scopes(monkeypatch):
    """打桩 db_service._sql_scope：不触碰真实 SQL 目录。映射 {source_sql: (level, game)}。"""
    mapping = {"uni.sql": ("通用", None), "proj.sql": ("项目", "kof"), "priv.sql": ("个人", None)}
    monkeypatch.setattr(db_service, "_sql_scope", lambda name: mapping.get(name, (None, None)))
    return mapping


def _login(client, username: str, password: str) -> str:
    return client.post("/api/auth/login", json={"username": username, "password": password}).json()["access_token"]


def _game_stub(monkeypatch):
    """get_game 依赖打桩：resolve 直接回显传入 key，不依赖真实 games.json。"""
    import backend.services.games as games_svc
    monkeypatch.setattr(games_svc, "resolve",
                       lambda key, engine=None: {"key": (key or "").strip() or "rooc_am", "name": key or "rooc_am", "db": "pf_rooc_am"})


# ── db_service 层 ──

def test_universal_shared_visible_and_owner_tagged(scopes, seeded):
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(alice, "sql_uni_rev", "通用收入", source_sql="uni.sql")

    items, _ = db_service.list_indicators(admin)
    row = next(i for i in items if i.get("metric_id") == "sql_uni_rev")
    assert row["share_role"] == "level"
    assert row["source_level"] == "通用"
    assert row["my_permission"] == "write"  # admin=dev_admin 持 analysis_edit → 可共建

    own, _ = db_service.list_indicators(alice)
    mine = next(i for i in own if i.get("metric_id") == "sql_uni_rev")
    assert mine["share_role"] == "owner"
    assert mine["source_level"] == "通用"  # 本人持有的共享池指标也打层级标


def test_project_shared_family_filter(scopes, seeded):
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(alice, "sql_proj_dau", "项目DAU", source_sql="proj.sql")

    for game in ("kof", "kof_sea"):  # 同族互见
        items, _ = db_service.list_indicators(admin, game=game)
        assert any(i.get("metric_id") == "sql_proj_dau" for i in items)
    for game in ("ro_cn", "rooc_am"):  # 异族隔离
        items, _ = db_service.list_indicators(admin, game=game)
        assert not any(i.get("metric_id") == "sql_proj_dau" for i in items)
    items, _ = db_service.list_indicators(admin)  # 无 game 无法判家族 → 不并入（宁可隐藏）
    assert not any(i.get("metric_id") == "sql_proj_dau" for i in items)


def test_personal_and_missing_source_stay_isolated(scopes, seeded):
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(alice, "sql_priv_pay", "个人付费", source_sql="priv.sql")
    _insert(alice, "sql_gone_pay", "来源已删", source_sql="deleted.sql")

    items, _ = db_service.list_indicators(admin)
    mids = {i.get("metric_id") for i in items}
    assert "sql_priv_pay" not in mids
    assert "sql_gone_pay" not in mids  # 文件缺失 → 个人隔离兜底，不扩散可见性


def test_handmade_and_chat_indicators_unchanged(scopes, seeded):
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(alice, "ind_abc123", "手工指标")  # 无 source_sql
    _insert(alice, "ind_def456", "聊天生成", source_sql="")

    items, _ = db_service.list_indicators(admin)
    mids = {i.get("metric_id") for i in items}
    assert "ind_abc123" not in mids and "ind_def456" not in mids


def test_default_user_gets_read_permission_on_shared(scopes, seeded):
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(admin, "sql_uni_arpu", "全局ARPPU", source_sql="uni.sql")

    items, _ = db_service.list_indicators(alice)  # alice=default 身份，无 analysis_edit
    row = next(i for i in items if i.get("metric_id") == "sql_uni_arpu")
    assert row["share_role"] == "level"
    assert row["my_permission"] == "read"


def test_level_shared_domains_included(scopes, seeded):
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(alice, "sql_uni_gmv", "GMV", source_sql="uni.sql")
    c = _conn()
    c.execute("UPDATE indicators SET domain='商业化' WHERE metric_id='sql_uni_gmv'")
    c.commit()
    assert "商业化" in db_service.get_indicator_domains(admin)


# ── 路由层 ──

def test_update_level_shared_requires_analysis_edit(client, scopes, seeded, monkeypatch):
    _game_stub(monkeypatch)
    admin = _uid(seeded, "admin")
    ind_id = _insert(admin, "sql_uni_rev2", "共建指标", source_sql="uni.sql")
    alice_tok = _login(client, "alice", "alice123")
    admin_tok = _login(client, "admin", "admin123")

    # 普通用户（default 身份）无 analysis_edit → 403
    r = client.put(f"/api/indicators/{ind_id}", json={"metric_name": "改名字"},
                   headers={"Authorization": f"Bearer {alice_tok}"})
    assert r.status_code == 403
    # 管理员可共建修改
    r = client.put(f"/api/indicators/{ind_id}", json={"metric_name": "共建改名"},
                   headers={"Authorization": f"Bearer {admin_tok}"})
    assert r.status_code == 200
    assert r.json()["metric_name"] == "共建改名"


def test_delete_level_shared_requires_analysis_delete(client, scopes, seeded, monkeypatch):
    _game_stub(monkeypatch)
    admin = _uid(seeded, "admin")
    ind_id = _insert(admin, "sql_uni_rev3", "待删指标", source_sql="uni.sql")
    alice_tok = _login(client, "alice", "alice123")

    r = client.delete(f"/api/indicators/{ind_id}", headers={"Authorization": f"Bearer {alice_tok}"})
    assert r.status_code == 403


def test_list_endpoint_includes_level_shared(client, scopes, seeded, monkeypatch):
    _game_stub(monkeypatch)
    alice, admin = _uid(seeded, "alice"), _uid(seeded, "admin")
    _insert(admin, "sql_uni_rev4", "通用收入", source_sql="uni.sql")
    _insert(admin, "sql_proj_dau2", "项目DAU", source_sql="proj.sql")
    _insert(admin, "sql_priv_pay2", "个人付费", source_sql="priv.sql")
    tok = _login(client, "alice", "alice123")

    r = client.get("/api/indicators", params={"game": "kof"},
                   headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 200
    mids = {i.get("metric_id") for i in r.json()["items"]}
    assert "sql_uni_rev4" in mids      # 通用共享
    assert "sql_proj_dau2" in mids     # 项目同族（kof）
    assert "sql_priv_pay2" not in mids  # 个人隔离
    proj = next(i for i in r.json()["items"] if i.get("metric_id") == "sql_proj_dau2")
    assert proj["share_role"] == "level" and proj["source_level"] == "项目"
