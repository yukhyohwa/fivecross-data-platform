"""把 sql-ide 后端（复制版 ide_backend）的保留能力并入 data_ai。

铁律：原 sql-ide 目录全程只读；本包已物理迁入 backend/ide_app（去掉 sys.path 注入）。

P2 收编后：不再挂 /ide 前缀。保留的 router 由 main.py 直接挂 /api/*（panel/mcp/remote-mcp/
bi-config），本模块只负责：
- 导出保留 router（供 main.py 引用 ide_mount.xxx_router）
- 启动/关闭（建库/迁移/seed anonymous/宏→指标迁移）

已退役（P2）：用户连接（connect/query/history/schema/connection_manager/schema_cache）、
数据同步（sync/scheduler）、飞书 Bot（feishu_bot/飞书 WS）、sql-ide skill 引擎（skills/agent-skills）、
legacy/claude agent（agent/agent_v2/agent_sessions）。
"""

# ── 1. 让 `from backend.ide_app.*` （sys.path 注入已移除，直接 import backend.ide_app） ──────────────────────────────────

# ── 导入保留的 router / 服务（供 main.py 引用 + 启动逻辑）───────────────────

from backend.ide_app.api.remote_mcp import router as remote_mcp_router  # noqa: E402
from backend.ide_app.services.mcp_gateway import router as mcp_router  # noqa: E402
from backend.ide_app.services.db_service import init_db, _conn  # noqa: E402
from backend.ide_app.migrations import run_migration  # noqa: E402


# ── 3. 启动 / 关闭（从 sql-ide main.py 移植，逐段 try/except 非致命降级）────────

async def ide_startup():
    # 建库 + 迁移
    init_db()
    try:
        run_migration()
    except Exception as e:
        print(f"[ide_startup] Migration error (non-fatal): {e}")

    # 记忆重组（2026-10-23）：清掉 import_glossary 迁移遗留的术语记忆副本
    # （每次启动幂等；术语表唯一来源回归 knowledge/glossary.md）
    try:
        from backend.ide_app.migrations import cleanup_glossary_memories
        cleanup_glossary_memories()
    except Exception as e:
        print(f"[ide_startup] Glossary memory cleanup error (non-fatal): {e}")

    # RBAC 身份种子 + admin→dev_admin（每次启动幂等；独立于 run_migration 的「无用户才建库」分支）
    try:
        from backend.ide_app.services.permissions import seed_identities
        seed_identities()
    except Exception as e:
        print(f"[ide_startup] Seed identities error (non-fatal): {e}")

    # 匿名用户占位：data_ai 侧匿名回落统一用 user_id='anonymous'，而 indicators.user_id
    # 带外键 REFERENCES users(id)，不占位会导致匿名写入指标时「FOREIGN KEY constraint failed」。
    # 口令每次启动都旋转为随机值（对抗审查 HIGH：历史版本用过硬编码口令，且该行经
    # effective_permissions 持有全量权限点；login 端点已拒绝 anonymous，这里再作废口令，
    # 双保险）。口令值不打印。
    try:
        import secrets
        from backend.ide_app.services.db_service import _conn as _db_conn
        from backend.ide_app.core.auth import hash_password
        c = _db_conn()
        if not c.execute("SELECT id FROM users WHERE id='anonymous'").fetchone():
            c.execute(
                "INSERT INTO users (id, username, password_hash, role, is_active) VALUES (?,?,?,?,?)",
                ("anonymous", "anonymous", hash_password(secrets.token_urlsafe(32)), "user", 1),
            )
            c.commit()
            print("[ide_startup] Seeded anonymous user (data_ai fallback)")
        else:
            # 已存在则旋转口令：历史版本的硬编码口令每次重启即作废
            c.execute("UPDATE users SET password_hash=? WHERE id='anonymous'",
                      (hash_password(secrets.token_urlsafe(32)),))
            c.commit()
            print("[ide_startup] Rotated anonymous user password (placeholder row)")
    except Exception as e:
        print(f"[ide_startup] Seed anonymous user error (non-fatal): {e}")

    # 宏 → 指标 自动迁移
    try:
        from backend.ide_app.services.db_service import get_all_macros, create_indicator as db_create_indicator, get_indicator_by_metric_id
        from backend.ide_app.services.indicator_service import analyze_sql_indicator
        c = _conn()
        rows = c.execute("SELECT DISTINCT user_id FROM user_macros").fetchall()
        migrated_total = 0
        for row in rows:
            uid = row["user_id"]
            macros = get_all_macros(uid)
            for macro in macros:
                existing = get_indicator_by_metric_id(f"macro_{macro['id']}")
                if existing:
                    continue
                data = {
                    "metric_id": f"macro_{macro['id']}",
                    "metric_name": macro["name"],
                    "canonical_sql": macro["sql_text"],
                    "definition": macro.get("description", ""),
                    "from_macro_id": str(macro["id"]),
                    "status": "draft",
                }
                try:
                    analysis = await analyze_sql_indicator(macro["name"], macro["sql_text"], [], uid)
                    data.update(analysis)
                except Exception:
                    pass
                try:
                    db_create_indicator(uid, data)
                    migrated_total += 1
                except Exception:
                    pass
        if migrated_total:
            print(f"[ide_startup] Auto-migrated {migrated_total} macros to indicators")
    except Exception as e:
        print(f"[ide_startup] Macro→Indicator migration error (non-fatal): {e}")


async def ide_shutdown():
    """Release platform-local resources only; no legacy data-source teardown."""
    return None
