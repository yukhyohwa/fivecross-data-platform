"""P1-16 /api/admin/versions + /diff 端点级覆盖（对抗审查 LOW 补测）：
列表/diff 正常透传、版本缺失 404、非法名/版本名 400、个人级归属 403（本人 200）、未登录 401。"""
import json

from backend.ide_app.core.auth import create_token
from analysis import sql_store, versioning
from analysis.games import owner_key


def _token(seeded, name="admin"):
    access, _, _ = create_token(seeded[name]["id"])
    return {"Authorization": f"Bearer {access}"}


def _setup_sql(tmp_path, monkeypatch):
    """把 SQL 存储与版本目录指到 tmp：a.sql 当前内容两行，历史版本只有一行。"""
    sql_dir = tmp_path / "sql"
    sql_dir.mkdir()
    (sql_dir / "a.sql").write_text("SELECT 1;\nSELECT 2;\n", encoding="utf-8")
    vdir = tmp_path / "_versions" / "sql" / "a.sql"
    vdir.mkdir(parents=True)
    (vdir / "20260101_000000_abc123.sql").write_text("SELECT 1;\n", encoding="utf-8")
    monkeypatch.setattr(sql_store, "SQL_DIR", sql_dir)
    monkeypatch.setattr(versioning, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(versioning, "VERSIONS_DIR", tmp_path / "_versions")
    return sql_dir


def test_versions_no_auth_401(client, tmp_path, monkeypatch):
    _setup_sql(tmp_path, monkeypatch)
    r = client.get("/api/admin/versions", params={"kind": "sql", "name": "a.sql"})
    assert r.status_code == 401


def test_versions_list_and_diff(client, seeded, tmp_path, monkeypatch):
    _setup_sql(tmp_path, monkeypatch)
    h = _token(seeded)
    r = client.get("/api/admin/versions", params={"kind": "sql", "name": "a.sql"}, headers=h)
    assert r.status_code == 200
    assert [v["file"] for v in r.json()["versions"]] == ["20260101_000000_abc123.sql"]

    r = client.get("/api/admin/versions/diff",
                   params={"kind": "sql", "name": "a.sql", "version_file": "20260101_000000_abc123.sql"}, headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["truncated"] is False
    assert "+SELECT 2;" in body["diff"]  # + 行 = 当前；历史版本只有 SELECT 1


def test_versions_diff_missing_version_404(client, seeded, tmp_path, monkeypatch):
    _setup_sql(tmp_path, monkeypatch)
    r = client.get("/api/admin/versions/diff",
                   params={"kind": "sql", "name": "a.sql", "version_file": "nope.sql"},
                   headers=_token(seeded))
    assert r.status_code == 404


def test_versions_diff_traversal_names_400(client, seeded, tmp_path, monkeypatch):
    _setup_sql(tmp_path, monkeypatch)
    h = _token(seeded)
    # 工件名穿越 → 400
    r = client.get("/api/admin/versions/diff",
                   params={"kind": "sql", "name": "../evil", "version_file": "x.sql"}, headers=h)
    assert r.status_code == 400
    # 版本文件名带目录成分 → 400
    r = client.get("/api/admin/versions/diff",
                   params={"kind": "sql", "name": "a.sql", "version_file": "../evil.sql"}, headers=h)
    assert r.status_code == 400
    # 未知工件类型 → 400
    r = client.get("/api/admin/versions/diff",
                   params={"kind": "nope", "name": "a", "version_file": "x.sql"}, headers=h)
    assert r.status_code == 400


def test_versions_ownership_personal_403(client, seeded, tmp_path, monkeypatch):
    """「个人」级 SQL：非归属人（含 admin）看版本 → 403；归属人本人 → 200。"""
    sql_dir = _setup_sql(tmp_path, monkeypatch)
    owner = owner_key(seeded["alice"])
    (sql_dir / "a.sql.json").write_text(
        json.dumps({"level": "个人", "owner": owner}, ensure_ascii=False), encoding="utf-8")

    r = client.get("/api/admin/versions", params={"kind": "sql", "name": "a.sql"}, headers=_token(seeded, "admin"))
    assert r.status_code == 403
    r = client.get("/api/admin/versions", params={"kind": "sql", "name": "a.sql"}, headers=_token(seeded, "alice"))
    assert r.status_code == 200
