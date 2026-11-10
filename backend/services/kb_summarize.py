"""重导出 shim：知识库 / 专项 / SQL / 订阅生成的逻辑已上收共享包 analysis/kb_gen。

保留本模块只为兼容 data_ai 内既有 `from ..services import kb_summarize` 的 import；
新代码请直接 `from analysis import kb_gen`，或经 analysis.agents.run_agent("kb"/"skill") 调用。
"""
from analysis.kb_gen import (
    extract_title,
    summarize,
    summarize_chat,
    summarize_skill,
    summarize_to_sql,
    summarize_to_subscription,
)

__all__ = [
    "extract_title",
    "summarize",
    "summarize_chat",
    "summarize_skill",
    "summarize_to_sql",
    "summarize_to_subscription",
]
