"""P1-24 认证 smoke：登录成功/失败、/me 身份解析、未带 token 的 401。"""


def test_login_admin_ok(client):
    r = client.post("/api/auth/login", json={"username": "admin", "password": "admin123"})
    assert r.status_code == 200
    data = r.json()
    assert data["access_token"]
    assert data["user"]["username"] == "admin"


def test_login_bad_password_401(client):
    r = client.post("/api/auth/login", json={"username": "admin", "password": "wrong-pass"})
    assert r.status_code == 401


def test_me_with_token(client):
    login = client.post("/api/auth/login", json={"username": "admin", "password": "admin123"}).json()
    r = client.get("/api/auth/me", headers={"Authorization": f"Bearer {login['access_token']}"})
    assert r.status_code == 200
    data = r.json()
    assert data["username"] == "admin"
    # role=admin 已被 seed_identities 归到 dev_admin 身份 → 全量权限点（含 system）
    assert "system" in data["permissions"]
    assert data["llm_access"] == "admin"


def test_me_without_token_401(client):
    assert client.get("/api/auth/me").status_code == 401


def test_chatbi_route_without_token_401(client):
    # deps.get_current_user 路径：AUTH_ENABLED=true 时未带 token 直接 401（不匿名回落）
    r = client.get("/api/admin/sqls")
    assert r.status_code == 401
