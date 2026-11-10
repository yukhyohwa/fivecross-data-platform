"""RBAC「使用」权限点（sql_use/kb_use/skill_use/model_use）+ 资产机密档位（L1/L2/L3）。

口径（2026-10-29 用户拍板）：
- 四个使用点独立于 analysis_edit/delete（只管增删改），勾选了才能在聊天/深度分析/专项执行里取用。
- SQL/知识库/专项 各带单档位（L1 绝密 > L2 机密 > L3 秘密），授予是「多选集合」，
  资产档位命中集合即放行；未分级资产只查使用点。算法不分档。
- 关联/生成快照/刷新等内部保存不传档位时，保留既有档位，不静默清成未分级。
"""
import json

import pytest

from analysis import knowledge_store as ks
from analysis import versioning


# ── 纯逻辑：can_use_asset / effective_access_levels / normalize_confidentiality ──

def _mk_user(db, identity="default", extra_permissions="[]", extra_access_levels="{}", uid="u1"):
    """造一个指向某身份的用户 dict（identity 显式绑身份，extra_* 为 JSON 串）。"""
    return {
        "id": uid,
        "username": "u1",
        "identity": identity,
        "extra_permissions": extra_permissions,
        "extra_games": "[]",
        "extra_access_levels": extra_access_levels,
    }


def _upsert_identity(db, key, points, access_levels=None):
    from backend.ide_app.services import db_service

    db_service.upsert_identity(key, key, permission_points=points, games=["*"], access_levels=access_levels or {})


def test_can_use_asset_model_only_checks_model_use(app_env):
    from backend.ide_app.services import db_service, permissions

    _upsert_identity(db_service, "m_user", ["model_use"])
    u = _mk_user(db_service, identity="m_user")
    # model 无档位：只查 model_use，传任意档位都不影响
    assert permissions.can_use_asset(u, "model") is True
    assert permissions.can_use_asset(u, "model", "L1") is True

    _upsert_identity(db_service, "no_model", [])
    u2 = _mk_user(db_service, identity="no_model")
    assert permissions.can_use_asset(u2, "model") is False


def test_can_use_asset_sql_requires_use_point_and_level(app_env):
    from backend.ide_app.services import db_service, permissions

    # 只授 sql_use 但没设档 → 默认只有 L3（最低档）
    _upsert_identity(db_service, "sql_l3", ["sql_use"])
    u = _mk_user(db_service, identity="sql_l3")
    assert permissions.can_use_asset(u, "sql", None) is True      # 未分级不设限
    assert permissions.can_use_asset(u, "sql", "L3") is True      # 命中默认 L3
    assert permissions.can_use_asset(u, "sql", "L2") is False     # 越级
    assert permissions.can_use_asset(u, "sql", "L1") is False     # 越级

    # 授 sql_use + sql 档位 {L1, L2}
    _upsert_identity(db_service, "sql_l12", ["sql_use"], {"sql": ["L1", "L2"]})
    u2 = _mk_user(db_service, identity="sql_l12")
    assert permissions.can_use_asset(u2, "sql", "L1") is True
    assert permissions.can_use_asset(u2, "sql", "L2") is True
    assert permissions.can_use_asset(u2, "sql", "L3") is False    # 档位未授予

    # 有档但没 sql_use 点 → 一律拦
    _upsert_identity(db_service, "sql_nouse", [], {"sql": ["L1", "L2", "L3"]})
    u3 = _mk_user(db_service, identity="sql_nouse")
    assert permissions.can_use_asset(u3, "sql", "L1") is False


def test_can_use_asset_unknown_type_false(app_env):
    from backend.ide_app.services import db_service, permissions

    _upsert_identity(db_service, "all_use", ["sql_use", "kb_use", "skill_use", "model_use"])
    u = _mk_user(db_service, identity="all_use")
    assert permissions.can_use_asset(u, "bogus") is False


def test_effective_access_levels_default_L3_and_merge(app_env):
    from backend.ide_app.services import db_service, permissions

    # 身份没设档 → 默认 {"L3"}
    _upsert_identity(db_service, "no_lv", ["kb_use"])
    u = _mk_user(db_service, identity="no_lv")
    assert permissions.effective_access_levels(u, "kb") == {"L3"}

    # 身份 {skill:[L2]} ∪ 用户额外 {skill:[L1]} → {L1, L2}
    _upsert_identity(db_service, "mix_lv", ["skill_use"], {"skill": ["L2"]})
    u2 = _mk_user(db_service, identity="mix_lv", extra_access_levels=json.dumps({"skill": ["L1"]}))
    assert permissions.effective_access_levels(u2, "skill") == {"L1", "L2"}


def test_effective_access_levels_admin_and_anonymous_all(app_env):
    from backend.ide_app.services import db_service, permissions

    # 匿名回落 → 全档
    assert permissions.effective_access_levels(None, "sql") == set(permissions.CONFIDENTIALITY_LEVELS)
    assert permissions.effective_access_levels({"id": "anonymous"}, "sql") == set(permissions.CONFIDENTIALITY_LEVELS)

    # 持有 system 权限点（管理员）→ 全档
    _upsert_identity(db_service, "sys_user", ["system"])
    u = _mk_user(db_service, identity="sys_user")
    assert permissions.effective_access_levels(u, "sql") == set(permissions.CONFIDENTIALITY_LEVELS)

    # 算法不分档 → 空集
    assert permissions.effective_access_levels(u, "model") == set()


def test_normalize_confidentiality_and_clean_access_levels():
    from backend.ide_app.services.permissions import normalize_confidentiality, clean_access_levels

    assert normalize_confidentiality("L1") == "L1"
    assert normalize_confidentiality(" L2 ") == "L2"
    assert normalize_confidentiality("L4") is None
    assert normalize_confidentiality("") is None
    assert normalize_confidentiality(None) is None

    # 只保留三键 + 合法档位，去重保序
    assert clean_access_levels({"sql": ["L1", "L1", "L4"], "kb": ["L3"], "model": ["L1"], "zzz": ["L2"]}) == {
        "sql": ["L1"], "kb": ["L3"],
    }


# ── 文件系统隔离：重定向 knowledge_store / versioning，避免测试碰真实资产 ──

@pytest.fixture()
def asset_fs(tmp_path, monkeypatch):
    monkeypatch.setattr(versioning, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(versioning, "VERSIONS_DIR", tmp_path / "_versions")
    monkeypatch.setattr(ks, "SKILLS_DIR", tmp_path / "knowledge" / "skills")
    monkeypatch.setattr(ks, "DOCS_DIR", tmp_path / "knowledge" / "docs")
    ks.SKILLS_DIR.mkdir(parents=True, exist_ok=True)
    ks.DOCS_DIR.mkdir(parents=True, exist_ok=True)
    return tmp_path


def test_skill_and_doc_meta_roundtrip_confidentiality(asset_fs):
    ks.write_skill("x", "# x")
    ks.write_skill_meta("x", {"sqls": [], "level": "通用", "confidentiality": "L1"})
    assert ks.read_skill_meta("x")["confidentiality"] == "L1"

    ks.write_doc("d", "# d")
    ks.write_doc_meta("d", {"level": "通用", "confidentiality": "L2"})
    assert ks.read_doc_meta("d")["confidentiality"] == "L2"


# ── 保存端点：内部路径不传档位时保留既有档位（model_fields_set 口径） ──

def _game():
    return {"key": "kof", "name": "拳皇", "db": "kof"}


def test_save_skill_preserves_confidentiality_when_omitted(asset_fs, app_env):
    from backend.routers import skills as skills_router
    from backend.routers.skills import SkillSave

    user = {"id": "admin", "username": "admin", "identity": "dev_admin"}

    # 显式设 L1
    skills_router.save_skill("绝密专项", SkillSave(content="# 方法", level="通用", confidentiality="L1"), user, _game())
    assert ks.read_skill_meta("绝密专项")["confidentiality"] == "L1"

    # 关联/刷新路径：不传 confidentiality（body.model_fields_set 无该键）→ 保留 L1
    skills_router.save_skill("绝密专项", SkillSave(content="# 方法二", level="通用"), user, _game())
    assert ks.read_skill_meta("绝密专项")["confidentiality"] == "L1"

    # 显式清空（confidentiality=null）→ 落盘 None（未分级）
    skills_router.save_skill("绝密专项", SkillSave(content="# 方法三", level="通用", confidentiality=None), user, _game())
    assert ks.read_skill_meta("绝密专项")["confidentiality"] is None


def test_save_doc_preserves_confidentiality_when_omitted(asset_fs, app_env):
    from backend.routers import kb_admin
    from backend.routers.kb_admin import KbSave

    user = {"id": "admin", "username": "admin", "identity": "dev_admin"}

    kb_admin.save_kb("docs", "机密文档", KbSave(content="# 正文", level="通用", confidentiality="L2"), user, _game())
    assert ks.read_doc_meta("机密文档")["confidentiality"] == "L2"

    # 不传档位 → 保留 L2
    kb_admin.save_kb("docs", "机密文档", KbSave(content="# 正文二", level="通用"), user, _game())
    assert ks.read_doc_meta("机密文档")["confidentiality"] == "L2"

    # 显式清空 → None
    kb_admin.save_kb("docs", "机密文档", KbSave(content="# 正文三", level="通用", confidentiality=None), user, _game())
    assert ks.read_doc_meta("机密文档")["confidentiality"] is None


def test_list_docs_admin_returns_confidentiality(asset_fs, app_env):
    from backend.routers import kb_admin

    ks.write_doc("a", "# a")
    ks.write_doc_meta("a", {"level": "通用", "confidentiality": "L1"})
    ks.write_doc("b", "# b")
    ks.write_doc_meta("b", {"level": "通用"})  # 未分级

    r = kb_admin.list_docs_admin(game=_game())
    assert r["doc_confidentiality"] == {"a": "L1", "b": None}
    assert sorted(r["docs"]) == ["a", "b"]


# ── 多身份（2026-10-30）：users.identity 改为多选，权限/游戏/档位取并集 ──

def test_parse_identity_keys_legacy_and_list():
    from backend.ide_app.services.permissions import _parse_identity_keys

    assert _parse_identity_keys("dev_admin") == ["dev_admin"]  # 旧单 key 字符串
    assert _parse_identity_keys('["dev_admin","data_analysis"]') == ["dev_admin", "data_analysis"]
    assert _parse_identity_keys("[]") == []
    assert _parse_identity_keys("") == []
    assert _parse_identity_keys(None) == []


def test_multi_identity_union(app_env):
    from backend.ide_app.services import db_service, permissions

    db_service.upsert_identity("i1", "身份一", ["apps", "analysis"], ["kof"])
    db_service.upsert_identity("i2", "身份二", ["ai", "sql_use"], ["kof_sea"], access_levels={"sql": ["L2"]})
    u = _mk_user(db_service, identity=json.dumps(["i1", "i2"]))
    assert permissions.effective_permissions(u) == {"apps", "analysis", "ai", "sql_use"}
    assert permissions.effective_games(u) == ["kof", "kof_sea"]
    assert permissions.effective_access_levels(u, "sql") == {"L2"}
    v = permissions.user_perm_view(u)
    assert v["identity"] == ["i1", "i2"]
    assert v["identity_name"] == ["身份一", "身份二"]


def test_multi_identity_full_game_dominates(app_env):
    from backend.ide_app.services import db_service, permissions

    db_service.upsert_identity("full", "全游戏", ["apps"], ["*"])
    db_service.upsert_identity("custom", "自定义", ["ai"], ["kof"])
    u = _mk_user(db_service, identity=json.dumps(["full", "custom"]))
    assert permissions.effective_games(u) == ["*"]


def test_update_user_rbac_roundtrip_multi_identity(app_env):
    from backend.ide_app.services import db_service, permissions

    permissions.seed_identities()  # 种出 default 身份，才能断言空身份回落 default
    u = db_service.create_user("multi", "h")
    db_service.update_user_rbac(u["id"], ["dev_admin", "data_analysis"], [], [])
    row = db_service.get_user_by_id(u["id"])
    assert permissions._parse_identity_keys(row["identity"]) == ["dev_admin", "data_analysis"]

    # 旧前端传来的单 key 字符串（滚动部署期间）也能落成单元素列表
    db_service.update_user_rbac(u["id"], "dev_admin", [], [])
    row = db_service.get_user_by_id(u["id"])
    assert permissions._parse_identity_keys(row["identity"]) == ["dev_admin"]

    # 空列表 → 空身份（'' 哨兵）
    db_service.update_user_rbac(u["id"], [], [], [])
    row = db_service.get_user_by_id(u["id"])
    assert row["identity"] == ""
    assert permissions.resolve_identity(row)["key"] == "default"
