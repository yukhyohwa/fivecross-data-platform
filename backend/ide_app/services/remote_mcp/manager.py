"""远程 MCP 服务器运行时：token 续期、mcp_servers 构造、OAuth 编排、工具探测。

设计要点（与计划一致）：
- claude-agent-sdk 的 McpHttpServerConfig 只支持 url+headers，没有 token provider
  回调，所以无法在 SDK 内部处理 401→refresh→retry。改为每轮对话开始前按
  REMOTE_MCP_REFRESH_SKEW_S 提前量预刷。
- 服务器由 admin 配置、经 shared_items 分享给成员，所以凭据属于 owner，
  但任何被分享者的对话都可能触发续期 —— 锁必须按 server_id 而不是 user。
- OAuth 的 _pending 由本模块持有，环回 listener 与 HTTP 路由共用同一份。
"""
import asyncio
import json
import logging
import secrets
import time

import httpx

from backend.ide_app.core.settings import settings
from backend.ide_app.services.db_service import (
    get_remote_mcp_server,
    list_remote_mcp_for_user,
    update_remote_mcp_probe,
    update_remote_mcp_redirect_uri,
)

from . import oauth
from .store import get_credentials, save_credentials

logger = logging.getLogger(__name__)

_MCP_PROTOCOL_VERSION = "2025-06-18"
_PROBE_TIMEOUT_S = 30

# 进行中的授权会话：state -> PendingAuth
_pending: dict[str, dict] = {}
# 已完成会话的结果（state -> {"user_id", "result", "at"}）。
# 环回 listener 完成交换时 _pending 已被 pop，前端还要轮询拿结果，所以另存一份短 TTL 缓存。
_results: dict[str, dict] = {}
# 续期串行锁，按 server_id（凭据是共享的）
_locks: dict[int, asyncio.Lock] = {}
# 环回 listener 的实际端口（callback_server 启动后回填）
_callback_port: int = 0

def _pending_ttl() -> int:
    return int(getattr(settings, "REMOTE_MCP_PENDING_TTL_S", 600) or 600)


def _refresh_skew() -> int:
    return int(getattr(settings, "REMOTE_MCP_REFRESH_SKEW_S", 900) or 900)


def _lock_for(server_id: int) -> asyncio.Lock:
    lock = _locks.get(server_id)
    if lock is None:
        lock = asyncio.Lock()
        _locks[server_id] = lock
    return lock


def set_callback_port(port: int) -> None:
    global _callback_port
    _callback_port = port


def get_callback_port() -> int:
    return _callback_port


def gc_pending() -> None:
    """清理过期授权会话（授权码约 10 分钟失效）。"""
    now = time.time()
    ttl = _pending_ttl()
    for st in [s for s, p in _pending.items() if now - p["created_at"] > ttl]:
        _pending.pop(st, None)
    for st in [s for s, r in _results.items() if now - r["at"] > ttl]:
        _results.pop(st, None)


# ── token 续期 ───────────────────────────────────────────────────────────────

async def get_valid_access_token(row: dict) -> str:
    """返回可用的 access token；失败写回 needs_auth 状态并返回 ''。

    返回空串时调用方应跳过该 server —— 本轮少几个工具，而不是让 CLI 卡死。
    """
    creds = get_credentials(row)
    if not creds:
        return ""
    auth_type = row.get("auth_type") or "none"

    if auth_type == "bearer":
        return creds.get("access_token", "")

    if auth_type != "oauth2":
        return ""

    now = int(time.time())
    if creds.get("access_token") and now < int(creds.get("expires_at") or 0) - _refresh_skew():
        return creds["access_token"]

    server_id = row["id"]
    async with _lock_for(server_id):
        # 双重检查：等锁期间可能已被别的协程刷新
        fresh = get_credentials(get_remote_mcp_server(server_id) or row)
        if fresh.get("access_token") and now < int(fresh.get("expires_at") or 0) - _refresh_skew():
            return fresh["access_token"]

        refresh_token = fresh.get("refresh_token")
        if not refresh_token:
            _mark_needs_auth(server_id, "缺少 refresh_token，请重新授权")
            return ""
        try:
            resp = await oauth.refresh_access_token(
                row.get("auth_token_url") or "",
                refresh_token=refresh_token,
                client_id=fresh.get("client_id", ""),
            )
        except oauth.OAuthError as e:
            # 90 天 refresh token 过期/被撤销 → invalid_grant
            fresh.pop("access_token", None)
            save_credentials(server_id, fresh)
            _mark_needs_auth(server_id, f"授权已失效（{e}），请重新授权")
            return ""
        except Exception as e:
            # 网络异常（超时/连不上/DNS）：只是这一轮拿不到 token，授权本身可能仍然有效，
            # 不能标成 needs_auth 逼用户重新授权。
            logger.warning("remote_mcp: refresh failed for server %s: %s", server_id, e)
            update_remote_mcp_probe(server_id, tools=None, status="error",
                                    error=f"刷新 token 失败（网络）：{str(e)[:200]}")
            return ""
        merged = oauth.merge_token_response(fresh, resp)
        save_credentials(server_id, merged)
        logger.info("remote_mcp: refreshed token for server %s", server_id)
        return merged.get("access_token", "")


def _mark_needs_auth(server_id: int, message: str) -> None:
    update_remote_mcp_probe(server_id, tools=None, status="needs_auth", error=message[:300])


# ── 工具探测 ─────────────────────────────────────────────────────────────────

def _rpc_headers(token: str) -> dict:
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def _parse_rpc(resp: httpx.Response) -> dict:
    """Streamable HTTP 可能返回 application/json，也可能是 text/event-stream。"""
    ctype = resp.headers.get("content-type", "")
    if "text/event-stream" in ctype:
        for line in resp.text.splitlines():
            if line.startswith("data:"):
                payload = line[5:].strip()
                if payload:
                    return json.loads(payload)
        raise ValueError("SSE 响应中没有 data 行")
    return resp.json()


async def probe_server(row: dict) -> dict:
    """探测远端工具清单，写回 tools_json / 状态。返回 {ok, tools_count, tools, error}。

    刻意不引入 mcp SDK（major 版本漂移），直接走 JSON-RPC over Streamable HTTP。
    """
    server_id = row["id"]
    if (row.get("transport") or "http").lower() == "stdio":
        return {"ok": False, "error": "stdio 传输暂不支持在线探测"}

    token = ""
    if (row.get("auth_type") or "none") != "none":
        token = await get_valid_access_token(row)
        if not token:
            return {"ok": False, "error": "凭据不可用，请重新授权"}

    url = row.get("url") or ""
    if not url:
        return {"ok": False, "error": "未配置服务器地址"}

    try:
        async with httpx.AsyncClient(timeout=_PROBE_TIMEOUT_S) as c:
            init = await c.post(url, headers=_rpc_headers(token), json={
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {
                    "protocolVersion": _MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "chat-bi", "version": "0.1.0"},
                },
            })
            if init.status_code in (401, 403):
                raise oauth.OAuthError(f"远端返回 {init.status_code}", init.status_code,
                                       init.text[:300])
            if init.status_code >= 400:
                raise ValueError(f"initialize 失败 HTTP {init.status_code}: {init.text[:200]}")
            session_id = init.headers.get("mcp-session-id")
            headers = _rpc_headers(token)
            if session_id:
                headers["mcp-session-id"] = session_id
            await c.post(url, headers=headers, json={
                "jsonrpc": "2.0", "method": "notifications/initialized"})
            lst = await c.post(url, headers=headers, json={
                "jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            if lst.status_code >= 400:
                raise ValueError(f"tools/list 失败 HTTP {lst.status_code}: {lst.text[:200]}")
            body = _parse_rpc(lst)

        tools = [
            {
                "name": t.get("name", ""),
                "description": (t.get("description") or "")[:300],
                "inputSchema": t.get("inputSchema") or t.get("input_schema")
                or {"type": "object", "properties": {}},
            }
            for t in ((body.get("result") or {}).get("tools") or [])
            if t.get("name")
        ]
        update_remote_mcp_probe(server_id, tools=tools, status="ok", error="")
        return {"ok": True, "tools_count": len(tools), "tools": tools}
    except Exception as e:
        message = str(e)[:300]
        status = "needs_auth" if isinstance(e, oauth.OAuthError) else "error"
        update_remote_mcp_probe(server_id, tools=None, status=status, error=message)
        return {"ok": False, "error": message}


# ── OAuth 编排 ───────────────────────────────────────────────────────────────

async def start_oauth(row: dict, owner_user_id: str, redirect_uri: str) -> dict:
    """确保 client_id 可用（必要时 DCR）+ 生成 PKCE + 记住待处理会话。"""
    server_id = row["id"]
    creds = get_credentials(row)
    if not creds.get("client_id") or creds.get("redirect_uri") != redirect_uri:
        # redirect_uri 变了（比如端口回退）必须重新注册，否则授权码换 token 会失败
        reg = await oauth.register_client(
            row.get("auth_register_url") or "", redirect_uri, client_name="SQL IDE"
        )
        creds = dict(creds)
        creds["client_id"] = reg["client_id"]
        if reg.get("client_secret"):
            creds["client_secret"] = reg["client_secret"]
        creds["redirect_uri"] = redirect_uri
        save_credentials(server_id, creds)

    gc_pending()
    verifier, challenge = oauth.pkce_pair()
    state = secrets.token_hex(16)
    _pending[state] = {
        "user_id": owner_user_id,
        "server_id": server_id,
        "verifier": verifier,
        "client_id": creds["client_id"],
        "redirect_uri": redirect_uri,
        "created_at": time.time(),
        "result": None,
    }
    update_remote_mcp_redirect_uri(server_id, redirect_uri)
    return {
        "authorize_url": oauth.build_authorize_url(
            row.get("auth_authorize_url") or "",
            client_id=creds["client_id"],
            redirect_uri=redirect_uri,
            scope=row.get("auth_scope") or "",
            state=state,
            code_challenge=challenge,
            resource=row.get("auth_resource") or "",
        ),
        "state": state,
    }


def get_pending(state: str, user_id: str) -> dict:
    gc_pending()
    pend = _pending.get(state)
    if not pend or pend["user_id"] != user_id:
        return {}
    return pend


def peek_pending(state: str) -> dict:
    """不校验用户，仅判断 state 是否存在（环回 listener 用）。"""
    gc_pending()
    return _pending.get(state) or {}


def pending_status(state: str, user_id: str) -> dict:
    gc_pending()
    pend = _pending.get(state)
    if pend:
        if pend["user_id"] != user_id:
            return {"status": "forbidden"}
        result = pend.get("result")
        if result is None:
            return {"status": "pending"}
        return {"status": "ok" if result.get("ok") else "error", **result}
    # 会话已完成（_pending 已被 pop）—— 结果从短期缓存里取，否则前端会把成功
    # 误判成「会话已过期」。
    done = _results.get(state)
    if done:
        if done["user_id"] != user_id:
            return {"status": "forbidden"}
        result = done["result"]
        return {"status": "ok" if result.get("ok") else "error", **result}
    return {"status": "expired"}


async def complete_oauth(state: str, code: str) -> dict:
    """环回 listener 与「粘贴回调 URL」两条路径的唯一汇合点。"""
    gc_pending()
    pend = _pending.pop(state, None)   # 单次使用
    if not pend:
        raise oauth.OAuthError("授权会话不存在或已过期，请重新发起授权")

    server_id = pend["server_id"]
    row = get_remote_mcp_server(server_id)
    if not row:
        raise oauth.OAuthError("服务器已被删除")

    try:
        tok = await oauth.exchange_code(
            row.get("auth_token_url") or "",
            code=code,
            client_id=pend["client_id"],
            redirect_uri=pend["redirect_uri"],
            code_verifier=pend["verifier"],
        )
    except oauth.OAuthError as e:
        update_remote_mcp_probe(server_id, tools=None, status="error",
                                error=f"换取 token 失败：{e}"[:300])
        _results[state] = {"user_id": pend["user_id"],
                           "result": {"ok": False, "error": str(e)[:300]},
                           "at": time.time()}
        raise

    creds = get_credentials(row)
    creds.update(tok)
    creds["client_id"] = pend["client_id"]
    creds["token_url"] = row.get("auth_token_url") or ""
    creds["redirect_uri"] = pend["redirect_uri"]
    creds["obtained_at"] = int(time.time())
    creds["expires_at"] = creds["obtained_at"] + int(tok.get("expires_in", 7200))
    save_credentials(server_id, creds)

    probe = await probe_server(get_remote_mcp_server(server_id) or row)
    result = {"ok": bool(probe.get("ok")), "server_id": server_id,
              "tools_count": probe.get("tools_count", 0), "error": probe.get("error", "")}
    _results[state] = {"user_id": pend["user_id"], "result": result, "at": time.time()}
    return result


def set_pending_result(state: str, result: dict) -> None:
    """环回 listener 完成交换后回填，供前端轮询 oauth/status。

    _pending 此时已被 complete_oauth pop 掉，所以同时写进 _results。
    """
    pend = _pending.get(state)
    if pend:
        pend["result"] = result
        user_id = pend["user_id"]
    else:
        user_id = (_results.get(state) or {}).get("user_id", "")
    if user_id:
        _results[state] = {"user_id": user_id, "result": result, "at": time.time()}


def abort_pending(state: str) -> None:
    _pending.pop(state, None)


# ── 深度分析并入：工具清单 + tools/call（手写 FC 循环复用，不经 SDK）──────────

def list_remote_tools(user_id: str) -> list[dict]:
    """返回该用户启用服务器的完整工具清单（含 inputSchema），供深度分析注册 FC 工具。

    每条 {"server", "name", "description", "input_schema", "server_row"}。
    tools_json 由 probe_server 探测后写回（已含 inputSchema）。
    """
    out: list[dict] = []
    for row in list_remote_mcp_for_user(user_id):
        if not row.get("enabled"):
            continue
        name = row.get("name") or ""
        if not name:
            continue
        try:
            tools = json.loads(row.get("tools_json") or "[]")
        except Exception:
            tools = []
        for t in tools:
            tname = t.get("name") or ""
            if not tname:
                continue
            out.append({
                "server": name,
                "name": tname,
                "description": t.get("description") or "",
                "input_schema": t.get("inputSchema") or t.get("input_schema")
                or {"type": "object", "properties": {}},
                "server_row": row,
            })
    return out


def find_server_by_name(user_id: str, name: str) -> dict | None:
    """按服务器名找该用户启用中的服务器行；不存在/未启用返回 None。"""
    for row in list_remote_mcp_for_user(user_id):
        if (row.get("name") or "") == name and row.get("enabled"):
            return row
    return None


def _extract_mcp_content(result: dict) -> dict:
    """把 MCP tools/call 的 result 折叠成 {text, is_error, raw}，text 为可读文本。"""
    content = result.get("content") or []
    texts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(block.get("text") or "")
    return {
        "text": "\n".join(texts),
        "is_error": bool(result.get("isError")),
        "raw": result,
    }


async def call_remote_tool(row: dict, tool_name: str, arguments: dict) -> dict:
    """对远程 MCP 服务器发起 tools/call（JSON-RPC over Streamable HTTP）。

    返回 agent_tools 约定结构：{"ok": True, "result": {...}} 或 {"ok": False, "error": ...}。
    stdio 传输不支持在线调用（与 probe_server 一致，跳过）。
    """
    if (row.get("transport") or "http").lower() == "stdio":
        return {"ok": False, "error": "stdio 传输暂不支持在线调用"}

    token = ""
    if (row.get("auth_type") or "none") != "none":
        token = await get_valid_access_token(row)
        if not token:
            return {"ok": False, "error": "凭据不可用，请重新授权"}

    url = row.get("url") or ""
    if not url:
        return {"ok": False, "error": "未配置服务器地址"}

    try:
        async with httpx.AsyncClient(timeout=_PROBE_TIMEOUT_S) as c:
            init = await c.post(url, headers=_rpc_headers(token), json={
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {
                    "protocolVersion": _MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "chat-bi", "version": "0.1.0"},
                },
            })
            if init.status_code in (401, 403):
                raise oauth.OAuthError(f"远端返回 {init.status_code}", init.status_code,
                                       init.text[:300])
            if init.status_code >= 400:
                raise ValueError(f"initialize 失败 HTTP {init.status_code}: {init.text[:200]}")
            session_id = init.headers.get("mcp-session-id")
            headers = _rpc_headers(token)
            if session_id:
                headers["mcp-session-id"] = session_id
            await c.post(url, headers=headers, json={
                "jsonrpc": "2.0", "method": "notifications/initialized"})
            call = await c.post(url, headers=headers, json={
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments or {}},
            })
            if call.status_code >= 400:
                raise ValueError(f"tools/call 失败 HTTP {call.status_code}: {call.text[:200]}")
            body = _parse_rpc(call)

        if "error" in body:
            return {"ok": False, "error": json.dumps(body["error"], ensure_ascii=False)[:500]}
        result = body.get("result") or {}
        return {"ok": True, "result": _extract_mcp_content(result)}
    except oauth.OAuthError as e:
        return {"ok": False, "error": f"授权失败（{e}），请重新授权"}
    except Exception as e:
        return {"ok": False, "error": str(e)[:500]}
