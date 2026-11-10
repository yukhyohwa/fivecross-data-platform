"""远程 MCP 服务器凭据读写（Fernet 加密接缝）+ name 校验 + API 出口视图。

凭据一律加密后存进 user_remote_mcp_server.credentials_encrypted；
public_view() 是唯一的对 API 出口，永不含明文凭据。
"""
import json
import re

from backend.ide_app.core.crypto import decrypt, encrypt
from backend.ide_app.services.db_service import (
    get_remote_mcp_server,
    update_remote_mcp_credentials,
    update_remote_mcp_env,
)

NAME_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
# 保留名：不能覆盖 in-process 的 sqlide MCP server
RESERVED_NAMES = {"sqlide"}

# stdio transport 的 command allowlist —— 用户可控 command+args 等于后端主机任意
# 代码执行，非 allowlist 一律拒绝（配合 API 层的 admin-only 双重收紧）。
STDIO_ALLOWED_COMMANDS = {"uvx", "npx", "python", "python3", "node", "docker"}


def validate_name(name: str) -> str:
    """校验并归一化 server name（它同时是工具前缀 mcp__<name>__<tool>）。"""
    n = (name or "").strip().lower()
    if not NAME_RE.match(n):
        raise ValueError("名称只能包含小写字母、数字、下划线、连字符，长度 1-32")
    if n in RESERVED_NAMES:
        raise ValueError(f"名称 {n} 为系统保留名")
    return n


def validate_stdio(command: str) -> str:
    """校验 stdio command 在 allowlist 内。"""
    cmd = (command or "").strip()
    if not cmd:
        raise ValueError("stdio 传输必须填写 command")
    base = cmd.replace("\\", "/").rsplit("/", 1)[-1].lower()
    if base.endswith(".exe"):
        base = base[:-4]
    if base.endswith(".cmd") or base.endswith(".bat"):
        base = base[:-4]
    if base not in STDIO_ALLOWED_COMMANDS:
        raise ValueError(
            f"command {base} 不在允许列表内（{', '.join(sorted(STDIO_ALLOWED_COMMANDS))}）"
        )
    return cmd


def get_credentials(row: dict) -> dict:
    """解密凭据 JSON；无凭据或解密失败返回 {}。"""
    if not row:
        return {}
    raw = decrypt(row.get("credentials_encrypted") or "")
    if not raw:
        return {}
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_credentials(server_id: int, creds: dict) -> None:
    update_remote_mcp_credentials(
        server_id, encrypt(json.dumps(creds, ensure_ascii=False))
    )


def get_server_credentials(server_id: int) -> dict:
    return get_credentials(get_remote_mcp_server(server_id))


def save_env(server_id: int, env: dict) -> None:
    update_remote_mcp_env(
        server_id, encrypt(json.dumps(env, ensure_ascii=False)) if env else ""
    )


def public_view(row: dict) -> dict:
    """API 出口视图：带状态位，永不返回凭据本身。"""
    creds = get_credentials(row)
    try:
        tools = json.loads(row.get("tools_json") or "[]")
    except Exception:
        tools = []
    return {
        "id": row["id"],
        "name": row["name"],
        "url": row.get("url") or "",
        "transport": row.get("transport") or "http",
        "command": row.get("command") or "",
        "auth_type": row.get("auth_type") or "none",
        "auth_register_url": row.get("auth_register_url") or "",
        "auth_authorize_url": row.get("auth_authorize_url") or "",
        "auth_token_url": row.get("auth_token_url") or "",
        "auth_scope": row.get("auth_scope") or "",
        "auth_resource": row.get("auth_resource") or "",
        "enabled": bool(row.get("enabled")),
        "shared_by_user_id": row.get("shared_by_user_id", ""),
        "share_role": row.get("share_role", "owner"),
        "my_permission": row.get("my_permission", "write"),
        "has_credentials": bool(creds.get("access_token") or creds.get("refresh_token")),
        "has_refresh_token": bool(creds.get("refresh_token")),
        "credential_expires_at": creds.get("expires_at"),
        "tools": tools,
        "tools_count": row.get("tools_count") or 0,
        "last_status": row.get("last_status") or "",
        "last_error": row.get("last_error") or "",
        "last_checked_at": row.get("last_checked_at"),
    }
