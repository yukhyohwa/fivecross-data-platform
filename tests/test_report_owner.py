"""P1-24 订阅报告 owner 隔离：_sub_visible（订阅跨游戏家族）+ _report_visible（历史报告归属）。"""
from backend.routers.reports import _report_visible, _sub_visible


def test_sub_visible_legacy_no_game_visible():
    # 未标 game 的旧订阅视为通用
    assert _sub_visible(None, "kof") is True
    assert _sub_visible("", "kof") is True


def test_sub_visible_same_family_visible():
    assert _sub_visible("kof", "kof") is True
    assert _sub_visible("kof_sea", "kof") is True  # 同族互见
    assert _sub_visible("kof", "kof_sea") is True


def test_sub_visible_cross_family_hidden():
    assert _sub_visible("ro", "kof") is False
    assert _sub_visible("kof", "ro") is False


def test_report_visible_legacy_no_owner_visible():
    assert _report_visible({}, {"id": "u1", "username": "a"}) is True
    assert _report_visible(None, {"id": "u1", "username": "a"}) is True


def test_report_visible_owner_only():
    assert _report_visible({"owner": "u1"}, {"id": "u1", "username": "a"}) is True
    assert _report_visible({"owner": "u1"}, {"id": "u2", "username": "b"}) is False


def test_report_visible_system_perm_sees_all(seeded):
    from backend.ide_app.services.db_service import _conn
    admin = dict(_conn().execute("SELECT * FROM users WHERE id=?", (seeded["admin"]["id"],)).fetchone())
    alice = dict(_conn().execute("SELECT * FROM users WHERE id=?", (seeded["alice"]["id"],)).fetchone())
    # 有 system 权限点（dev_admin）→ 他人归属的历史报告也可见
    assert _report_visible({"owner": "u-other"}, admin) is True
    # 普通用户 → 仅归属人可见
    assert _report_visible({"owner": alice["id"]}, alice) is True
    assert _report_visible({"owner": "u-other"}, alice) is False
