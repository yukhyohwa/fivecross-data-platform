"""Import legacy JSON data into SQLite for an admin user."""
import datetime
import json
import sqlite3
import uuid
from .core.crypto import encrypt
from .services.db_service import (
    init_db, create_user, save_agent_config,
)
from .core.auth import hash_password
from .core.paths import APP_DIR  # 审计 P2-4：遗留 JSON 数据源随数据目录迁到项目 data_ai/data/.sql-ide

DATA_DIR = APP_DIR


# ── 退役套件内联（审计 P1-10：db_service 的连接/历史/macros 函数已删除，仅此迁移脚本需要）──

def _list_connections(uid: str) -> list[dict]:
    from .services.db_service import _conn
    c = _conn()
    rows = c.execute(
        "SELECT id, name, host, port, user_name, database_name, db_type, charset, "
        "use_ssh, ssh_host, ssh_port, ssh_user, ssh_key_path, created_at, updated_at "
        "FROM user_connections WHERE user_id=? ORDER BY updated_at DESC", (uid,)
    ).fetchall()
    return [dict(r) for r in rows]


def _save_connection(uid: str, data: dict) -> str:
    from .services.db_service import _conn
    c = _conn()
    conn_id = data.get("id", str(uuid.uuid4())[:8])
    now = datetime.datetime.utcnow().isoformat()
    c.execute("""
        INSERT INTO user_connections (id, user_id, name, host, port, user_name, password_encrypted,
            database_name, db_type, charset, use_ssh, ssh_host, ssh_port, ssh_user, ssh_password_encrypted, ssh_key_path, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, host=excluded.host, port=excluded.port,
            user_name=excluded.user_name, password_encrypted=excluded.password_encrypted,
            database_name=excluded.database_name, db_type=excluded.db_type, charset=excluded.charset,
            use_ssh=excluded.use_ssh, ssh_host=excluded.ssh_host, ssh_port=excluded.ssh_port,
            ssh_user=excluded.ssh_user, ssh_password_encrypted=excluded.ssh_password_encrypted,
            ssh_key_path=excluded.ssh_key_path, updated_at=excluded.updated_at
    """, (
        conn_id, uid, data["name"], data["host"], data.get("port", 3306),
        data.get("user_name", ""), data.get("password_encrypted", ""),
        data.get("database_name", ""), data.get("db_type", "mysql"),
        data.get("charset", "utf8mb4"), data.get("use_ssh", 0),
        data.get("ssh_host"), data.get("ssh_port", 22),
        data.get("ssh_user"), data.get("ssh_password_encrypted", ""),
        data.get("ssh_key_path"), now, now,
    ))
    c.commit()
    return conn_id


def _create_macro(uid: str, data: dict) -> str:
    from .services.db_service import _conn
    c = _conn()
    mid = str(uuid.uuid4())[:8]
    now = datetime.datetime.utcnow().isoformat()
    c.execute(
        "INSERT INTO user_macros (id, user_id, name, sql_text, description, folder, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
        (mid, uid, data["name"], data.get("sql_text", ""), data.get("description", ""), data.get("folder", "默认"), now, now),
    )
    c.commit()
    return mid


def _create_macro_folder(uid: str, name: str):
    from .services.db_service import _conn
    c = _conn()
    try:
        c.execute("INSERT INTO user_macro_folders (user_id, folder_name) VALUES (?,?)", (uid, name))
        c.commit()
    except sqlite3.IntegrityError:
        pass


def _add_history(uid: str, entry: dict):
    from .services.db_service import _conn
    c = _conn()
    hid = str(uuid.uuid4())[:8]
    c.execute(
        "INSERT INTO user_query_history (id, user_id, connection_id, connection_name, sql_text, duration, row_count, executed_at) VALUES (?,?,?,?,?,?,?,?)",
        (hid, uid, entry.get("connection_id"), entry.get("connection_name", ""), entry.get("sql_text", ""),
         entry.get("duration", 0), entry.get("row_count", 0), entry.get("executed_at", datetime.datetime.utcnow().isoformat())),
    )
    c.commit()


def _seed_default_connections(uid: str):
    """Seed two default database connections for admin user.

    Only seeds if the user has zero connections (idempotent).
    Update host / port / user / password to match your environment.
    """
    existing = _list_connections(uid)
    if existing:
        return  # already has connections, skip

    defaults = [
        {
            "id": "default_mysql",
            "name": "本地 MySQL",
            "host": "127.0.0.1",
            "port": 3306,
            "user_name": "root",
            "password_encrypted": encrypt(""),
            "database_name": "",
            "db_type": "mysql",
            "charset": "utf8mb4",
        },
        {
            "id": "default_mysql_ssh",
            "name": "远程 MySQL (SSH)",
            "host": "127.0.0.1",
            "port": 3306,
            "user_name": "root",
            "password_encrypted": encrypt(""),
            "database_name": "",
            "db_type": "mysql",
            "charset": "utf8mb4",
            "use_ssh": 1,
            "ssh_host": "your-ssh-host",
            "ssh_port": 22,
            "ssh_user": "root",
            "ssh_password_encrypted": encrypt(""),
            "ssh_key_path": "",
        },
    ]
    for cfg in defaults:
        _save_connection(uid, cfg)
    print(f"[migration] Seeded {len(defaults)} default connections for admin")


def run_migration():
    """Migrate legacy JSON files to DB if they exist and no users exist yet."""
    init_db()  # ensure tables exist
    from .services.db_service import _conn
    c = _conn()
    existing = c.execute("SELECT COUNT(*) as cnt FROM users").fetchone()
    if existing and existing["cnt"] > 0:
        return  # already migrated

    # Create admin user
    admin_pwd = "123456"
    admin = create_user("admin", hash_password(admin_pwd))
    # Set role to admin
    from .services.db_service import _conn
    c = _conn()
    c.execute("UPDATE users SET role='admin' WHERE id=?", (admin["id"],))
    c.commit()
    uid = admin["id"]

    # ── Default connections for admin ──
    _seed_default_connections(uid)

    has_data = False

    # Connections
    conn_file = DATA_DIR / "connections.json"
    if conn_file.exists():
        try:
            conns = json.loads(conn_file.read_text())
            for cid, cfg in conns.items():
                _save_connection(uid, {
                    "id": cid,
                    "name": cfg.get("name", ""),
                    "host": cfg.get("host", "localhost"),
                    "port": cfg.get("port", 3306),
                    "user_name": cfg.get("user", ""),
                    "password_encrypted": encrypt(cfg.get("password", "")),
                    "database_name": cfg.get("database", ""),
                    "db_type": cfg.get("db_type", "mysql"),
                    "charset": cfg.get("charset", "utf8mb4"),
                    "use_ssh": 1 if cfg.get("use_ssh") else 0,
                    "ssh_host": cfg.get("ssh_host"),
                    "ssh_port": cfg.get("ssh_port", 22),
                    "ssh_user": cfg.get("ssh_user"),
                    "ssh_password_encrypted": encrypt(cfg.get("ssh_password", "")),
                    "ssh_key_path": cfg.get("ssh_key_path"),
                })
            has_data = True
            print(f"[migration] Imported {len(conns)} connections")
        except Exception as e:
            print(f"[migration] Connections import error: {e}")

    # Macros
    macro_file = DATA_DIR / "macros.json"
    if macro_file.exists():
        try:
            data = json.loads(macro_file.read_text())
            folders = set()
            for k, v in data.items():
                if isinstance(v, dict) and v.get("id"):
                    _create_macro(uid, {
                        "name": v.get("name", ""),
                        "sql_text": v.get("sql", ""),
                        "description": v.get("description", ""),
                        "folder": v.get("folder", "默认"),
                    })
                    if v.get("folder") and v["folder"] != "/":
                        folders.add(v["folder"])
            for f in folders:
                _create_macro_folder(uid, f)
            has_data = True
            print(f"[migration] Imported macros")
        except Exception as e:
            print(f"[migration] Macros import error: {e}")

    # History
    hist_file = DATA_DIR / "history.json"
    if hist_file.exists():
        try:
            items = json.loads(hist_file.read_text())
            for h in items[:200]:  # limit to 200 entries
                _add_history(uid, {
                    "connection_id": "",
                    "connection_name": h.get("connection_name", ""),
                    "sql_text": h.get("sql", ""),
                    "duration": h.get("duration", 0),
                    "row_count": h.get("row_count", 0),
                    "executed_at": h.get("executed_at"),
                })
            has_data = True
            print(f"[migration] Imported {min(len(items), 200)} history entries")
        except Exception as e:
            print(f"[migration] History import error: {e}")

    # Agent config
    agent_file = DATA_DIR / "agent_config.json"
    if agent_file.exists():
        try:
            cfg = json.loads(agent_file.read_text())
            save_agent_config(uid, cfg)
            has_data = True
            print(f"[migration] Imported agent config")
        except Exception as e:
            print(f"[migration] Agent config import error: {e}")

    if has_data:
        print(f"[migration] Done. Admin user: admin / {admin_pwd}")
    else:
        print("[migration] No legacy data found")


def cleanup_glossary_memories():
    """记忆重组（2026-10-23）：术语表回归系统级唯一来源（knowledge/glossary.md）。

    历史 /api/memory/import-glossary 一次性迁移曾把 glossary.md 逐行复制成
    category='术语' 的记忆行（每人一份、scope=global）；该端点已移除，术语注入改由
    schema_context（SQL 生成）与深度分析 system prompt 直接读 glossary.md。
    这些记忆行只是文件副本（原文件完整保留），每次启动幂等清除，避免旧术语副本
    继续污染个人记忆召回池。删除范围（对抗审查 2026-10-23 二轮）：source IN
    ('glossary', 'shared', 'import')——记忆复制/共享机制（share/import）会把
    这些行二次复制成新 source 逃逸清理；三者都是机制产物而非用户手建，用户手建
    的「术语」分类记忆（其它 source）不受影响。
    """
    from .services.db_service import _conn
    try:
        c = _conn()
        cur = c.execute(
            "DELETE FROM agent_memory WHERE category='术语' AND source IN ('glossary', 'shared', 'import')"
        )
        c.commit()
        if cur.rowcount:
            print(f"[migration] Removed {cur.rowcount} legacy glossary memory rows (术语表回归系统级来源)")
    except Exception as e:
        print(f"[migration] Glossary memory cleanup error (non-fatal): {e}")
