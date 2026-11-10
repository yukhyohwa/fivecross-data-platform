"""P2-4 复核：权限点清单端点与保存过滤（_clean_points 挡住已删除的孤儿权限点回写）。"""


def _login(client, username, password):
    return client.post("/api/auth/login", json={"username": username, "password": password}).json()["access_token"]


def test_permission_points_endpoint_has_no_orphans(client):
    """GET /api/permissions/points 返回后端真实清单，不含 personal/workspace 孤儿点。"""
    token = _login(client, "alice", "alice123")
    r = client.get("/api/permissions/points", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    points = r.json()["points"]
    assert "personal" not in points and "workspace" not in points
    assert {"apps", "analysis", "ai", "system", "analysis_edit", "analysis_delete"} <= set(points)


def test_permission_points_open_to_logged_in_user(client):
    """清单端点只需登录（供前端三处清单统一消费），不要求 system 权限。"""
    token = _login(client, "alice", "alice123")
    r = client.get("/api/permissions/points", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200


def test_clean_points_filters_unknown_and_dedups():
    from backend.ide_app.api.permissions_api import _clean_points

    out = _clean_points(["system", "personal", "workspace", "system", "not-a-point"])
    assert out == ["system"]


def test_identity_save_strips_orphan_points(client):
    """创建身份时把 personal/workspace 过滤掉，残留键无法再写回 DB。"""
    from backend.ide_app.services import db_service

    token = _login(client, "admin", "admin123")
    r = client.post(
        "/api/permissions/identities",
        json={"key": "tmp_clean_test", "name": "临时", "permission_points": ["analysis", "personal"], "games": ["*"]},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200, r.text
    row = db_service.get_identity("tmp_clean_test")
    import json as _json

    assert "personal" not in _json.loads(row["permission_points"] or "[]")
    db_service.delete_identity("tmp_clean_test")
