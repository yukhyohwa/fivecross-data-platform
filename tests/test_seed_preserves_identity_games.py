"""回归：seed_identities 每次启动调用不得覆盖内置身份已被自定义的 games / permission_points。

根因（曾 bug）：seed_identities 对每个内置身份无条件 upsert，ON CONFLICT UPDATE 把 games 重置为
["*"]，导致权限管理里把「全游戏」改成「自定义」后，一重启/一部署（git reset --hard + 重启）就被
打回全游戏。
"""
import json


def test_seed_preserves_custom_identity_games(app_env):
    """内置身份被改成「自定义游戏」后，再跑 seed_identities（等价重启/部署）不得打回全游戏。"""
    from backend.ide_app.services import permissions
    from backend.ide_app.services import db_service

    # 模拟权限管理里把内置身份 ops_normal 从全游戏改成自定义（仅 kof）
    db_service.upsert_identity(
        "ops_normal",
        "运营普通",
        permission_points=["apps"],
        games=["kof"],
        is_builtin=1,
    )
    assert json.loads(db_service.get_identity("ops_normal")["games"]) == ["kof"]

    # 再次启动种子（等价 ide_startup / 部署重启）
    permissions.seed_identities()

    row = db_service.get_identity("ops_normal")
    assert json.loads(row["games"]) == ["kof"], "自定义游戏授权被 seed 打回全游戏"


def test_seed_preserves_custom_identity_permissions(app_env):
    """内置身份的权限点被编辑后，seed_identities 同样不得覆盖。"""
    from backend.ide_app.services import permissions
    from backend.ide_app.services import db_service

    db_service.upsert_identity(
        "ops_normal",
        "运营普通",
        permission_points=["apps", "analysis"],
        games=["*"],
        is_builtin=1,
    )
    assert json.loads(db_service.get_identity("ops_normal")["permission_points"]) == ["apps", "analysis"]

    permissions.seed_identities()

    row = db_service.get_identity("ops_normal")
    assert json.loads(row["permission_points"]) == ["apps", "analysis"], "自定义权限点被 seed 重置"


def test_seed_still_inserts_missing_builtin(app_env):
    """缺的内置身份仍会被补种（不因「不覆盖」而漏建）。"""
    from backend.ide_app.services import permissions
    from backend.ide_app.services import db_service

    db_service.delete_identity("finance")
    assert db_service.get_identity("finance") is None

    permissions.seed_identities()

    assert db_service.get_identity("finance") is not None
