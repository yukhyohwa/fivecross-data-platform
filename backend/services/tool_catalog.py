"""全后台统一工具目录：data_ai 深度分析工具 + sql-ide MCP 工具合并为一份清单。

两类来源：
- chatbi：data_ai 深度分析 agent 工具（agent_tools.TOOL_SCHEMAS，绑游戏库）。
- mcp：sql-ide MCP 网关工具（mcp_gateway.TOOL_REGISTRY，走 JSON-RPC tools/call）。

同名且 MCP 侧 handler 直接委托 chatbi handler 的工具（query_database 等，两者是同一执行面）以 chatbi 为唯一来源。旧外部报表模板执行面已停用，不进入目录。
"""
from . import agent_tools
from . import ide_bridge  # 复用 ide_app 的 tool_meta 表
from backend.ide_app.services.mcp_gateway import TOOL_REGISTRY  # noqa: E402

# 同名去重白名单：仅限「MCP handler 委托 chatbi handler」的工具（同一执行面，双行纯重复）。
# 独立扩展执行面不在默认名单内 → 目录保留 chatbi:: 与 mcp:: 两行。
_MCP_DELEGATES_TO_CHATBI = frozenset({"query_database", "list_tables", "describe_table", "search_columns"})


def build_catalog() -> list[dict]:
    """合并两来源工具，应用 tool_meta 覆盖，返回 [{key,name,description,source,enabled,edited}]。"""
    metas = ide_bridge.db_service.get_tool_metas()

    def _item(source: str, name: str, default_desc: str) -> dict:
        key = f"{source}::{name}"
        meta = metas.get(key)
        if meta:
            description = meta.get("description") or default_desc
            enabled = meta.get("enabled", True)
            edited = True
        else:
            description = default_desc
            enabled = True
            edited = False
        return {
            "key": key,
            "name": name,
            "description": description,
            "source": source,
            "enabled": enabled,
            "edited": edited,
        }

    items: list[dict] = []
    chatbi_names: set[str] = set()
    for t in agent_tools.list_tool_metas():
        chatbi_names.add(t["name"])
        items.append(_item("chatbi", t["name"], t["description"]))
    for name, info in TOOL_REGISTRY.items():
        if name in chatbi_names and name in _MCP_DELEGATES_TO_CHATBI:
            continue  # 同名且 MCP 侧委托 chatbi handler：同一执行面，仅保留 chatbi:: 行
        items.append(_item("mcp", name, info["definition"]["description"]))
    return items
