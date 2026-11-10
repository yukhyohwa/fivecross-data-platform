"""P1-17 内部建号：公开注册已下线（405，根静态挂载兜底 + 路由表无该路径）；管理员建号端点
POST /api/auth/users 权限/校验/重复/可登录；DELETE /api/auth/users 删除套件；anonymous 占位行
永不参与登录（对抗审查 HIGH 修复）。"""
from backend.ide_app.core.auth import create_token


def _admin_auth(seeded):
    """进程内签发 admin 令牌（不依赖已知密码；与线上验证口径一致）。"""
    access, _, _ = create_token(seeded["admin"]["id"])
    return {"Authorization": f"Bearer {access}"}


def _seed_anonymous():
    """还原 ide_mount 的 anonymous FK 占位行（测试无 lifespan，ide_startup 不跑）。"""
    from backend.ide_app.core.auth import hash_password
    from backend.ide_app.services.db_service import _conn
    c = _conn()
    if not c.execute("SELECT id FROM users WHERE id='anonymous'").fetchone():
        c.execute(
            "INSERT INTO users (id, username, password_hash, role, is_active) VALUES (?,?,?,?,?)",
            ("anonymous", "anonymous", hash_password("__anonymous__"), "user", 1),
        )
        c.commit()


def test_public_register_gone(client):
    # 注册端点已删除：无任何 POST 路由匹配该路径，落到根 StaticFiles 兜底 → 405
    # （此应用所有未命中的 POST 都会因根静态挂载得到 405，正说明 /api/auth/register 不再存在）
    r = client.post("/api/auth/register", json={"username": "evil", "password": "123456"})
    assert r.status_code == 405


def test_register_route_absent(client):
    # 对抗审查 LOW：405 只能说明「无 POST 路由命中」，直接断言路由表里没有 register 路径
    paths = [getattr(r, "path", "") for r in client.app.routes]
    assert "/api/auth/register" not in paths


def test_anonymous_cannot_login(client):
    # 对抗审查 HIGH：anonymous 占位行曾带硬编码口令 + 全量权限点，登录必须被拒（与用户不存在同响应）
    _seed_anonymous()
    r = client.post("/api/auth/login", json={"username": "anonymous", "password": "__anonymous__"})
    assert r.status_code == 401


def test_create_user_requires_admin(client):
    login = client.post("/api/auth/login", json={"username": "alice", "password": "alice123"}).json()
    r = client.post("/api/auth/users", json={"username": "bob", "password": "123456"},
                    headers={"Authorization": f"Bearer {login['access_token']}"})
    assert r.status_code == 403


def test_create_user_without_token_401(client):
    assert client.post("/api/auth/users", json={"username": "bob", "password": "123456"}).status_code == 401


def test_admin_create_user_then_login(client, seeded):
    r = client.post("/api/auth/users", json={"username": "bob", "password": "123456"}, headers=_admin_auth(seeded))
    assert r.status_code == 201
    assert r.json()["username"] == "bob"
    # 新账号可登录（初始密码 123456 策略）
    login = client.post("/api/auth/login", json={"username": "bob", "password": "123456"})
    assert login.status_code == 200


def test_admin_create_user_validation(client, seeded):
    h = _admin_auth(seeded)
    assert client.post("/api/auth/users", json={"username": "ab", "password": "123456"}, headers=h).status_code == 400
    assert client.post("/api/auth/users", json={"username": "bob2", "password": "123"}, headers=h).status_code == 400


def test_admin_create_user_duplicate_409(client, seeded):
    h = _admin_auth(seeded)
    assert client.post("/api/auth/users", json={"username": "dup", "password": "123456"}, headers=h).status_code == 201
    r = client.post("/api/auth/users", json={"username": "dup", "password": "123456"}, headers=h)
    assert r.status_code == 409


# ── DELETE /api/auth/users（对抗审查 MEDIUM：此前删除端点零覆盖） ──

def _admin_create(client, seeded, name="victim") -> str:
    r = client.post("/api/auth/users", json={"username": name, "password": "123456"}, headers=_admin_auth(seeded))
    assert r.status_code == 201
    return r.json()["id"]


def test_delete_user_unknown_404(client, seeded):
    r = client.delete("/api/auth/users/no-such-id", headers=_admin_auth(seeded))
    assert r.status_code == 404


def test_delete_user_self_400(client, seeded):
    r = client.delete(f"/api/auth/users/{seeded['admin']['id']}", headers=_admin_auth(seeded))
    assert r.status_code == 400


def test_delete_user_anonymous_400(client, seeded):
    _seed_anonymous()
    r = client.delete("/api/auth/users/anonymous", headers=_admin_auth(seeded))
    assert r.status_code == 400


def test_delete_user_requires_admin(client, seeded):
    uid = _admin_create(client, seeded, "victim")
    login = client.post("/api/auth/login", json={"username": "alice", "password": "alice123"}).json()
    r = client.delete(f"/api/auth/users/{uid}", headers={"Authorization": f"Bearer {login['access_token']}"})
    assert r.status_code == 403


def test_delete_user_success_then_404(client, seeded):
    uid = _admin_create(client, seeded, "victim")
    r = client.delete(f"/api/auth/users/{uid}", headers=_admin_auth(seeded))
    assert r.status_code == 200
    r = client.delete(f"/api/auth/users/{uid}", headers=_admin_auth(seeded))
    assert r.status_code == 404


def test_delete_system_holder_with_another_admin_ok(client, seeded):
    """系统权限点用户可删（还剩 admin 持 system）；覆盖「最后一个系统账号」保护的分支，
    且 anonymous 占位行存在时不把人数算虚高（对抗审查 HIGH 修复口径）。"""
    from backend.ide_app.services import permissions
    from backend.ide_app.services.db_service import _conn

    _seed_anonymous()
    uid = _admin_create(client, seeded, "sys2")
    c = _conn()
    c.execute("UPDATE users SET role='admin' WHERE id=?", (uid,))
    c.commit()
    permissions.seed_identities()  # role=admin → dev_admin 全量权限（含 system）
    r = client.delete(f"/api/auth/users/{uid}", headers=_admin_auth(seeded))
    assert r.status_code == 200
