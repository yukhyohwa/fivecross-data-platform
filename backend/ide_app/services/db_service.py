import sqlite3
import threading
import uuid
import json
from datetime import datetime
from pathlib import Path
from typing import Optional

# 审计 P2-6：个人 LLM api_key 密文落库（复用 core/crypto.py 的 Fernet 加解密，勿改 crypto.py 本身）
from backend.ide_app.core.crypto import decrypt, encrypt

# 融合后独立数据落点：data_ai/ide_data.db（从 ~/.sql-ide/app_data.db 一次性复制而来）
DB_DIR = Path(__file__).resolve().parents[3]  # data_ai/ 根目录
DB_PATH = DB_DIR / "ide_data.db"

_local = threading.local()


def _conn() -> sqlite3.Connection:
    """Return a thread-local SQLite connection (created once per thread, reused thereafter)."""
    conn = getattr(_local, "conn", None)
    if conn is None:
        DB_DIR.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA foreign_keys=ON")
        _local.conn = conn
    return conn


# ── schema ──

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    is_active BOOLEAN DEFAULT 1,
    login_attempts INTEGER DEFAULT 0,
    refresh_token TEXT,
    refresh_token_expires_at TEXT,
    last_login_at TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    joydata_email TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS user_connections (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    host TEXT NOT NULL,
    port INTEGER DEFAULT 3306,
    user_name TEXT DEFAULT '',
    password_encrypted TEXT DEFAULT '',
    database_name TEXT DEFAULT '',
    db_type TEXT DEFAULT 'mysql',
    charset TEXT DEFAULT 'utf8mb4',
    use_ssh BOOLEAN DEFAULT 0,
    ssh_host TEXT,
    ssh_port INTEGER DEFAULT 22,
    ssh_user TEXT,
    ssh_password_encrypted TEXT DEFAULT '',
    ssh_key_path TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    UNIQUE(user_id, name)
);

CREATE TABLE IF NOT EXISTS user_macros (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    sql_text TEXT NOT NULL,
    description TEXT DEFAULT '',
    folder TEXT DEFAULT '默认',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS user_macro_folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    folder_name TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    UNIQUE(user_id, folder_name)
);

CREATE TABLE IF NOT EXISTS user_query_history (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    connection_id TEXT,
    connection_name TEXT DEFAULT '',
    sql_text TEXT NOT NULL,
    duration REAL DEFAULT 0,
    row_count INTEGER DEFAULT 0,
    executed_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS user_agent_config (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    api_key TEXT DEFAULT '',
    model TEXT DEFAULT 'deepseek-chat',
    api_base TEXT DEFAULT 'https://api.deepseek.com/v1',
    agent_backend TEXT DEFAULT 'legacy',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS user_settings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    max_rows INTEGER DEFAULT 200,
    show_schema BOOLEAN DEFAULT 0,
    show_macros BOOLEAN DEFAULT 0,
    show_history BOOLEAN DEFAULT 0,
    editor_sql TEXT DEFAULT '',
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS indicator_folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    parent_id INTEGER REFERENCES indicator_folders(id),
    sort_order INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS indicators (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    metric_id TEXT NOT NULL UNIQUE,
    metric_name TEXT NOT NULL,
    metric_alias TEXT DEFAULT '',
    version INTEGER DEFAULT 1,
    owner TEXT DEFAULT '',
    status TEXT DEFAULT 'draft' CHECK(status IN ('active','deprecated','draft')),
    domain TEXT DEFAULT '',
    category TEXT DEFAULT '',
    tags TEXT DEFAULT '[]',
    definition TEXT DEFAULT '',
    aggregation_type TEXT DEFAULT '',
    granularity TEXT DEFAULT '',
    canonical_sql TEXT NOT NULL,
    sql_fragments TEXT DEFAULT '[]',
    db_type TEXT DEFAULT 'mysql',
    sql_template_params TEXT DEFAULT '[]',
    event_source TEXT DEFAULT '[]',
    join_logic TEXT DEFAULT '[]',
    filter_conditions TEXT DEFAULT '[]',
    window_size TEXT DEFAULT '',
    supported_filters TEXT DEFAULT '[]',
    business_scenarios TEXT DEFAULT '[]',
    input_tables TEXT DEFAULT '[]',
    dependencies TEXT DEFAULT '[]',
    refresh_frequency TEXT DEFAULT '',
    data_latency TEXT DEFAULT '',
    test_cases TEXT DEFAULT '[]',
    common_mistakes TEXT DEFAULT '[]',
    known_edge_cases TEXT DEFAULT '[]',
    related_indicators TEXT DEFAULT '[]',
    change_log TEXT DEFAULT '[]',
    uncertain_fields TEXT DEFAULT '[]',
    from_macro_id TEXT,
    source_sql TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_indicators_user ON indicators(user_id);
CREATE INDEX IF NOT EXISTS idx_indicators_metric_id ON indicators(metric_id);
CREATE INDEX IF NOT EXISTS idx_indicators_domain ON indicators(domain);
CREATE INDEX IF NOT EXISTS idx_indicators_status ON indicators(status);

CREATE TABLE IF NOT EXISTS indicator_versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    indicator_id INTEGER NOT NULL REFERENCES indicators(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,
    snapshot TEXT NOT NULL,
    change_comment TEXT DEFAULT '',
    created_by TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_indicator_versions_indicator ON indicator_versions(indicator_id);

CREATE TABLE IF NOT EXISTS skills (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    skill_id TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    version INTEGER DEFAULT 1,
    status TEXT DEFAULT 'draft' CHECK(status IN ('draft','testing','published','deprecated')),
    category TEXT DEFAULT '',
    tags TEXT DEFAULT '[]',
    trigger_keywords TEXT DEFAULT '[]',
    inputs TEXT DEFAULT '[]',
    steps TEXT DEFAULT '[]',
    output TEXT DEFAULT '{}',
    markdown TEXT DEFAULT '',
    executed_count INTEGER DEFAULT 0,
    avg_duration REAL DEFAULT 0,
    success_rate REAL DEFAULT 0,
    last_executed TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_skills_user ON skills(user_id);
CREATE INDEX IF NOT EXISTS idx_skills_status ON skills(status);

CREATE TABLE IF NOT EXISTS skill_executions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    skill_id INTEGER NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
    status TEXT DEFAULT 'running' CHECK(status IN ('running','success','failed','partial')),
    inputs TEXT DEFAULT '{}',
    outputs TEXT DEFAULT '{}',
    steps_log TEXT DEFAULT '[]',
    total_duration REAL,
    error_message TEXT DEFAULT '',
    triggered_by TEXT DEFAULT 'manual',
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_skill_executions_skill ON skill_executions(skill_id);

CREATE TABLE IF NOT EXISTS router_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT,
    user_input TEXT NOT NULL,
    route_target TEXT NOT NULL,
    confidence REAL,
    reasoning TEXT,
    matched_skill_id TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS feishu_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    app_id TEXT NOT NULL,
    app_secret TEXT NOT NULL,
    tenant_access_token TEXT DEFAULT '',
    token_expires_at TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sync_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    enabled INTEGER DEFAULT 1,
    direction TEXT DEFAULT 'feishu_to_db',
    strategy TEXT DEFAULT 'append',
    feishu_account_id INTEGER NOT NULL REFERENCES feishu_accounts(id),
    feishu_doc_token TEXT NOT NULL,
    feishu_table_id TEXT DEFAULT '',
    conn_id TEXT NOT NULL,
    target_table TEXT NOT NULL,
    field_mapping TEXT DEFAULT '[]',
    primary_keys TEXT DEFAULT '[]',
    cron_expr TEXT DEFAULT '',
    last_sync_at TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_sync_tasks_user ON sync_tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_sync_tasks_enabled ON sync_tasks(enabled);

CREATE TABLE IF NOT EXISTS sync_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL REFERENCES sync_tasks(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'running',
    started_at TEXT,
    finished_at TEXT,
    source_rows INTEGER DEFAULT 0,
    inserted_rows INTEGER DEFAULT 0,
    updated_rows INTEGER DEFAULT 0,
    error_message TEXT DEFAULT '',
    detail TEXT DEFAULT '[]',
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_sync_logs_task ON sync_logs(task_id);

CREATE TABLE IF NOT EXISTS agent_conversation_summary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    conn_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    message_count INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    UNIQUE(user_id, conn_id)
);

CREATE TABLE IF NOT EXISTS agent_memory (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT,
    scope TEXT NOT NULL DEFAULT 'private',
    category TEXT NOT NULL,
    key TEXT,
    content TEXT NOT NULL,
    source TEXT DEFAULT 'manual',
    hit_count INTEGER DEFAULT 0,
    mem_type TEXT NOT NULL DEFAULT '日常',
    bind_name TEXT NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_agent_memory_user ON agent_memory(user_id, scope);
CREATE INDEX IF NOT EXISTS idx_agent_memory_category ON agent_memory(category);

--- 飞书机器人 ---
CREATE TABLE IF NOT EXISTS feishu_chat_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    chat_type TEXT DEFAULT 'group',
    user_id TEXT NOT NULL,
    conn_id TEXT NOT NULL,
    messages TEXT DEFAULT '[]',
    sender_open_id TEXT DEFAULT '',
    sender_name TEXT DEFAULT '',
    skill_id TEXT DEFAULT '',
    skill_loop INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS feishu_bot_config (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id TEXT NOT NULL,
    app_secret TEXT NOT NULL,
    verification_token TEXT DEFAULT '',
    encrypt_key TEXT DEFAULT '',
    mapped_user_id TEXT DEFAULT '',
    conn_id TEXT DEFAULT '',
    agent_backend TEXT DEFAULT 'legacy',
    is_active INTEGER DEFAULT 0,
    long_connection_enabled INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS feishu_bot_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT,
    chat_id TEXT,
    text TEXT,
    status TEXT,
    error TEXT,
    duration REAL DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_fbl_chat ON feishu_bot_logs(chat_id);

--- Agent 聊天会话历史 ---
CREATE TABLE IF NOT EXISTS agent_chat_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    conn_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '未命名对话',
    messages TEXT NOT NULL DEFAULT '[]',
    msg_count INTEGER DEFAULT 0,
    snapshot TEXT NOT NULL DEFAULT '{}',
    description TEXT NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_acs_user ON agent_chat_sessions(user_id, updated_at);

--- 共同创作分享表 ---
CREATE TABLE IF NOT EXISTS shared_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_type TEXT NOT NULL CHECK(item_type IN ('indicator','skill','remote_mcp')),
    item_id INTEGER NOT NULL,
    owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    shared_with_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission TEXT NOT NULL DEFAULT 'read' CHECK(permission IN ('read','write')),
    created_at TEXT DEFAULT (datetime('now')),
    UNIQUE(item_type, item_id, shared_with_user_id)
);
CREATE INDEX IF NOT EXISTS idx_si_shared_with ON shared_items(shared_with_user_id, item_type);
CREATE INDEX IF NOT EXISTS idx_si_item ON shared_items(item_type, item_id);

--- 远程 MCP 服务器配置（通用层，Sensor Tower 只是第一行）---
--- 由 admin 统一配置，通过 shared_items(item_type='remote_mcp') 分享给成员 ---
CREATE TABLE IF NOT EXISTS user_remote_mcp_server (
    id INTEGER PRIMARY KEY AUTOINCREMENT,        -- 必须是 INTEGER：shared_items.item_id 是 INTEGER
    owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,                   -- 全局唯一：它就是工具命名空间 mcp__<name>__<tool>
    url TEXT NOT NULL DEFAULT '',                -- http/sse 用
    transport TEXT NOT NULL DEFAULT 'http',      -- http | sse | stdio
    command TEXT NOT NULL DEFAULT '',            -- stdio 用
    args_json TEXT NOT NULL DEFAULT '[]',        -- stdio 用
    env_encrypted TEXT NOT NULL DEFAULT '',      -- stdio 用（Fernet 加密的 env JSON）
    auth_type TEXT NOT NULL DEFAULT 'none',      -- none | bearer | oauth2
    credentials_encrypted TEXT NOT NULL DEFAULT '',
    auth_register_url TEXT NOT NULL DEFAULT '',  -- DCR
    auth_authorize_url TEXT NOT NULL DEFAULT '',
    auth_token_url TEXT NOT NULL DEFAULT '',
    auth_scope TEXT NOT NULL DEFAULT '',
    auth_resource TEXT NOT NULL DEFAULT '',      -- RFC8707 resource indicator
    redirect_uri TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1,
    tools_json TEXT NOT NULL DEFAULT '[]',
    tools_count INTEGER NOT NULL DEFAULT 0,
    last_status TEXT NOT NULL DEFAULT '',        -- '' | ok | error | needs_auth
    last_error TEXT NOT NULL DEFAULT '',
    last_checked_at TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_urmcp_owner ON user_remote_mcp_server(owner_user_id, enabled);

CREATE TABLE IF NOT EXISTS bi_platform_config (
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, key)
);

CREATE TABLE IF NOT EXISTS bi_project_mapping (
    database_name TEXT NOT NULL PRIMARY KEY,
    project_id TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS joydata_auth (
    user_id TEXT NOT NULL PRIMARY KEY,  -- data_ai users.id（每用户独立 OAuth 凭据 = 按 Joydata 权限各看各的）
    access_token TEXT NOT NULL DEFAULT '',   -- Fernet 加密
    refresh_token TEXT NOT NULL DEFAULT '',  -- Fernet 加密
    client_id TEXT NOT NULL DEFAULT '',      -- DCR 注册的 OAuth client_id（refresh 需要）
    expires_at INTEGER NOT NULL DEFAULT 0,   -- unix 秒
    connected_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tool_meta (
    key TEXT PRIMARY KEY,          -- "{source}::{name}"
    source TEXT NOT NULL,
    description TEXT,              -- NULL = 用代码默认描述
    enabled INTEGER DEFAULT 1,
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS identities (
    key TEXT PRIMARY KEY,          -- slug，如 dev_admin / data_analysis
    name TEXT NOT NULL,            -- 显示名，如 开发管理
    permission_points TEXT DEFAULT '[]',  -- JSON 数组，权限点键的集合
    games TEXT DEFAULT '["*"]',    -- JSON 数组，游戏 key 列表；["*"]=全游戏
    access_levels TEXT DEFAULT '{}',  -- JSON 对象，{sql/kb/skill: [L1,L2,L3]} 机密档位多选集合
    is_builtin INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS identity_email_mappings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identity_key TEXT NOT NULL,
    match_type TEXT NOT NULL DEFAULT 'exact',  -- 'exact' 精确邮箱 | 'suffix' 后缀/域名
    pattern TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);
"""


# ── 启动/迁移前快照（审计 P1-22）──────────────────────────────────────────────
BACKUP_DIR = DB_DIR / "backups"
BACKUP_KEEP = 10
BACKUP_MIN_INTERVAL_HOURS = 6  # 限频：register 等路径也会兜底调 init_db，避免频繁快照


def backup_db(keep: int = BACKUP_KEEP) -> Path | None:
    """迁移/启动前快照 ide_data.db。

    用 SQLite backup API 完整拷贝（含 WAL 中未 checkpoint 的内容，比直接 copy 文件安全）；
    按时间戳命名存 data_ai/backups/，只保留最近 keep 份。DB 文件不存在（首次启动）跳过；
    BACKUP_MIN_INTERVAL_HOURS 内已有快照则跳过；任何失败不阻断启动。

    恢复预案：停止服务 → 用某份备份覆盖 DB_PATH（同时删除同目录 ide_data.db-wal/-shm）→ 重启。
    """
    if not DB_PATH.exists():
        return None
    try:
        # 限频：最近一份快照还在间隔内就不重复备份。
        # 只认时间戳前缀 ide_data_YYYYmmdd_*.db——每日备份用独立前缀 ide_data_daily_*，
        # 若共用通配会互相误伤（间隔判定被每日备份抑制、保留清理互删）。
        existing = sorted(BACKUP_DIR.glob("ide_data_[0-9]*.db"))
        if existing:
            try:
                stamp = existing[-1].name[len("ide_data_"):-len(".db")]
                last = datetime.strptime(stamp, "%Y%m%d_%H%M%S")
                if (datetime.now() - last).total_seconds() < BACKUP_MIN_INTERVAL_HOURS * 3600:
                    return None
            except ValueError:
                pass
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        # 清扫历史崩溃残留的临时文件（不同时间戳的残留不会被本次预清理覆盖）
        for stale in BACKUP_DIR.glob("ide_data_[0-9]*.db.tmp"):
            try:
                stale.unlink()
            except OSError:
                pass
        target = BACKUP_DIR / f"ide_data_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
        # 先备到临时文件、成功后原子改名（对抗审查）：崩溃/失败残留的残缺 .db 不再
        # 占用正式名——tmp 后缀不匹配限频/清理 glob，失败路径显式清理。
        tmp = BACKUP_DIR / f"{target.name}.tmp"
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
        src = sqlite3.connect(str(DB_PATH))
        try:
            dst = sqlite3.connect(str(tmp))
            try:
                src.backup(dst)
            finally:
                dst.close()
        finally:
            src.close()
        tmp.replace(target)
        # 清理旧备份，保留最近 keep 份（同样只认时间戳前缀，不碰每日备份）
        for old in sorted(BACKUP_DIR.glob("ide_data_[0-9]*.db"))[:-keep]:
            try:
                old.unlink()
            except OSError:
                pass
        print(f"[backup] ide_data.db 快照已生成：{target.name}（保留最近 {keep} 份）")
        return target
    except Exception as exc:
        print(f"[backup] ide_data.db 备份失败（非致命）：{exc}")
        return None


DAILY_BACKUP_KEEP = 14  # 每日备份保留 14 份（约两周，恢复窗口远长于启动快照）


def backup_db_daily() -> Path | None:
    """每日备份（审计建议 10）：独立前缀 ide_data_daily_YYYYmmdd.db + 独立保留数，
    与启动快照（ide_data_*.db）互不干扰。同一天已备过则跳过（daemon 每小时醒来一次，
    当天重复备份无意义）；任何失败不阻断服务。"""
    if not DB_PATH.exists():
        return None
    try:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d")
        if any(BACKUP_DIR.glob(f"ide_data_daily_{stamp}*.db")):
            return None
        # 清扫历史崩溃残留的临时文件（同 prefix，不同时间戳的残留不会被当日预清理覆盖）
        for stale in BACKUP_DIR.glob("ide_data_daily_*.db.tmp"):
            try:
                stale.unlink()
            except OSError:
                pass
        target = BACKUP_DIR / f"ide_data_daily_{stamp}.db"
        # 先备到临时文件、成功后原子改名（对抗审查）：备份中途失败残留的残缺 .db 会
        # 把「当天已备过」判重永久占住（当日不再重试）；tmp 名不匹配判重 glob，
        # 失败路径显式清理，当天可重试。
        tmp = BACKUP_DIR / f"{target.name}.tmp"
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
        src = sqlite3.connect(str(DB_PATH))
        try:
            dst = sqlite3.connect(str(tmp))
            try:
                src.backup(dst)
            finally:
                dst.close()
        finally:
            src.close()
        tmp.replace(target)
        for old in sorted(BACKUP_DIR.glob("ide_data_daily_*.db"))[:-DAILY_BACKUP_KEEP]:
            try:
                old.unlink()
            except OSError:
                pass
        print(f"[backup] ide_data.db 每日备份已生成：{target.name}（保留最近 {DAILY_BACKUP_KEEP} 份）")
        return target
    except Exception as exc:
        print(f"[backup] ide_data.db 每日备份失败（非致命）：{exc}")
        return None


def init_db():
    # 审计 P1-22：任何前向迁移执行前先做快照（限频 + 失败不阻断），保证迁移有回滚点
    backup_db()
    c = _conn()
    c.executescript(_SCHEMA_SQL)
    c.commit()
    # Idempotent column migrations for pre-existing DBs (CREATE TABLE IF NOT
    # EXISTS won't add new columns to an existing table).
    user_cols = {r["name"] for r in c.execute("PRAGMA table_info(users)")}
    if "joydata_email" not in user_cols:
        c.execute("ALTER TABLE users ADD COLUMN joydata_email TEXT DEFAULT ''")
        c.commit()
    # RBAC：身份 + 用户级额外权限点/额外游戏/额外机密档位
    for col, ddl in [
        ("identity", "ALTER TABLE users ADD COLUMN identity TEXT DEFAULT ''"),
        ("extra_permissions", "ALTER TABLE users ADD COLUMN extra_permissions TEXT DEFAULT ''"),
        ("extra_games", "ALTER TABLE users ADD COLUMN extra_games TEXT DEFAULT ''"),
        ("extra_access_levels", "ALTER TABLE users ADD COLUMN extra_access_levels TEXT DEFAULT '{}'"),
    ]:
        if col not in user_cols:
            c.execute(ddl)
            c.commit()

    # identities: 旧库补 access_levels 列（SQL/知识库/专项 机密档位多选集合）
    ident_cols = {r["name"] for r in c.execute("PRAGMA table_info(identities)")}
    if "access_levels" not in ident_cols:
        c.execute("ALTER TABLE identities ADD COLUMN access_levels TEXT DEFAULT '{}'")
        c.commit()

    cols = {r["name"] for r in c.execute("PRAGMA table_info(user_agent_config)")}
    if "agent_backend" not in cols:
        c.execute("ALTER TABLE user_agent_config ADD COLUMN agent_backend TEXT DEFAULT 'legacy'")
        c.commit()

    # indicators: 旧库补 source_sql 列（一拆多后记录指标来源 SQL 文件）
    ind_cols = {r["name"] for r in c.execute("PRAGMA table_info(indicators)")}
    if "source_sql" not in ind_cols:
        c.execute("ALTER TABLE indicators ADD COLUMN source_sql TEXT DEFAULT ''")
        c.commit()

    # joydata_auth: 旧库补 client_id 列（DCR 注册的 OAuth client_id，refresh 需要）
    ja_cols = {r["name"] for r in c.execute("PRAGMA table_info(joydata_auth)")}
    if "client_id" not in ja_cols:
        try:
            c.execute("ALTER TABLE joydata_auth ADD COLUMN client_id TEXT NOT NULL DEFAULT ''")
            c.commit()
        except Exception:
            pass

    # agent_memory: 旧库可能缺 updated_at 列（CREATE TABLE IF NOT EXISTS 不会补列）
    am_cols = {r["name"] for r in c.execute("PRAGMA table_info(agent_memory)")}
    if "updated_at" not in am_cols:
        try:
            # SQLite ALTER ADD COLUMN 不允许表达式默认值，用 NULL；新行由应用层或触发器填充
            c.execute("ALTER TABLE agent_memory ADD COLUMN updated_at TEXT")
            c.commit()
        except Exception:
            pass
    # 对抗验证 2026-10-21：补列前的旧行 updated_at 为 NULL，在 ORDER BY updated_at DESC
    # 召回池里恒排最后——迁移时按 created_at 回填，旧行也能参与 recent 排序
    try:
        c.execute("UPDATE agent_memory SET updated_at = created_at WHERE updated_at IS NULL OR updated_at = ''")
        c.commit()
    except Exception:
        pass
    # 记忆增强（2026-10-21）：类型打标 + 绑定资产（旧数据默认「日常」、无绑定）
    if "mem_type" not in am_cols:
        try:
            c.execute("ALTER TABLE agent_memory ADD COLUMN mem_type TEXT NOT NULL DEFAULT '日常'")
            c.commit()
        except Exception:
            pass
    if "bind_name" not in am_cols:
        try:
            c.execute("ALTER TABLE agent_memory ADD COLUMN bind_name TEXT NOT NULL DEFAULT ''")
            c.commit()
        except Exception:
            pass
    # bind_name 索引只能在列补齐后建（旧库 executescript 阶段列尚不存在，放 _SCHEMA_SQL 会启动失败）
    try:
        c.execute("CREATE INDEX IF NOT EXISTS idx_agent_memory_bind ON agent_memory(user_id, bind_name)")
        c.commit()
    except Exception:
        pass

    # feishu_chat_sessions: 迁移到按 (chat_id, sender_open_id) 隔离 + skill loop 字段
    # 旧表有列级 chat_id UNIQUE 约束，需重建表去掉它（SQLite 无法直接删列约束）
    schema_row = c.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='feishu_chat_sessions'").fetchone()
    need_rebuild = bool(schema_row and "chat_id TEXT NOT NULL UNIQUE" in (schema_row["sql"] or ""))

    if need_rebuild:
        # 重建表：去掉 chat_id 列级 UNIQUE，改为复合唯一索引
        c.execute("ALTER TABLE feishu_chat_sessions RENAME TO feishu_chat_sessions_old")
        c.execute("""CREATE TABLE feishu_chat_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id TEXT NOT NULL,
            chat_type TEXT DEFAULT 'group',
            user_id TEXT NOT NULL,
            conn_id TEXT NOT NULL,
            messages TEXT DEFAULT '[]',
            sender_open_id TEXT DEFAULT '',
            sender_name TEXT DEFAULT '',
            skill_id TEXT DEFAULT '',
            skill_loop INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        )""")
        # 迁移旧数据（sender_open_id 旧库为空，保留）
        c.execute("""INSERT INTO feishu_chat_sessions
            (id, chat_id, chat_type, user_id, conn_id, messages, sender_open_id, sender_name, skill_id, skill_loop, created_at, updated_at)
            SELECT id, chat_id, chat_type, user_id, conn_id, messages, '', '', '', 0, created_at, updated_at
            FROM feishu_chat_sessions_old""")
        c.execute("DROP TABLE feishu_chat_sessions_old")
        # 删除旧索引（若存在）
        c.execute("DROP INDEX IF EXISTS idx_fcs_chat_id")
        c.commit()
    else:
        # 新库：仅补列
        fcs_cols = {r["name"] for r in c.execute("PRAGMA table_info(feishu_chat_sessions)")}
        for col, ddl in [
            ("sender_open_id", "ALTER TABLE feishu_chat_sessions ADD COLUMN sender_open_id TEXT DEFAULT ''"),
            ("sender_name", "ALTER TABLE feishu_chat_sessions ADD COLUMN sender_name TEXT DEFAULT ''"),
            ("skill_id", "ALTER TABLE feishu_chat_sessions ADD COLUMN skill_id TEXT DEFAULT ''"),
            ("skill_loop", "ALTER TABLE feishu_chat_sessions ADD COLUMN skill_loop INTEGER DEFAULT 0"),
        ]:
            if col not in fcs_cols:
                try:
                    c.execute(ddl)
                except Exception:
                    pass
        c.commit()
    # 复合唯一索引
    try:
        c.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_fcs_chat_sender ON feishu_chat_sessions(chat_id, sender_open_id)")
        c.commit()
    except Exception:
        pass

    # shared_items: 放宽 item_type CHECK，纳入 'remote_mcp'（远程 MCP server 分享）
    # 旧表的 CHECK 只允许 ('indicator','skill')，SQLite 无法改 CHECK，必须重建表。
    # 判据用 sqlite_master.sql（PRAGMA table_info 看不到 CHECK 约束）。
    si_row = c.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='shared_items'"
    ).fetchone()
    if si_row and "'remote_mcp'" not in (si_row["sql"] or ""):
        c.execute("ALTER TABLE shared_items RENAME TO shared_items_old")
        c.execute("""CREATE TABLE shared_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_type TEXT NOT NULL CHECK(item_type IN ('indicator','skill','remote_mcp')),
            item_id INTEGER NOT NULL,
            owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            shared_with_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            permission TEXT NOT NULL DEFAULT 'read' CHECK(permission IN ('read','write')),
            created_at TEXT DEFAULT (datetime('now')),
            UNIQUE(item_type, item_id, shared_with_user_id)
        )""")
        c.execute("""INSERT INTO shared_items
            (id, item_type, item_id, owner_user_id, shared_with_user_id, permission, created_at)
            SELECT id, item_type, item_id, owner_user_id, shared_with_user_id, permission, created_at
            FROM shared_items_old""")
        c.execute("DROP TABLE shared_items_old")
        c.commit()
    # DROP TABLE 会连带删除索引，无条件重建（幂等）
    c.execute("CREATE INDEX IF NOT EXISTS idx_si_shared_with ON shared_items(shared_with_user_id, item_type)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_si_item ON shared_items(item_type, item_id)")
    c.commit()

    # bi_platform_config: 迁移到 user_id + key 复合主键（用户隔离）
    try:
        bi_cols = {r["name"] for r in c.execute("PRAGMA table_info(bi_platform_config)")}
    except Exception:
        bi_cols = set()
    if "user_id" not in bi_cols:
        try:
            c.execute("DROP TABLE IF EXISTS bi_platform_config")
            c.execute("""CREATE TABLE bi_platform_config (
                user_id TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                updated_at TEXT DEFAULT (datetime('now')),
                PRIMARY KEY (user_id, key)
            )""")
            c.commit()
        except Exception:
            pass

    # feishu_bot_config: 加 long_connection_enabled 列（WebSocket 长连接模式开关）
    try:
        fb_cols = {r["name"] for r in c.execute("PRAGMA table_info(feishu_bot_config)")}
    except Exception:
        fb_cols = set()
    if "long_connection_enabled" not in fb_cols:
        try:
            c.execute("ALTER TABLE feishu_bot_config ADD COLUMN long_connection_enabled INTEGER DEFAULT 0")
            c.commit()
        except Exception:
            pass

    # agent_chat_sessions: 加 snapshot 列（会话最终查询页/结果页快照）
    try:
        acs_cols = {r["name"] for r in c.execute("PRAGMA table_info(agent_chat_sessions)")}
    except Exception:
        acs_cols = set()
    if "snapshot" not in acs_cols:
        try:
            c.execute("ALTER TABLE agent_chat_sessions ADD COLUMN snapshot TEXT NOT NULL DEFAULT '{}'")
            c.commit()
        except Exception:
            pass

    # agent_chat_sessions: 加 description 列（会话自动总结描述）
    try:
        acs_cols = {r["name"] for r in c.execute("PRAGMA table_info(agent_chat_sessions)")}
    except Exception:
        acs_cols = set()
    if "description" not in acs_cols:
        try:
            c.execute("ALTER TABLE agent_chat_sessions ADD COLUMN description TEXT NOT NULL DEFAULT ''")
            c.commit()
        except Exception:
            pass


# ── users ──

def create_user(username: str, password_hash: str) -> dict:
    c = _conn()
    uid = str(uuid.uuid4())[:12]
    now = datetime.utcnow().isoformat()
    c.execute("INSERT INTO users (id, username, password_hash, created_at, updated_at) VALUES (?,?,?,?,?)",
              (uid, username, password_hash, now, now))
    c.commit()
    return {"id": uid, "username": username}


def get_user_by_username(username: str) -> Optional[dict]:
    c = _conn()
    row = c.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
    return dict(row) if row else None


def get_username(user_id: str) -> str:
    """按 user id 取用户名（分享展示用）；不存在返回空串。"""
    row = _conn().execute("SELECT username FROM users WHERE id=?", (user_id,)).fetchone()
    return row["username"] if row else ""


def get_user_by_id(uid: str) -> Optional[dict]:
    c = _conn()
    row = c.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
    return dict(row) if row else None


def set_user_joydata_email(uid: str, email: str) -> None:
    """绑定用户的 joydata 邮箱（看板「每人各看各的」身份来源，admin 维护）。"""
    c = _conn()
    c.execute("UPDATE users SET joydata_email=?, updated_at=datetime('now') WHERE id=?", (email or "", uid))
    c.commit()


# ── 权限管理（RBAC）──

def list_identities() -> list[dict]:
    c = _conn()
    rows = c.execute("SELECT * FROM identities ORDER BY is_builtin DESC, name").fetchall()
    return [dict(r) for r in rows]


def get_identity(key: str) -> Optional[dict]:
    row = _conn().execute("SELECT * FROM identities WHERE key=?", (key,)).fetchone()
    return dict(row) if row else None


def upsert_identity(key: str, name: str, permission_points: list[str], games: list[str], is_builtin: int = 0, access_levels: dict | None = None) -> None:
    c = _conn()
    c.execute(
        "INSERT INTO identities (key, name, permission_points, games, access_levels, is_builtin) "
        "VALUES (?,?,?,?,?,?) "
        "ON CONFLICT(key) DO UPDATE SET name=excluded.name, permission_points=excluded.permission_points, "
        "games=excluded.games, access_levels=excluded.access_levels, updated_at=datetime('now')",
        (key, name, json.dumps(permission_points), json.dumps(games), json.dumps(access_levels or {}), is_builtin),
    )
    c.commit()


def delete_identity(key: str) -> None:
    c = _conn()
    c.execute("DELETE FROM identities WHERE key=?", (key,))
    c.commit()


def list_email_mappings() -> list[dict]:
    c = _conn()
    rows = c.execute(
        "SELECT m.*, i.name AS identity_name FROM identity_email_mappings m "
        "LEFT JOIN identities i ON i.key = m.identity_key ORDER BY m.id"
    ).fetchall()
    return [dict(r) for r in rows]


def add_email_mapping(identity_key: str, match_type: str, pattern: str) -> dict:
    c = _conn()
    cur = c.execute(
        "INSERT INTO identity_email_mappings (identity_key, match_type, pattern) VALUES (?,?,?)",
        (identity_key, match_type, pattern),
    )
    c.commit()
    row = c.execute(
        "SELECT m.*, i.name AS identity_name FROM identity_email_mappings m "
        "LEFT JOIN identities i ON i.key = m.identity_key WHERE m.id=?",
        (cur.lastrowid,),
    ).fetchone()
    return dict(row)


def delete_email_mapping(mid: int) -> None:
    c = _conn()
    c.execute("DELETE FROM identity_email_mappings WHERE id=?", (mid,))
    c.commit()


def update_user_rbac(uid: str, identity, extra_permissions: list[str], extra_games: list[str], extra_access_levels: dict | None = None) -> None:
    # identity 支持多选：既收 list[str]，也兼容旧前端传来的单 key 字符串（滚动部署期间）。
    if isinstance(identity, str):
        identity = [identity] if identity.strip() else []
    ident_keys = [k.strip() for k in (identity or []) if isinstance(k, str) and k.strip()]
    c = _conn()
    c.execute(
        "UPDATE users SET identity=?, extra_permissions=?, extra_games=?, extra_access_levels=?, updated_at=datetime('now') WHERE id=?",
        (json.dumps(ident_keys) if ident_keys else "", json.dumps(extra_permissions or []), json.dumps(extra_games or []),
         json.dumps(extra_access_levels or {}), uid),
    )
    c.commit()


def delete_user(uid: str) -> None:
    """删除用户；依赖表的 user_id 外键均为 ON DELETE CASCADE。调用方负责保护 anonymous/自己/最后管理员。"""
    c = _conn()
    c.execute("DELETE FROM users WHERE id=?", (uid,))
    c.commit()


def update_user_token(uid: str, refresh_token: str, expires_at: str):
    c = _conn()
    c.execute("UPDATE users SET refresh_token=?, refresh_token_expires_at=?, last_login_at=datetime('now'), login_attempts=0 WHERE id=?",
              (refresh_token, expires_at, uid))
    c.commit()


def increment_login_attempts(username: str):
    c = _conn()
    c.execute("UPDATE users SET login_attempts = login_attempts + 1 WHERE username=?", (username,))
    c.commit()


def clear_login_attempts(uid: str):
    c = _conn()
    c.execute("UPDATE users SET login_attempts=0 WHERE id=?", (uid,))
    c.commit()


# ── agent config ──
# 审计 P2-6：api_key 以 Fernet 密文落库，读取处解密；历史明文数据兼容回退，对外语义不变（调用方拿到的仍是 key 原值）。

def _decrypt_agent_api_key(stored: str) -> str:
    """审计 P2-6：解密库里存的 api_key。

    新写入的数据是 Fernet 密文；历史数据是明文，decrypt() 对非密文串返回空串，
    因此「解密为空但库里非空」时按明文回退读取。后续任意一次保存会自动转成密文。
    """
    if not stored:
        return ""
    plain = decrypt(stored)
    return plain if plain else stored


def get_agent_config(uid: str) -> dict:
    c = _conn()
    row = c.execute("SELECT api_key, model, api_base, agent_backend FROM user_agent_config WHERE user_id=?", (uid,)).fetchone()
    if row:
        return {"api_key": _decrypt_agent_api_key(row["api_key"]), "model": row["model"],
                "api_base": row["api_base"], "agent_backend": row["agent_backend"] or "legacy"}
    return {"api_key": "", "model": "deepseek-chat",
            "api_base": "https://api.deepseek.com/v1", "agent_backend": "legacy"}


def save_agent_config(uid: str, data: dict):
    c = _conn()
    # 审计 P2-6：写库前加密 api_key；空 key（未配置/管理员回落全局）保持空串不加密
    api_key = data.get("api_key", "")
    stored_key = encrypt(api_key) if api_key else ""
    c.execute("""
        INSERT INTO user_agent_config (user_id, api_key, model, api_base, created_at, updated_at)
        VALUES (?,?,?,?, datetime('now'), datetime('now'))
        ON CONFLICT(user_id) DO UPDATE SET
            api_key=excluded.api_key, model=excluded.model, api_base=excluded.api_base, updated_at=datetime('now')
    """, (uid, stored_key, data.get("model", "deepseek-chat"), data.get("api_base", "https://api.deepseek.com/v1")))
    c.commit()


# ── tool meta（统一工具目录的界面覆盖层：描述 / 启停）──

def get_tool_metas() -> dict:
    """返回全部工具元数据覆盖 {key: {"description": str|None, "enabled": bool}}。"""
    c = _conn()
    rows = c.execute("SELECT key, description, enabled FROM tool_meta").fetchall()
    return {
        r["key"]: {"description": r["description"], "enabled": bool(r["enabled"])}
        for r in rows
    }


def save_tool_meta(key: str, source: str, description: str | None, enabled: bool):
    """写入/更新某工具的覆盖元数据。description 传 None 表示回退代码默认描述。"""
    c = _conn()
    c.execute("""
        INSERT INTO tool_meta (key, source, description, enabled, updated_at)
        VALUES (?,?,?,?, datetime('now'))
        ON CONFLICT(key) DO UPDATE SET
            source=excluded.source,
            description=excluded.description,
            enabled=excluded.enabled,
            updated_at=datetime('now')
    """, (key, source, description, 1 if enabled else 0))
    c.commit()


# ── settings ──

def get_user_settings(uid: str) -> dict:
    c = _conn()
    row = c.execute("SELECT * FROM user_settings WHERE user_id=?", (uid,)).fetchone()
    if row:
        return dict(row)
    return {}


def save_user_settings(uid: str, data: dict):
    c = _conn()
    fields = ["user_id=?"]
    vals = [uid]
    for k, v in data.items():
        if k != "user_id":
            fields.append(f"{k}=?")
            vals.append(v)
    vals.append(uid)
    c.execute(f"""
        INSERT INTO user_settings (user_id, {', '.join(k for k in data if k != 'user_id')}, updated_at)
        VALUES (?,{', '.join(['?'] * sum(1 for k in data if k != 'user_id'))}, datetime('now'))
        ON CONFLICT(user_id) DO UPDATE SET
            {', '.join(f'{k}=excluded.{k}' for k in data if k != 'user_id')},
            updated_at=datetime('now')
    """, [uid] + [v for k, v in data.items() if k != 'user_id'])
    c.commit()


# ── indicators ──

def _row_to_indicator(row) -> dict:
    """将 SQLite Row 转为指标字典（解析 JSON 字段）"""
    d = dict(row)
    for field in [
        "tags", "sql_fragments", "sql_template_params", "event_source",
        "join_logic", "filter_conditions", "supported_filters", "business_scenarios",
        "input_tables", "dependencies", "test_cases", "common_mistakes",
        "known_edge_cases", "related_indicators", "change_log", "uncertain_fields",
    ]:
        if isinstance(d.get(field), str):
            try:
                d[field] = json.loads(d[field])
            except (json.JSONDecodeError, TypeError):
                d[field] = []
    return d


def create_indicator(uid: str, data: dict) -> dict:
    c = _conn()
    metric_id = data.get("metric_id", f"ind_{uuid.uuid4().hex[:10]}")
    now = datetime.utcnow().isoformat()
    json_fields = [
        "tags", "sql_fragments", "sql_template_params", "event_source",
        "join_logic", "filter_conditions", "supported_filters", "business_scenarios",
        "input_tables", "dependencies", "test_cases", "common_mistakes",
        "known_edge_cases", "related_indicators", "change_log", "uncertain_fields",
    ]
    values = {
        "user_id": uid, "metric_id": metric_id,
        "metric_name": data.get("metric_name", ""),
        "metric_alias": data.get("metric_alias", ""),
        "version": data.get("version", 1),
        "owner": data.get("owner", ""), "status": data.get("status", "draft"),
        "domain": data.get("domain", ""), "category": data.get("category", ""),
        "definition": data.get("definition", ""),
        "aggregation_type": data.get("aggregation_type", ""),
        "granularity": data.get("granularity", ""),
        "canonical_sql": data.get("canonical_sql", ""),
        "db_type": data.get("db_type", "mysql"),
        "window_size": data.get("window_size", ""),
        "refresh_frequency": data.get("refresh_frequency", ""),
        "data_latency": data.get("data_latency", ""),
        "from_macro_id": data.get("from_macro_id"),
        "source_sql": data.get("source_sql", ""),
    }
    for f in json_fields:
        val = data.get(f)
        if val is not None:
            values[f] = json.dumps(val, ensure_ascii=False) if not isinstance(val, str) else val
        else:
            values[f] = "[]"
    fields = ", ".join(values.keys())
    placeholders = ", ".join(["?"] * len(values))
    c.execute(
        f"INSERT INTO indicators ({fields}, created_at, updated_at) VALUES ({placeholders}, ?, ?)",
        list(values.values()) + [now, now],
    )
    c.commit()
    return get_indicator_by_metric_id(metric_id)


def update_indicator(indicator_id: int, data: dict) -> dict:
    c = _conn()
    now = datetime.utcnow().isoformat()
    updates = []
    vals = []
    json_fields = [
        "tags", "sql_fragments", "sql_template_params", "event_source",
        "join_logic", "filter_conditions", "supported_filters", "business_scenarios",
        "input_tables", "dependencies", "test_cases", "common_mistakes",
        "known_edge_cases", "related_indicators", "change_log", "uncertain_fields",
    ]
    for k, v in data.items():
        if k in ("id", "user_id", "metric_id", "created_at"):
            continue
        if k in json_fields and not isinstance(v, str):
            v = json.dumps(v, ensure_ascii=False)
        updates.append(f"{k}=?")
        vals.append(v)
    vals.append(now)
    vals.append(indicator_id)
    c.execute(f"UPDATE indicators SET {', '.join(updates)}, updated_at=? WHERE id=?", vals)
    c.commit()
    return get_indicator_by_id(indicator_id)


def delete_indicator(indicator_id: int):
    c = _conn()
    c.execute("DELETE FROM indicators WHERE id=?", (indicator_id,))
    c.commit()


def get_indicator_by_id(indicator_id: int):
    """获取指标（通过 id）"""
    c = _conn()
    row = c.execute("SELECT * FROM indicators WHERE id=?", (indicator_id,)).fetchone()
    return _row_to_indicator(row) if row else None


def get_indicator_by_metric_id(metric_id: str):
    """获取指标（通过 metric_id）"""
    c = _conn()
    row = c.execute("SELECT * FROM indicators WHERE metric_id=?", (metric_id,)).fetchone()
    return _row_to_indicator(row) if row else None


def get_indicators_by_source_sql(source_sql: str) -> list:
    """获取某 SQL 文件拆出的全部子指标（按 source_sql 反查，不按 user 过滤，与 metric_id 全局去重一致）。"""
    c = _conn()
    rows = c.execute(
        "SELECT * FROM indicators WHERE source_sql=? ORDER BY id ASC", (source_sql,)
    ).fetchall()
    return [_row_to_indicator(r) for r in rows]


def rename_sql_indicators(old_sql: str, new_sql: str) -> int:
    """SQL 改名后同步派生指标（审计建议 7）：source_sql 改新名，内嵌文件名的
    metric_id（sql_<主干> 或 sql_<主干>_<列> 约定，见 indicator_scan._child_metric_id）
    一并改；新 metric_id 撞已有 UNIQUE 时跳过该条（宁缺勿覆盖他人指标）。返回同步条数。
    """
    old_stem = old_sql[: -len(".sql")] if old_sql.endswith(".sql") else old_sql
    new_stem = new_sql[: -len(".sql")] if new_sql.endswith(".sql") else new_sql
    prefix = f"sql_{old_stem}"
    n = 0
    c = _conn()
    rows = c.execute("SELECT * FROM indicators WHERE source_sql=?", (old_sql,)).fetchall()
    for r in rows:
        mid = r["metric_id"] or ""
        new_mid = (f"sql_{new_stem}" + mid[len(prefix):]) if mid.startswith(prefix) else mid
        if new_mid != mid:
            clash = c.execute(
                "SELECT 1 FROM indicators WHERE metric_id=? AND id<>?", (new_mid, r["id"])
            ).fetchone()
            if clash:
                continue  # 目标 metric_id 已被占用（可能同名跨库 SQL 指标），跳过不覆盖
        c.execute(
            "UPDATE indicators SET source_sql=?, metric_id=?, updated_at=? WHERE id=?",
            (new_sql, new_mid, datetime.utcnow().isoformat(), r["id"]),
        )
        n += 1
    c.commit()
    return n


# ── SQL 派生指标的层级对齐（指标打通）：来源 SQL 为 通用/项目 的派生指标跟随 SQL 层级共享 ──

def _sql_scope(sql_name: str) -> tuple:
    """指标来源 SQL 的 (level, game)；文件不存在/读取异常返回 (None, None)。

    analysis 包由 backend/config.py 注入 sys.path，这里兜底再注入一次（独立 import 场景）。
    """
    name = (sql_name or "").strip()
    if not name:
        return None, None
    try:
        import sys as _sys
        from pathlib import Path as _P
        _ga = _P(__file__).resolve().parents[3]
        if str(_ga) not in _sys.path:
            _sys.path.insert(0, str(_ga))
        from analysis import sql_store as _ss
        return _ss.sql_scope(name)
    except Exception:
        return None, None


def indicator_share_scope(sql_name: str) -> str | None:
    """SQL 派生指标的共享范围：'通用' | '项目' | None（个人来源/无来源/文件缺失 → 个人隔离）。"""
    level, _game = _sql_scope(sql_name)
    return level if level in ("通用", "项目") else None


def _level_shared_permission(uid: str) -> str:
    """层级共享指标的可写性：持「新增/修改」分析权限（analysis_edit，同 SQL管理）可共建，否则只读。"""
    if not uid:
        return "read"
    try:
        user = get_user_by_id(uid)
        from . import permissions as _perms
        if user and _perms.has_perm(dict(user), "analysis_edit"):
            return "write"
    except Exception:
        pass
    return "read"


def list_indicators(uid: str, search: str = "", domain: str = "", status: str = "", tags: list = None, page: int = 1, size: int = 50, game: str = None) -> tuple:
    """列出当前用户可见的指标 = 本人 + 显式分享给我 + 层级共享（SQL 派生指标打通）。

    - 本人：user_id=uid，分页；
    - 显式分享：shared_items(item_type='indicator')，仅第 1 页并入（小集合）；
    - 层级共享：来源 SQL 为「通用」（全用户）或「项目」（按家族键同族可见，需传 game）的派生
      指标，跟随后台 SQL 的层级对齐——任何用户都能读到同一行（共建），写权限见 my_permission
      （analysis_edit → write）。个人级 SQL 派生 + 手工/聊天指标仍按 owner + 分享机制隔离。
    """
    c = _conn()
    filters = []
    fparams = []
    if search:
        filters.append("(metric_name LIKE ? OR metric_alias LIKE ? OR definition LIKE ?)")
        like = f"%{search}%"
        fparams.extend([like, like, like])
    if domain:
        filters.append("domain=?")
        fparams.append(domain)
    if status:
        filters.append("status=?")
        fparams.append(status)
    if tags:
        for tag in tags:
            filters.append("tags LIKE ?")
            fparams.append(f"%{tag}%")

    # 1. 本人指标（分页）
    where = ["user_id=?"] + filters
    params = [uid] + fparams
    where_clause = " AND ".join(where)
    count_row = c.execute(f"SELECT COUNT(*) as cnt FROM indicators WHERE {where_clause}", params).fetchone()
    own_total = count_row["cnt"] if count_row else 0
    offset = (page - 1) * size
    rows = c.execute(
        f"SELECT * FROM indicators WHERE {where_clause} ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        params + [size, offset],
    ).fetchall()
    own_items = []
    for r in rows:
        d = _row_to_indicator(r)
        d.update(share_role="owner", my_permission="write")
        # 本人持有的派生指标若来源 SQL 为 通用/项目，同样属于层级共享池（他人可见可共建），打标供前端展示
        level, _mg = _sql_scope(d.get("source_sql") or "")
        if level in ("通用", "项目"):
            d["source_level"] = level
        own_items.append(d)

    # Collaborative shared indicators (no pagination — typically small set)
    shared_rows = c.execute(
        "SELECT i.*, s.permission as _sp FROM indicators i "
        "JOIN shared_items s ON s.item_type='indicator' AND s.item_id=i.id "
        "WHERE s.shared_with_user_id=? ORDER BY i.updated_at DESC",
        (uid,),
    ).fetchall()
    shared_items = []
    for r in shared_rows:
        d = _row_to_indicator(r)
        d["share_role"] = "shared"
        d["my_permission"] = r["_sp"]
        shared_items.append(d)

    # 3. 层级共享（仅第 1 页并入，同显式分享口径）：user_id≠本人且带 source_sql 的派生指标，
    #    按来源 SQL 层级过滤——通用全可见；项目按家族键（family_key）同族可见，game 缺省时
    #    无法判定家族故不并入（宁可隐藏不扩散）；个人级 source_sql 不入共享池。
    level_items = []
    if page == 1:
        seen_ids = {i["id"] for i in own_items} | {i["id"] for i in shared_items}
        lw = ["user_id!=?", "source_sql!=''"] + filters
        lrows = c.execute(
            f"SELECT * FROM indicators WHERE {' AND '.join(lw)} ORDER BY updated_at DESC LIMIT 500",
            [uid] + fparams,
        ).fetchall()
        for r in lrows:
            d = _row_to_indicator(r)
            if d.get("id") in seen_ids:
                continue
            level, meta_game = _sql_scope(d.get("source_sql") or "")
            if level not in ("通用", "项目"):
                continue
            if level == "项目":
                try:
                    from analysis import games as _games
                    if _games.family_key(meta_game) != _games.family_key(game):
                        continue
                except Exception:
                    continue
            d["share_role"] = "level"
            d["source_level"] = level
            d["my_permission"] = _level_shared_permission(uid)
            level_items.append(d)
            seen_ids.add(d["id"])

    # Only return shared on first page
    combined = own_items + (shared_items if page == 1 else []) + level_items
    total = own_total + len(shared_items) + len(level_items)
    return combined, total


def get_indicators_by_ids(uid: str, ids: list[int]) -> list:
    """按 ID 列表批量获取指标（仅当前用户）"""
    if not ids:
        return []
    c = _conn()
    placeholders = ",".join(["?"] * len(ids))
    rows = c.execute(
        f"SELECT * FROM indicators WHERE user_id=? AND id IN ({placeholders})",
        [uid] + ids,
    ).fetchall()
    items = [_row_to_indicator(r) for r in rows]
    # 剥离服务端字段
    strip_keys = {"id", "metric_id", "user_id", "created_at", "updated_at", "from_macro_id"}
    for item in items:
        for k in list(item.keys()):
            if k in strip_keys or k in ("share_role", "my_permission"):
                item.pop(k, None)
    return items


def get_indicator_domains(uid: str, game: str = None) -> list:
    """指标域下拉 = 本人指标的域 + 层级共享指标（通用/项目同族）的域，便于按域筛选共享指标。"""
    c = _conn()
    rows = c.execute("SELECT DISTINCT domain FROM indicators WHERE user_id=? AND domain != '' ORDER BY domain", (uid,)).fetchall()
    domains = [r["domain"] for r in rows]
    lrows = c.execute(
        "SELECT DISTINCT domain, source_sql FROM indicators WHERE user_id!=? AND source_sql!='' AND domain!='' LIMIT 500",
        (uid,),
    ).fetchall()
    for r in lrows:
        if r["domain"] in domains:
            continue
        level, meta_game = _sql_scope(r["source_sql"])
        if level not in ("通用", "项目"):
            continue
        if level == "项目":
            try:
                from analysis import games as _games
                if _games.family_key(meta_game) != _games.family_key(game):
                    continue
            except Exception:
                continue
        domains.append(r["domain"])
    return domains


# ── indicator versions ──

def create_indicator_version(indicator_id: int, version: int, snapshot: str, change_comment: str = "", created_by: str = ""):
    c = _conn()
    c.execute("INSERT INTO indicator_versions (indicator_id, version, snapshot, change_comment, created_by) VALUES (?,?,?,?,?)",
              (indicator_id, version, snapshot, change_comment, created_by))
    c.commit()


def list_indicator_versions(indicator_id: int) -> list:
    c = _conn()
    rows = c.execute("SELECT * FROM indicator_versions WHERE indicator_id=? ORDER BY version DESC", (indicator_id,)).fetchall()
    return [dict(r) for r in rows]


# ── indicator folders ──

def create_indicator_folder(uid: str, name: str, parent_id: int = None) -> dict:
    c = _conn()
    c.execute("INSERT INTO indicator_folders (user_id, name, parent_id) VALUES (?,?,?)", (uid, name, parent_id))
    c.commit()
    row = c.execute("SELECT * FROM indicator_folders WHERE id=last_insert_rowid()").fetchone()
    return dict(row) if row else {"name": name}


def list_indicator_folders(uid: str) -> list:
    c = _conn()
    rows = c.execute("SELECT * FROM indicator_folders WHERE user_id=? ORDER BY sort_order, name", (uid,)).fetchall()
    return [dict(r) for r in rows]


def delete_indicator_folder(folder_id: int):
    c = _conn()
    c.execute("DELETE FROM indicator_folders WHERE id=?", (folder_id,))
    c.commit()


def rename_indicator_folder(folder_id: int, new_name: str):
    c = _conn()
    c.execute("UPDATE indicator_folders SET name=? WHERE id=?", (new_name, folder_id))
    c.commit()


# ── macros migration ──

def get_all_macros(uid: str) -> list:
    c = _conn()
    rows = c.execute("SELECT * FROM user_macros WHERE user_id=? ORDER BY created_at", (uid,)).fetchall()
    return [dict(r) for r in rows]


# ── Agent Conversation Summary ──

def get_conversation_summary(user_id: str, conn_id: str) -> Optional[str]:
    c = _conn()
    row = c.execute(
        "SELECT summary FROM agent_conversation_summary WHERE user_id=? AND conn_id=?",
        (user_id, conn_id),
    ).fetchone()
    return row["summary"] if row else None


def save_conversation_summary(user_id: str, conn_id: str, summary: str, message_count: int = 0):
    c = _conn()
    c.execute(
        """INSERT INTO agent_conversation_summary (user_id, conn_id, summary, message_count)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(user_id, conn_id) DO UPDATE SET
           summary=excluded.summary, message_count=excluded.message_count,
           updated_at=datetime('now')""",
        (user_id, conn_id, summary, message_count),
    )
    c.commit()


def delete_conversation_summary(user_id: str, conn_id: str):
    # 【坑 4（2026-10-21）】未接线、留作兜底：全库无调用方（会话摘要随 agent_chat_sessions
    # 一并清理），删除无版本化/回收站。若将来接线，须走删除侧版本化或软删。
    c = _conn()
    c.execute(
        "DELETE FROM agent_conversation_summary WHERE user_id=? AND conn_id=?",
        (user_id, conn_id),
    )
    c.commit()


# ── Agent Memory ──

MEM_TYPES = ("日常", "专项", "SQL", "知识库", "算法")
BIND_MAX_LEN = 100


def _normalize_mem_type(mem_type, bind_name):
    """记忆增强（2026-10-21 对抗审查收口）：类型白名单收敛 + 「日常⇒清空绑定」不变量。

    所有写入路径（create/update/agent 工具/API/导入/分享）的唯一归一化入口：
    strip + 非法值收敛为「日常」+ 绑定限长，保证任何入口产出的数据形态一致。
    """
    mt = str(mem_type or "").strip() or "日常"
    if mt not in MEM_TYPES:
        mt = "日常"
    bn = str(bind_name or "").strip()[:BIND_MAX_LEN]
    if mt == "日常":
        bn = ""
    return mt, bn


def get_memories(user_id: str = None, scope: str = "private", category: str = None, limit: int = 50,
                 order: str = "hit") -> list[dict]:
    """获取记忆列表。order="hit"（默认）按命中数+更新时间；order="recent" 按更新时间（召回池用，保证新记忆不被截断）"""
    c = _conn()
    conditions = []
    params = []
    if scope:
        conditions.append("scope=?")
        params.append(scope)
    if user_id:
        conditions.append("user_id=?")
        params.append(user_id)
    if category:
        conditions.append("category=?")
        params.append(category)
    where = " AND ".join(conditions) if conditions else "1=1"
    order_sql = "ORDER BY updated_at DESC" if order == "recent" else "ORDER BY hit_count DESC, updated_at DESC"
    rows = c.execute(
        f"SELECT * FROM agent_memory WHERE {where} {order_sql} LIMIT ?",
        params + [limit],
    ).fetchall()
    return [dict(r) for r in rows]


def search_memories(user_id: str = None, keyword: str = "", scope: str = None, limit: int = 10) -> tuple[list[dict], int]:
    """搜索记忆（关键词匹配 content）"""
    c = _conn()
    conditions = []
    params = []
    if user_id:
        conditions.append("user_id=?")
        params.append(user_id)
    if scope:
        conditions.append("scope=?")
        params.append(scope)
    if keyword:
        conditions.append("content LIKE ?")
        params.append(f"%{keyword}%")
    where = " AND ".join(conditions) if conditions else "1=1"
    total = c.execute(
        f"SELECT COUNT(*) as cnt FROM agent_memory WHERE {where}", params
    ).fetchone()["cnt"]
    # updated_at 可能不存在于旧库，降级用 created_at 排序
    order_col = "updated_at"
    try:
        c.execute(f"SELECT updated_at FROM agent_memory LIMIT 0")
    except Exception:
        order_col = "created_at"
    rows = c.execute(
        f"SELECT * FROM agent_memory WHERE {where} ORDER BY hit_count DESC, {order_col} DESC LIMIT ?",
        params + [limit],
    ).fetchall()
    return [dict(r) for r in rows], total


def create_memory(user_id: str, scope: str, category: str, content: str, key: str = None, source: str = "manual",
                  mem_type: str = "日常", bind_name: str = "") -> int:
    """创建一条记忆（记忆增强 2026-10-21：mem_type 类型打标 + bind_name 绑定资产，统一归一化入口）"""
    mt, bn = _normalize_mem_type(mem_type, bind_name)
    c = _conn()
    # updated_at 显式写入（对抗验证 2026-10-21 二轮）：旧库 ALTER 补列无默认值时，
    # 不写它会导致新行 updated_at=NULL、ORDER BY updated_at DESC 恒排末尾，
    # 大存量下被 recent 召回池 LIMIT 截断进不了召回。
    c.execute(
        """INSERT INTO agent_memory (user_id, scope, category, key, content, source, mem_type, bind_name, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))""",
        (user_id, scope, category, key, content, source, mt, bn),
    )
    c.commit()
    return c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]


def update_memory(memory_id: int, content: str = None, category: str = None, scope: str = None,
                  mem_type: str = None, bind_name: str = None):
    """更新记忆（记忆增强：类型/绑定与 create 走同一归一化，保证「日常⇒无绑定」不变量在改类型时生效）。

    对抗验证 2026-10-21 收口：
    - 空串（''/纯空格）视为「未提供」而非显式值，避免空串被归一化成「日常」并误清绑定；
    - SELECT+UPDATE 用 BEGIN IMMEDIATE 包成一个写事务，杜绝并发 PUT 各读旧快照后先后落库、
      让已清空的绑定「复活」破坏不变量的竞态；
    - 归一化结果与当前行不一致（含存量非法类型脏数据）也写回，历史脏行在一次更新后收敛。
    """
    mt_arg = str(mem_type).strip() if mem_type is not None else None
    mt_arg = mt_arg or None  # 空串 = 未提供
    bn_arg = str(bind_name).strip() if bind_name is not None else None
    bn_arg = bn_arg or None  # 空串 = 未提供
    c = _conn()
    # 对抗验证 2026-10-21 二轮：同一 thread-local 连接若残留先前请求泄漏的隐式事务
    # （外键违反等写异常发生在 BEGIN 后、commit 前），这里的 BEGIN IMMEDIATE 会抛
    # OperationalError 且失败在 try 外无法回滚——线程从此每条 update_memory 都 500。
    # 先滚掉泄漏事务再开新事务。
    if c.in_transaction:
        c.rollback()
    c.execute("BEGIN IMMEDIATE")
    try:
        row = c.execute("SELECT mem_type, bind_name FROM agent_memory WHERE id=?", (memory_id,)).fetchone()
        if row is None:
            c.rollback()
            return
        cur_mt = row["mem_type"] or "日常"
        cur_bn = row["bind_name"] or ""
        # 计算生效类型/绑定：只传其一也过同一归一化（如 专项→日常 时绑定自动清空）
        eff_bind = bn_arg if bn_arg is not None else cur_bn
        eff_mt, eff_bn = _normalize_mem_type(mt_arg if mt_arg is not None else cur_mt, eff_bind)

        updates = []
        params = []
        if content is not None:
            updates.append("content=?")
            params.append(content)
        if category is not None:
            updates.append("category=?")
            params.append(category)
        if scope is not None:
            updates.append("scope=?")
            params.append(scope)
        if mt_arg is not None or eff_mt != cur_mt:
            updates.append("mem_type=?")
            params.append(eff_mt)
        if bn_arg is not None or eff_bn != cur_bn:
            updates.append("bind_name=?")
            params.append(eff_bn)
        if not updates:
            c.rollback()
            return
        updates.append("updated_at=datetime('now')")
        params.append(memory_id)
        c.execute(
            f"UPDATE agent_memory SET {', '.join(updates)} WHERE id=?",
            params,
        )
        c.commit()
    except Exception:
        c.rollback()
        raise


def delete_memory(memory_id: int):
    """删除一条记忆"""
    c = _conn()
    c.execute("DELETE FROM agent_memory WHERE id=?", (memory_id,))
    c.commit()


def increment_memory_hit(memory_id: int):
    """增加记忆引用次数"""
    c = _conn()
    c.execute("UPDATE agent_memory SET hit_count = hit_count + 1 WHERE id=?", (memory_id,))
    c.commit()


def get_memories_by_ids(uid: str, ids: list[int]) -> list:
    """按 ID 列表批量获取记忆（仅当前用户）"""
    if not ids:
        return []
    c = _conn()
    placeholders = ",".join(["?"] * len(ids))
    rows = c.execute(
        f"SELECT * FROM agent_memory WHERE user_id=? AND id IN ({placeholders})",
        [uid] + ids,
    ).fetchall()
    items = [dict(r) for r in rows]
    strip_keys = {"id", "user_id", "key", "source", "hit_count", "created_at", "updated_at"}
    for item in items:
        for k in strip_keys:
            item.pop(k, None)
    return items


# ── feishu chat sessions (keyed by chat_id + sender_open_id) ──

def get_feishu_session(chat_id: str, sender_open_id: str = "") -> Optional[dict]:
    c = _conn()
    row = c.execute(
        "SELECT * FROM feishu_chat_sessions WHERE chat_id=? AND sender_open_id=?",
        (chat_id, sender_open_id),
    ).fetchone()
    return dict(row) if row else None


def create_feishu_session(chat_id: str, chat_type: str, user_id: str, conn_id: str,
                          sender_open_id: str = "", sender_name: str = "") -> dict:
    c = _conn()
    c.execute(
        """INSERT INTO feishu_chat_sessions
           (chat_id, chat_type, user_id, conn_id, messages, sender_open_id, sender_name, updated_at)
           VALUES (?,?,?,?,?,?,?,datetime('now'))""",
        (chat_id, chat_type, user_id, conn_id, "[]", sender_open_id, sender_name),
    )
    c.commit()
    return get_feishu_session(chat_id, sender_open_id)


def update_feishu_session_messages(chat_id: str, sender_open_id: str, messages: str):
    c = _conn()
    c.execute(
        "UPDATE feishu_chat_sessions SET messages=?, updated_at=datetime('now') WHERE chat_id=? AND sender_open_id=?",
        (messages, chat_id, sender_open_id),
    )
    c.commit()


def clear_feishu_session(chat_id: str, sender_open_id: str = ""):
    c = _conn()
    c.execute(
        "UPDATE feishu_chat_sessions SET messages='[]', skill_id='', skill_loop=0, updated_at=datetime('now') WHERE chat_id=? AND sender_open_id=?",
        (chat_id, sender_open_id),
    )
    c.commit()


def update_feishu_session_skill(chat_id: str, sender_open_id: str, skill_id: str, skill_loop: int):
    """更新会话的 skill loop 状态"""
    c = _conn()
    c.execute(
        "UPDATE feishu_chat_sessions SET skill_id=?, skill_loop=?, updated_at=datetime('now') WHERE chat_id=? AND sender_open_id=?",
        (skill_id, skill_loop, chat_id, sender_open_id),
    )
    c.commit()


def list_feishu_sessions(limit: int = 50) -> list:
    c = _conn()
    rows = c.execute(
        "SELECT * FROM feishu_chat_sessions ORDER BY updated_at DESC LIMIT ?", (limit,),
    ).fetchall()
    return [dict(r) for r in rows]


# ── feishu bot config ──

def get_feishu_bot_config() -> Optional[dict]:
    c = _conn()
    row = c.execute("SELECT * FROM feishu_bot_config WHERE is_active=1 ORDER BY id DESC LIMIT 1").fetchone()
    return dict(row) if row else None


def save_feishu_bot_config(data: dict):
    c = _conn()
    existing = c.execute("SELECT id FROM feishu_bot_config LIMIT 1").fetchone()
    if existing:
        updates, vals = [], []
        for f in ["app_id", "app_secret", "verification_token", "encrypt_key",
                   "mapped_user_id", "conn_id", "agent_backend", "is_active",
                   "long_connection_enabled"]:
            if f in data:
                updates.append(f"{f}=?")
                vals.append(data[f])
        updates.append("updated_at=datetime('now')")
        vals.append(existing["id"])
        c.execute(f"UPDATE feishu_bot_config SET {', '.join(updates)} WHERE id=?", vals)
    else:
        c.execute(
            """INSERT INTO feishu_bot_config
               (app_id, app_secret, verification_token, encrypt_key,
                mapped_user_id, conn_id, agent_backend, is_active, long_connection_enabled)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (data.get("app_id", ""), data.get("app_secret", ""),
             data.get("verification_token", ""), data.get("encrypt_key", ""),
             data.get("mapped_user_id", ""), data.get("conn_id", ""),
             data.get("agent_backend", "legacy"), 1,
             data.get("long_connection_enabled", 0)),
        )
    c.commit()


# ── feishu bot logs ──

def add_feishu_bot_log(event_id: str, chat_id: str, text: str, status: str,
                       error: str = "", duration: float = 0) -> int:
    c = _conn()
    c.execute(
        """INSERT INTO feishu_bot_logs (event_id, chat_id, text, status, error, duration)
           VALUES (?,?,?,?,?,?)""",
        (event_id, chat_id, text[:500], status, error[:1000], duration),
    )
    c.commit()
    return c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]


def list_feishu_bot_logs(chat_id: str = "", limit: int = 50) -> list:
    c = _conn()
    if chat_id:
        rows = c.execute(
            "SELECT * FROM feishu_bot_logs WHERE chat_id=? ORDER BY id DESC LIMIT ?",
            (chat_id, limit),
        ).fetchall()
    else:
        rows = c.execute(
            "SELECT * FROM feishu_bot_logs ORDER BY id DESC LIMIT ?", (limit,),
        ).fetchall()
    return [dict(r) for r in rows]


# ── Agent chat session history ──

def list_chat_sessions(user_id: str, conn_id: str, limit: int = 50) -> list[dict]:
    c = _conn()
    rows = c.execute(
        "SELECT id, title, description, msg_count, updated_at FROM agent_chat_sessions "
        "WHERE user_id=? AND conn_id=? ORDER BY updated_at DESC LIMIT ?",
        (user_id, conn_id, limit),
    ).fetchall()
    return [dict(r) for r in rows]


def save_chat_session(user_id: str, conn_id: str, title: str,
                      messages_json: str, msg_count: int,
                      session_id: int | None = None,
                      snapshot_json: str = "{}") -> int:
    c = _conn()
    now = datetime.utcnow().isoformat()
    if session_id:
        c.execute(
            "UPDATE agent_chat_sessions SET title=?, messages=?, msg_count=?, snapshot=?, updated_at=? "
            "WHERE id=? AND user_id=?",
            (title, messages_json, msg_count, snapshot_json, now, session_id, user_id),
        )
        c.commit()
        return session_id
    c.execute(
        "INSERT INTO agent_chat_sessions (user_id, conn_id, title, messages, msg_count, snapshot, created_at, updated_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (user_id, conn_id, title, messages_json, msg_count, snapshot_json, now, now),
    )
    c.commit()
    return c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]


def get_chat_session(user_id: str, session_id: int) -> dict | None:
    c = _conn()
    row = c.execute(
        "SELECT * FROM agent_chat_sessions WHERE id=? AND user_id=?",
        (session_id, user_id),
    ).fetchone()
    return dict(row) if row else None


def delete_chat_session(user_id: str, session_id: int) -> None:
    # 【坑 4（2026-10-21）】未接线、留作兜底：全库无调用方，删除无版本化/回收站。
    # 若将来接线，须走删除侧版本化或软删。
    c = _conn()
    c.execute("DELETE FROM agent_chat_sessions WHERE id=? AND user_id=?", (session_id, user_id))
    c.commit()


def set_chat_session_meta(user_id: str, session_id: int, title: str, description: str = "") -> None:
    """自动总结后更新会话标题与描述。"""
    c = _conn()
    c.execute(
        "UPDATE agent_chat_sessions SET title=?, description=?, updated_at=? WHERE id=? AND user_id=?",
        (title, description, datetime.utcnow().isoformat(), session_id, user_id),
    )
    c.commit()


# ── agent_memory helpers ──

def get_memory_by_id(memory_id: int) -> dict | None:
    c = _conn()
    row = c.execute("SELECT * FROM agent_memory WHERE id=?", (memory_id,)).fetchone()
    return dict(row) if row else None


# ── shared_items ──

def add_shared_item(item_type: str, item_id: int, owner_user_id: str,
                    shared_with_user_id: str, permission: str = "read") -> int:
    c = _conn()
    c.execute(
        "INSERT OR REPLACE INTO shared_items "
        "(item_type, item_id, owner_user_id, shared_with_user_id, permission) "
        "VALUES (?,?,?,?,?)",
        (item_type, item_id, owner_user_id, shared_with_user_id, permission),
    )
    c.commit()
    return c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]


def get_shared_permission(item_type: str, item_id: int, user_id: str) -> str | None:
    """Return 'read'/'write' if user has collaborative share access, else None."""
    c = _conn()
    row = c.execute(
        "SELECT permission FROM shared_items WHERE item_type=? AND item_id=? AND shared_with_user_id=?",
        (item_type, item_id, user_id),
    ).fetchone()
    return row["permission"] if row else None


def remove_shared_item(item_type: str, item_id: int, shared_with_user_id: str) -> None:
    c = _conn()
    c.execute(
        "DELETE FROM shared_items WHERE item_type=? AND item_id=? AND shared_with_user_id=?",
        (item_type, item_id, shared_with_user_id),
    )
    c.commit()


# ── 远程 MCP 服务器（通用配置层）───────────────────────────────────────────────

_REMOTE_MCP_FIELDS = (
    "name", "url", "transport", "command", "args_json", "env_encrypted",
    "auth_type", "auth_register_url", "auth_authorize_url", "auth_token_url",
    "auth_scope", "auth_resource",
)


def list_remote_mcp_servers(owner_user_id: str) -> list[dict]:
    """某 admin 自己配置的服务器。"""
    rows = _conn().execute(
        "SELECT * FROM user_remote_mcp_server WHERE owner_user_id=? ORDER BY created_at",
        (owner_user_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def list_remote_mcp_for_user(user_id: str) -> list[dict]:
    """该用户可用（自己配置的 + 被分享的）服务器，带 share_role / my_permission。"""
    c = _conn()
    own = c.execute(
        "SELECT * FROM user_remote_mcp_server WHERE owner_user_id=? ORDER BY created_at",
        (user_id,),
    ).fetchall()
    shared = c.execute(
        "SELECT s.*, si.permission AS _perm, si.owner_user_id AS _owner "
        "FROM user_remote_mcp_server s "
        "JOIN shared_items si ON si.item_type='remote_mcp' AND si.item_id=s.id "
        "WHERE si.shared_with_user_id=? ORDER BY s.created_at",
        (user_id,),
    ).fetchall()
    out = []
    for r in own:
        d = dict(r)
        d["share_role"] = "owner"
        d["my_permission"] = "write"
        out.append(d)
    for r in shared:
        d = dict(r)
        d["share_role"] = "shared"
        d["my_permission"] = d.pop("_perm", "read")
        d["shared_by_user_id"] = d.pop("_owner", "")
        out.append(d)
    return out


def get_remote_mcp_server(server_id: int) -> Optional[dict]:
    row = _conn().execute(
        "SELECT * FROM user_remote_mcp_server WHERE id=?", (server_id,)
    ).fetchone()
    return dict(row) if row else None


def upsert_remote_mcp_server(owner_user_id: str, data: dict) -> int:
    """按 name 全局 UPSERT，返回 server id。name 冲突且非本人所有时抛 ValueError。"""
    c = _conn()
    name = (data.get("name") or "").strip()
    existing = c.execute(
        "SELECT id, owner_user_id FROM user_remote_mcp_server WHERE name=?", (name,)
    ).fetchone()
    sid = data.get("id")
    if existing:
        if existing["owner_user_id"] != owner_user_id:
            raise ValueError(f"名称 {name} 已被其他管理员的服务器占用")
        sid = existing["id"]
    elif sid:
        owned = c.execute(
            "SELECT owner_user_id FROM user_remote_mcp_server WHERE id=?", (sid,)
        ).fetchone()
        if not owned or owned["owner_user_id"] != owner_user_id:
            raise ValueError("服务器不存在或无权修改")

    values = {
        "name": name,
        "url": data.get("url", "") or "",
        "transport": data.get("transport", "http") or "http",
        "command": data.get("command", "") or "",
        "args_json": json.dumps(data.get("args") or [], ensure_ascii=False),
        "env_encrypted": data.get("env_encrypted", "") or "",
        "auth_type": data.get("auth_type", "none") or "none",
        "auth_register_url": data.get("auth_register_url", "") or "",
        "auth_authorize_url": data.get("auth_authorize_url", "") or "",
        "auth_token_url": data.get("auth_token_url", "") or "",
        "auth_scope": data.get("auth_scope", "") or "",
        "auth_resource": data.get("auth_resource", "") or "",
    }
    if sid:
        sets = ", ".join(f"{f}=:{f}" for f in _REMOTE_MCP_FIELDS)
        c.execute(
            f"UPDATE user_remote_mcp_server SET {sets}, "
            "enabled=:enabled, updated_at=datetime('now') WHERE id=:id",
            {**values, "enabled": 1 if data.get("enabled", True) else 0, "id": sid},
        )
        c.commit()
        return sid
    cols = ", ".join(_REMOTE_MCP_FIELDS)
    ph = ", ".join(f":{f}" for f in _REMOTE_MCP_FIELDS)
    cur = c.execute(
        f"INSERT INTO user_remote_mcp_server (owner_user_id, enabled, {cols}) "
        f"VALUES (:owner_user_id, :enabled, {ph})",
        {**values, "owner_user_id": owner_user_id,
         "enabled": 1 if data.get("enabled", True) else 0},
    )
    c.commit()
    return cur.lastrowid


def update_remote_mcp_credentials(server_id: int, credentials_encrypted: str) -> None:
    c = _conn()
    c.execute(
        "UPDATE user_remote_mcp_server SET credentials_encrypted=?, updated_at=datetime('now') WHERE id=?",
        (credentials_encrypted, server_id),
    )
    c.commit()


def update_remote_mcp_redirect_uri(server_id: int, redirect_uri: str) -> None:
    c = _conn()
    c.execute(
        "UPDATE user_remote_mcp_server SET redirect_uri=?, updated_at=datetime('now') WHERE id=?",
        (redirect_uri, server_id),
    )
    c.commit()


def update_remote_mcp_env(server_id: int, env_encrypted: str) -> None:
    """写回 stdio 的 env（已加密）。"""
    c = _conn()
    c.execute(
        "UPDATE user_remote_mcp_server SET env_encrypted=?, updated_at=datetime('now') WHERE id=?",
        (env_encrypted or "", server_id),
    )
    c.commit()


def update_remote_mcp_probe(server_id: int, *, tools: Optional[list] = None,
                            status: str = "", error: str = "") -> None:
    """写回探测结果；tools=None 表示不更新工具清单（仅改状态）。"""
    c = _conn()
    sets = ["last_status=?", "last_error=?", "last_checked_at=datetime('now')"]
    params: list = [status, error]
    if tools is not None:
        sets += ["tools_json=?", "tools_count=?"]
        params += [json.dumps(tools, ensure_ascii=False), len(tools)]
    params.append(server_id)
    c.execute(f"UPDATE user_remote_mcp_server SET {', '.join(sets)} WHERE id=?", params)
    c.commit()


def set_remote_mcp_enabled(server_id: int, enabled: bool) -> None:
    c = _conn()
    c.execute(
        "UPDATE user_remote_mcp_server SET enabled=?, updated_at=datetime('now') WHERE id=?",
        (1 if enabled else 0, server_id),
    )
    c.commit()


def delete_remote_mcp_server(server_id: int) -> None:
    """删除服务器，并清掉它的所有分享授权行。"""
    c = _conn()
    c.execute("DELETE FROM shared_items WHERE item_type='remote_mcp' AND item_id=?", (server_id,))
    c.execute("DELETE FROM user_remote_mcp_server WHERE id=?", (server_id,))
    c.commit()


def list_remote_mcp_shares(server_id: int) -> list[str]:
    """该服务器已分享给的用户 id 列表。"""
    rows = _conn().execute(
        "SELECT shared_with_user_id FROM shared_items WHERE item_type='remote_mcp' AND item_id=?",
        (server_id,),
    ).fetchall()
    return [r["shared_with_user_id"] for r in rows]


def remove_remote_mcp_share(server_id: int, shared_with_user_id: str) -> None:
    remove_shared_item("remote_mcp", server_id, shared_with_user_id)


# ── BI 平台配置 ──────────────────────────────────────────────────────────────

def get_bi_config(user_id: str, key: str) -> Optional[str]:
    """读取 BI 平台配置项（per-user）。"""
    row = _conn().execute(
        "SELECT value FROM bi_platform_config WHERE user_id=? AND key=?", (user_id, key)
    ).fetchone()
    return row["value"] if row else None


def set_bi_config(user_id: str, key: str, value: str) -> None:
    """写入或更新 BI 平台配置项（per-user）。"""
    c = _conn()
    c.execute(
        "INSERT INTO bi_platform_config (user_id, key, value, updated_at) VALUES (?, ?, ?, datetime('now')) "
        "ON CONFLICT(user_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        (user_id, key, value),
    )
    c.commit()


# ── Joydata MCP OAuth 凭据（per-user，Fernet 加密）────────────────────────────

def get_joydata_auth(user_id: str) -> Optional[dict]:
    """读取某用户的 Joydata OAuth 凭据（token 已解密）；未连接返回 None。"""
    row = _conn().execute(
        "SELECT user_id, access_token, refresh_token, client_id, expires_at, connected_at, updated_at "
        "FROM joydata_auth WHERE user_id=?", (user_id,)
    ).fetchone()
    if not row:
        return None
    from backend.ide_app.core.crypto import decrypt

    return {
        "user_id": row["user_id"],
        "access_token": decrypt(row["access_token"] or ""),
        "refresh_token": decrypt(row["refresh_token"] or ""),
        "client_id": row["client_id"] or "",
        "expires_at": int(row["expires_at"] or 0),
        "connected_at": row["connected_at"],
        "updated_at": row["updated_at"],
    }


def save_joydata_auth(user_id: str, access_token: str, refresh_token: str,
                      expires_at: int, client_id: str = "",
                      expect_updated_at: Optional[str] = None) -> bool:
    """写入/更新某用户的 Joydata OAuth 凭据（token 加密后落库）。

    expect_updated_at 给定 = 条件保存：仅当行仍处于该 updated_at 时写回。
    refresh 期间用户点了「断开」（行已删/已重连）→ 返回 False，调用方据此
    放弃写回，避免把已断开的连接「死而复生」。未给定 = 常规 upsert，恒返回 True。

    updated_at 用毫秒精度：否则同一秒内的 断开→重连 会让条件更新命中新行。
    """
    from backend.ide_app.core.crypto import encrypt

    c = _conn()
    enc_a, enc_r = encrypt(access_token or ""), encrypt(refresh_token or "")
    if expect_updated_at is not None:
        cur = c.execute(
            "UPDATE joydata_auth SET access_token=?, refresh_token=?, client_id=?, "
            "expires_at=?, updated_at=strftime('%Y-%m-%d %H:%M:%f','now') "
            "WHERE user_id=? AND updated_at=?",
            (enc_a, enc_r, client_id or "", int(expires_at or 0), user_id, expect_updated_at),
        )
        c.commit()
        return cur.rowcount > 0
    c.execute(
        "INSERT INTO joydata_auth (user_id, access_token, refresh_token, client_id, expires_at, connected_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, datetime('now'), strftime('%Y-%m-%d %H:%M:%f','now')) "
        "ON CONFLICT(user_id) DO UPDATE SET access_token=excluded.access_token, "
        "refresh_token=excluded.refresh_token, client_id=excluded.client_id, "
        "expires_at=excluded.expires_at, "
        "updated_at=excluded.updated_at",
        (user_id, enc_a, enc_r, client_id or "", int(expires_at or 0)),
    )
    c.commit()
    return True


def delete_joydata_auth(user_id: str) -> None:
    """断开某用户的 Joydata 连接（删除凭据）。"""
    c = _conn()
    c.execute("DELETE FROM joydata_auth WHERE user_id=?", (user_id,))
    c.commit()


# ── 数据库 ↔ BI 项目 映射（全局，admin 维护）────────────────────────────────────

def get_bi_project_for_database(database_name: str) -> Optional[str]:
    """读取全局映射：数据库名 → project_id。"""
    row = _conn().execute(
        "SELECT project_id FROM bi_project_mapping WHERE database_name=?", (database_name,)
    ).fetchone()
    return row["project_id"] if row else None


def set_bi_project_for_database(database_name: str, project_id: str) -> None:
    """写入或更新全局映射（UPSERT）。"""
    c = _conn()
    c.execute(
        "INSERT INTO bi_project_mapping (database_name, project_id, updated_at) VALUES (?, ?, datetime('now')) "
        "ON CONFLICT(database_name) DO UPDATE SET project_id=excluded.project_id, updated_at=excluded.updated_at",
        (database_name, project_id),
    )
    c.commit()


def delete_bi_project_for_database(database_name: str) -> None:
    c = _conn()
    c.execute("DELETE FROM bi_project_mapping WHERE database_name=?", (database_name,))
    c.commit()


def list_bi_project_mappings() -> list[dict]:
    rows = _conn().execute(
        "SELECT database_name, project_id, updated_at FROM bi_project_mapping ORDER BY database_name"
    ).fetchall()
    return [dict(r) for r in rows]


def get_connection_database(conn_id: str) -> Optional[str]:
    """读取连接行当前 database_name（切库时 switch_connection_db 会写回）。"""
    row = _conn().execute(
        "SELECT database_name FROM user_connections WHERE id=?", (conn_id,)
    ).fetchone()
    return row["database_name"] if row else None
