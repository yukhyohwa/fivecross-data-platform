"""P1-17 收尾回归：邮箱映射身份改为「admin 设邮箱时显式确认快照」，不再每次请求实时重算。

覆盖：
- 设邮箱命中映射 → identity 落库快照（identity_applied=true），有显式身份时不覆盖
- 未走快照的「空 identity + 命中邮箱」用户 → resolve_identity 落到 default（无实时重算）
- seed_identities 启动迁移把存量命中用户一次性快照
"""
import json


def _login(client, username, password):
    return client.post("/api/auth/login", json={"username": username, "password": password}).json()["access_token"]





def test_email_hit_snapshots_identity(client, seeded):
    """admin 设 joydata 邮箱命中映射 → users.identity 被快照，响应披露并标记已应用。"""
    from backend.ide_app.services.db_service import _conn, get_user_by_id

    from backend.ide_app.services.db_service import add_email_mapping
    add_email_mapping("ops_normal", "suffix", "@joydata.com")
    token = _login(client, "admin", "admin123")
    r = client.put(
        f"/api/auth/users/{seeded['alice']['id']}/joydata-email",
        json={"joydata_email": "someone@joydata.com"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["auto_identity"] == "ops_normal"
    assert body["auto_identity_name"]
    assert body["identity_applied"] is True
    row = get_user_by_id(seeded["alice"]["id"])
    assert json.loads(row["identity"]) == ["ops_normal"]


def test_email_hit_does_not_override_explicit_identity(client, seeded):
    """用户已有显式身份时，设邮箱命中映射只披露、不覆盖。"""
    from backend.ide_app.services.db_service import _conn, get_user_by_id

    from backend.ide_app.services.db_service import add_email_mapping
    add_email_mapping("ops_normal", "suffix", "@joydata.com")
    c = _conn()
    c.execute("UPDATE users SET identity='finance' WHERE id=?", (seeded["alice"]["id"],))
    c.commit()
    token = _login(client, "admin", "admin123")
    r = client.put(
        f"/api/auth/users/{seeded['alice']['id']}/joydata-email",
        json={"joydata_email": "someone@joydata.com"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["auto_identity"] == "ops_normal"  # 仍披露映射结果
    assert body["identity_applied"] is False
    assert get_user_by_id(seeded["alice"]["id"])["identity"] == "finance"


def test_no_live_email_reevaluation(client, seeded):
    """空 identity + 命中邮箱（未走设邮箱端点）→ resolve_identity 落到 default，不再实时重算。"""
    from backend.ide_app.services import permissions
    from backend.ide_app.services.db_service import _conn, set_user_joydata_email, get_user_by_id

    from backend.ide_app.services.db_service import add_email_mapping
    add_email_mapping("ops_normal", "suffix", "@joydata.com")
    # 直接落库模拟「旧数据 / 其他写入路径」，绕过 admin 设邮箱的确认快照
    set_user_joydata_email(seeded["alice"]["id"], "someone@joydata.com")
    row = get_user_by_id(seeded["alice"]["id"])
    assert not (row["identity"] or "").strip()
    ident = permissions.resolve_identity(row)
    assert ident["key"] == "default"
    assert "analysis" not in ident["permission_points"]


def test_seed_identities_migrates_existing_users(client, seeded):
    """启动迁移：存量「空 identity + 命中邮箱」用户被一次性快照进 identity。"""
    from backend.ide_app.services import permissions
    from backend.ide_app.services.db_service import _conn, set_user_joydata_email, get_user_by_id

    from backend.ide_app.services.db_service import add_email_mapping
    add_email_mapping("ops_normal", "suffix", "@joydata.com")
    set_user_joydata_email(seeded["alice"]["id"], "someone@joydata.com")
    permissions.seed_identities()  # 幂等：已快照的行不再处理
    assert json.loads(get_user_by_id(seeded["alice"]["id"])["identity"]) == ["ops_normal"]
    # 再跑一遍仍稳定
    permissions.seed_identities()
    assert json.loads(get_user_by_id(seeded["alice"]["id"])["identity"]) == ["ops_normal"]
