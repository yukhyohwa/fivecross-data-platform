"""P1-7：Jev 一致性校验的 resolve_llm 闸门——非管理员未配个人 key 时跳过 Jev。

（Jev 经 analysis.jev_client 直连全局 env key，必须复用 LLM 配置闸门的同一规则，
否则非管理员可通过 Jev 白嫖系统默认 LLM。）
"""
from backend.ide_app.services.db_service import _conn, save_agent_config
from backend.services.llm import jev_allowed


def _user_row(uid) -> dict:
    """从库中取完整用户行（含 identity/extra_permissions/email），等价 get_current_user 的返回。"""
    if isinstance(uid, dict):  # create_user 返回 {"id", "username"}
        uid = uid["id"]
    return dict(_conn().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone())


def test_jev_admin_allowed(seeded):
    admin = _user_row(seeded["admin"])
    assert admin["identity"]  # seed_identities 应把 role=admin 归到 dev_admin
    assert jev_allowed(admin) == (True, None)


def test_jev_nonadmin_without_key_blocked(seeded):
    alice = _user_row(seeded["alice"])
    ok, reason = jev_allowed(alice)
    assert not ok
    assert "API Key" in reason  # 与 LLM 配置闸门同一提示口径


def test_jev_nonadmin_with_key_allowed(seeded):
    save_agent_config(seeded["alice"]["id"], {"api_key": "sk-test-dummy", "api_base": "", "model": ""})
    assert jev_allowed(_user_row(seeded["alice"]))[0] is True


def test_jev_anonymous_allowed(seeded):
    # 匿名回落 = 系统默认（dev 模式不破坏现状），与 resolve_llm 口径一致
    assert jev_allowed(None) == (True, None)
    assert jev_allowed({}) == (True, None)
