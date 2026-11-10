"""重导出 shim：自然语言 → SQL 生成的逻辑已上收共享包 analysis/sql_gen。

保留本模块只为兼容 data_ai 内既有 `from ..services import sql_gen` 的 import；
新代码请直接 `from analysis import sql_gen`，或经 analysis.agents.run_agent("sql") 调用。
"""
from analysis.sql_gen import build_messages, generate_sql

__all__ = ["build_messages", "generate_sql"]
