"""游戏库 MCP Tools — 复用 FiveCross 深度分析同一套取数；表名、时区和金额字段必须来自当前项目真实 schema。

外部 MCP 客户端（Claude Desktop / Cursor）经 /api/mcp JSON-RPC 查的是游戏库，与深度分析
同一口径，不再绑用户连接（conn_id 已退役）。`game` 参数可选，缺省回落默认游戏。

游戏越权保护：调用方（MCP 网关）先设置 _ctx_game_user（登录用户 dict），
_ctx 按 effective_games 校验 game 参数；内部 agent 直调（未设 ctx → 匿名全放行）不受影响。
"""
import contextvars
import json

# 当前请求用户（MCP 网关在鉴权后注入；内部调用缺省 {} = 匿名 → 全放行）
_ctx_game_user: contextvars.ContextVar[dict] = contextvars.ContextVar("mcp_game_user", default={})

# ── Tool 定义（无 conn_id，game 可选）──

TOOL_QUERY_DATABASE = {
    "name": "query_database",
    "description": "在游戏数据库上执行一条只读 SQL（SELECT/WITH）。务必写聚合查询（GROUP BY）；"
    "表名和字段必须来自当前项目真实 schema；本地备份只能使用已登记文件口径，不得生成云端 SQL。",
    "inputSchema": {
        "type": "object",
        "properties": {
            "game": {"type": "string", "description": "游戏 key（如 kof / kof_sea），缺省用默认游戏"},
            "sql": {"type": "string", "description": "只读 SQL（SELECT/WITH）"},
            "max_rows": {"type": "integer", "description": "最多取多少行，默认 5000（超限报错）"},
        },
        "required": ["sql"],
    },
}

TOOL_LIST_TABLES = {
    "name": "list_tables",
    "description": "列出当前游戏库的表名（最多 300 个）。",
    "inputSchema": {
        "type": "object",
        "properties": {
            "game": {"type": "string", "description": "游戏 key，缺省用默认游戏"},
        },
    },
}

TOOL_DESCRIBE_TABLE = {
    "name": "describe_table",
    "description": "查看某张表的列结构（列名/类型/注释）。",
    "inputSchema": {
        "type": "object",
        "properties": {
            "game": {"type": "string", "description": "游戏 key，缺省用默认游戏"},
            "table": {"type": "string", "description": "表名"},
        },
        "required": ["table"],
    },
}

TOOL_SEARCH_COLUMNS = {
    "name": "search_columns",
    "description": "按列名模糊搜索字段，定位某个字段在哪张表（如 recharge/pay/price）。",
    "inputSchema": {
        "type": "object",
        "properties": {
            "game": {"type": "string", "description": "游戏 key，缺省用默认游戏"},
            "keyword": {"type": "string", "description": "字段名关键词"},
        },
        "required": ["keyword"],
    },
}


# ── 执行函数（复用 backend.services.agent_tools 的 handler）──

def _ctx(game: str | None = None) -> dict:
    from backend.deps import get_engine
    from backend.ide_app.services.permissions import effective_games
    from backend.services import games as games_svc

    user = _ctx_game_user.get() or {}
    requested = (game or "").strip()
    allowed = effective_games(user)
    if "*" not in allowed:
        # 非全游戏用户：显式指定无权限游戏 → 拒绝；未指定 → 回退到允许集内第一个（与 get_game 同口径）
        if requested and requested not in allowed:
            raise ValueError(f"无游戏权限：{requested}（允许：{'、'.join(allowed) or '无'}）")
        if not allowed:
            raise ValueError("您没有任何游戏的数据权限，无法查询数据，请联系管理员开通")
        if not requested:
            requested = allowed[0]
    engine = get_engine()
    g = games_svc.resolve(requested, engine)
    return {"engine": engine, "game": g, "user_id": "", "user": user}


def _wrap(result: dict) -> dict:
    return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, default=str)}]}


def _err(e: Exception) -> dict:
    return {"isError": True, "content": [{"type": "text", "text": str(e)}]}


async def query_database(game: str = None, sql: str = "", max_rows: int = 5000) -> dict:
    from backend.services import agent_tools as at

    try:
        return _wrap(at.query_database(_ctx(game), sql, max_rows=int(max_rows or 5000)))
    except Exception as e:
        return _err(e)


async def list_tables(game: str = None) -> dict:
    from backend.services import agent_tools as at

    try:
        return _wrap(at.list_tables(_ctx(game)))
    except Exception as e:
        return _err(e)


async def describe_table(game: str = None, table: str = "") -> dict:
    from backend.services import agent_tools as at

    try:
        return _wrap(at.describe_table(_ctx(game), table))
    except Exception as e:
        return _err(e)


async def search_columns(game: str = None, keyword: str = "") -> dict:
    from backend.services import agent_tools as at

    try:
        return _wrap(at.search_columns(_ctx(game), keyword))
    except Exception as e:
        return _err(e)
