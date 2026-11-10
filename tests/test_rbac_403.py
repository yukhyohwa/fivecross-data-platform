"""P1-24 RBAC smoke：普通用户越权 403（写入口 + 管理端点）。"""


def _login(client, username, password):
    return client.post("/api/auth/login", json={"username": username, "password": password}).json()["access_token"]


def test_user_cannot_save_sql(client):
    token = _login(client, "alice", "alice123")
    r = client.post(
        "/api/admin/sqls/%E6%B5%8B%E8%AF%95",  # URL 编码的「测试」
        json={"sql": "SELECT 1"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 403


def test_user_cannot_delete_sql(client):
    token = _login(client, "alice", "alice123")
    r = client.request("DELETE", "/api/admin/sqls/x", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 403


def test_user_cannot_list_users(client):
    token = _login(client, "alice", "alice123")
    r = client.get("/api/auth/users", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 403
