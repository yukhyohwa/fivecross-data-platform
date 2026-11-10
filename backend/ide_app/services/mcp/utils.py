"""MCP 工具结果安全提取 — 统一类型检查 + traceback 日志。

所有调用点统一使用 safe_extract_data / safe_extract_text，
当 result["content"] 类型异常时自动输出完整调用栈和上下文。
"""

import traceback
import logging

logger = logging.getLogger("mcp_utils")


def safe_extract_data(result: dict, caller: str = "") -> dict:
    """安全提取 MCP 工具结果中的 data 部分。

    当 content 是字符串而非 list[dict] 时，输出完整 traceback，
    精确定位调用方文件和行号，然后返回空 dict 避免崩溃。

    Args:
        result: MCP 工具返回的 dict，格式 {"content": [{"type":"text",...}, {"type":"json","data":{...}}]}
        caller: 调用方标识，如 "estimate_row_count"、"_dispatch_mcp:query_database"
    """
    content = result.get("content", [])
    if not isinstance(content, list):
        logger.warning(
            "[safe_extract_data] content 类型异常: type=%s caller=%s value_preview=%s",
            type(content).__name__,
            caller,
            str(content)[:200],
        )
        traceback.print_stack()
        return {}
    if len(content) > 1 and isinstance(content[1], dict):
        return content[1].get("data", {})
    if len(content) > 0 and isinstance(content[0], dict):
        return content[0].get("data", {})
    logger.warning(
        "[safe_extract_data] content 无法提取 data: len=%d caller=%s types=%s",
        len(content),
        caller,
        [type(c).__name__ for c in content[:3]],
    )
    traceback.print_stack()
    return {}


def safe_extract_text(result: dict, caller: str = "") -> str:
    """安全提取 MCP 工具结果中的 text 部分。

    Args:
        result: MCP 工具返回的 dict
        caller: 调用方标识
    """
    content = result.get("content", [])
    if not isinstance(content, list):
        logger.warning(
            "[safe_extract_text] content 类型异常: type=%s caller=%s",
            type(content).__name__,
            caller,
        )
        traceback.print_stack()
        return str(content)
    if len(content) > 0 and isinstance(content[0], dict):
        return content[0].get("text", "")
    return ""


def safe_check_item(obj, context: str, item_type: type = dict):
    """检查集合中单个元素类型，异常时输出 traceback。

    用于 build_system_prompt 等遍历 tables/indicators 的场景。

    Args:
        obj: 待检查的对象
        context: 上下文标识，如 "build_system_prompt:tables"
        item_type: 期望的类型，默认 dict
    """
    if not isinstance(obj, item_type):
        logger.warning(
            "[safe_check_item] 类型异常: expected=%s got=%s context=%s value=%s",
            item_type.__name__,
            type(obj).__name__,
            context,
            str(obj)[:200],
        )
        traceback.print_stack()
        return False
    return True
