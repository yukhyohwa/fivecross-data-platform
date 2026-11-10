"""P1-24 owner/游戏隔离：visible_to 语义 + owner_key 归属（个人级资产按 owner 过滤的判定核心）。"""
from analysis.games import family_key, owner_key, visible_to


def test_visible_to_generic_always_true():
    assert visible_to("通用", None, "kof", None, "alice") is True
    assert visible_to(None, None, "kof", None, "alice") is True  # 空层级 → 通用
    assert visible_to("", None, "kof", None, "alice") is True


def test_visible_to_personal_owner_only():
    assert visible_to("个人", None, "kof", "alice", "alice") is True
    assert visible_to("个人", None, "kof", "admin", "alice") is False  # 他人个人资产不可见
    assert visible_to("个人", None, "kof", "alice", None) is False     # 无用户上下文不外泄
    assert visible_to("个人", None, "kof", None, "alice") is False     # 未标归属的历史项宁可隐藏


def test_visible_to_project_family_key():
    assert visible_to("项目", "kof", "kof", "alice", "alice") is True
    assert visible_to("项目", "kof_sea", "kof", "alice", "alice") is True   # 同族互见
    assert visible_to("项目", "kof", "ro", "alice", "alice") is False       # 跨家族隔离


def test_family_key_strips_region_suffix():
    assert family_key("kof_sea") == "kof"
    assert family_key("kof") == "kof"


def test_owner_key_prefers_id():
    assert owner_key({"id": "u1", "username": "x"}) == "u1"
    assert owner_key({"username": "x"}) == "x"
    assert owner_key({}) is None
    assert owner_key(None) is None
