"""
SQL IDE MCP Gateway — 轻量 MCP 协议实现（SSE + JSON-RPC 2.0）

遵循 Model Context Protocol 标准：
- SSE (Server-Sent Events) 用于服务端推送
- HTTP POST 用于客户端请求
- JSON-RPC 2.0 消息格式

支持 Tools:
- query_database: 执行 SQL SELECT 查询（绑游戏库）
- list_tables: 列出表
- describe_table: 获取表结构
- search_columns: 搜索字段
- 指标：get_indicator_detail / update_indicator / rollback_indicator
- FiveCross 查询与指标管理工具
"""

import asyncio
import json
import logging
import time
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

logger = logging.getLogger("mcp")

# ── 导入所有 Tool 定义和执行函数 ──
# 数据库工具改绑游戏库（tools_game 复用 data_ai 深度分析取数），连接/写库能力已退役。
from backend.ide_app.services.mcp.tools_game import (
    TOOL_QUERY_DATABASE,
    TOOL_LIST_TABLES,
    TOOL_DESCRIBE_TABLE,
    TOOL_SEARCH_COLUMNS,
    query_database,
    list_tables as exec_list_tables,
    describe_table as exec_describe_table,
    search_columns as exec_search_columns,
    _ctx_game_user,
)
from backend.ide_app.services.mcp.tools_indicator import (
    TOOL_GET_INDICATOR_DETAIL,
    TOOL_UPDATE_INDICATOR,
    TOOL_ROLLBACK_INDICATOR,
    get_indicator_detail,
    update_indicator_mcp,
    rollback_indicator,
)

# ── 所有可用 Tools 注册表 ──
TOOL_REGISTRY = {
    "query_database": {
        "definition": TOOL_QUERY_DATABASE,
        "handler": query_database,
    },
    "list_tables": {
        "definition": TOOL_LIST_TABLES,
        "handler": exec_list_tables,
    },
    "describe_table": {
        "definition": TOOL_DESCRIBE_TABLE,
        "handler": exec_describe_table,
    },
    "search_columns": {
        "definition": TOOL_SEARCH_COLUMNS,
        "handler": exec_search_columns,
    },
    "get_indicator_detail": {
        "definition": TOOL_GET_INDICATOR_DETAIL,
        "handler": get_indicator_detail,
    },
    "update_indicator": {
        "definition": TOOL_UPDATE_INDICATOR,
        "handler": update_indicator_mcp,
    },
    "rollback_indicator": {
        "definition": TOOL_ROLLBACK_INDICATOR,
        "handler": rollback_indicator,
    },


}


# ── Router ──

router = APIRouter(prefix="/api/mcp", tags=["mcp"])


def _auth_user(http_request: Request) -> dict:
    """MCP 网关鉴权：Bearer JWT（access）→ 用户存在且未禁用。

    供 SSE 与 POST 共用；与 backend.deps.get_current_user 同口径（无匿名回落，MCP 严格要求登录）。
    """
    from backend.ide_app.core.auth import decode_token
    from backend.ide_app.services.db_service import get_user_by_id

    auth_header = http_request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="未认证")
    payload = decode_token(auth_header[7:])
    if not payload or payload.get("type") != "access":
        raise HTTPException(status_code=401, detail="Token 无效或已过期")
    user = get_user_by_id(payload.get("sub"))
    if not user or not user.get("is_active", 1):
        raise HTTPException(status_code=401, detail="用户不存在或已禁用")
    return dict(user)


@router.get("/tools")
async def list_mcp_tools():
    """返回所有已注册 MCP 工具的名称和描述（无需鉴权）"""
    return [
        {"name": name, "description": info["definition"]["description"]}
        for name, info in TOOL_REGISTRY.items()
    ]


class JSONRPCRequest(BaseModel):
    """JSON-RPC 2.0 请求模型"""
    jsonrpc: str = "2.0"
    method: str
    id: Optional[str] = None
    params: Optional[dict] = None


# ── SSE 连接管理 ──

# 存储活跃的 SSE 连接队列
_sse_queues: dict[str, asyncio.Queue] = {}


def _jsonrpc_error(code: int, message: str, req_id=None) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": code, "message": message},
    }


def _jsonrpc_result(result: dict, req_id=None) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": result,
    }


# ── SSE 端点 ──

@router.get("")
async def mcp_sse(request: Request):
    """MCP SSE 端点 — 客户端通过 SSE 接收服务端事件（需 Bearer 认证，与 POST 同口径）"""
    user = _auth_user(request)
    _ctx_game_user.set(user)

    session_id = str(uuid.uuid4())
    queue: asyncio.Queue = asyncio.Queue()
    _sse_queues[session_id] = queue

    # 清理函数
    async def cleanup():
        _sse_queues.pop(session_id, None)

    async def event_stream():
        try:
            # 1. 发送 endpoint 事件（告诉客户端 POST 地址）
            yield f"event: endpoint\ndata: {json.dumps({'endpoint': f'/api/mcp?session_id={session_id}'})}\n\n"

            # 2. 发送工具列表
            tools = [t["definition"] for t in TOOL_REGISTRY.values()]
            yield f"event: tools/list\ndata: {json.dumps(_jsonrpc_result({'tools': tools}))}\n\n"

            # 3. 持续监听队列，转发响应
            while True:
                try:
                    message = await asyncio.wait_for(queue.get(), timeout=30.0)
                    yield f"event: message\ndata: {json.dumps(message)}\n\n"
                except asyncio.TimeoutError:
                    # 发送心跳保持连接
                    yield f": heartbeat\n\n"

        except asyncio.CancelledError:
            pass
        finally:
            await cleanup()

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ── POST 端点（接收客户端请求） ──

@router.post("")
async def mcp_post(request: JSONRPCRequest, http_request: Request):
    """MCP POST 端点 — 接收客户端的 JSON-RPC 请求（需 Bearer 认证）"""
    user = _auth_user(http_request)
    _ctx_game_user.set(user)

    method = request.method
    req_id = request.id
    params = request.params or {}

    # 处理 tools/list
    if method == "tools/list":
        tools = [t["definition"] for t in TOOL_REGISTRY.values()]
        return _jsonrpc_result({"tools": tools}, req_id)

    # 处理 tools/call
    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        if tool_name not in TOOL_REGISTRY:
            return _jsonrpc_error(-32601, f"未知 Tool: {tool_name}", req_id)

        # BI 工具需要 user_id 做用户隔离
        if False:  # Legacy BI integration disabled.
            from backend.ide_app.services.mcp.tools_bi import _ctx_bi_user_id, _ctx_conn_id
            _ctx_bi_user_id.set(user.get("id", ""))
            # MCP 网关无数据库上下文，显式清空 conn_id（用默认 project_id）
            _ctx_conn_id.set(None)

        # Joydata 工具需要 user_id 做用户隔离（per-user OAuth 凭据）
        if False:  # Legacy JoyData integration disabled.
            _ctx_joydata_user_id.set(user.get("id", ""))

        # flexsql 转换需按当前用户解析个人 LLM Key（避免外部 MCP 客户端越权走系统默认 Key）
        _ctx_flexsql_user_id.set(user.get("id", ""))

        tool = TOOL_REGISTRY[tool_name]
        handler = tool["handler"]

        try:
            # 异步执行 handler
            result = await handler(**arguments)

            # 如果有 session_id，通过 SSE 推送结果
            session_id = http_request.query_params.get("session_id")
            if session_id and session_id in _sse_queues:
                await _sse_queues[session_id].put(
                    _jsonrpc_result(result, req_id)
                )
                return {"accepted": True}

            # 无 SSE 连接时直接返回
            return _jsonrpc_result(result, req_id)

        except Exception as e:
            logger.exception(f"Tool {tool_name} 执行失败")
            return _jsonrpc_error(-32603, str(e), req_id)

    # 方法不存在
    return _jsonrpc_error(-32601, f"未知方法: {method}", req_id)
