"""数据库 schema 探查：读 information_schema 的库/表/列。

目标库（config.DEFAULT_TARGET_DB）有 900+ 张表，因此 SQL 生成只取「核心表」：
- 前端 schema 浏览走 list_tables / list_columns，按需懒加载（不缓存，避免大库占用内存）；
- chat 流程走 load_core_schema，按 config.core_table_patterns 过滤后查列，仅缓存核心表。
"""
import threading

from analysis.db import run_raw_sql

from .. import config

_lock = threading.Lock()
_core_cache: dict[str, dict[str, list[dict]]] = {}  # db -> {table: [columns]}
_core_total: dict[str, int] = {}                    # db -> 全库表总数


def _q(s: str) -> str:
    """把标识符/名称安全地嵌进 SQL 字符串字面量（转义单引号）。"""
    return "'" + s.replace("'", "''") + "'"


def list_databases(engine) -> list[str]:
    try:
        df = run_raw_sql(
            engine, "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name"
        )
    except Exception:
        # FiveCross external clients do not expose the reference project's
        # information_schema. Chat must continue using local schema knowledge.
        return []
    return df["schema_name"].tolist() if not df.empty else []


def list_tables(engine, db: str) -> list[str]:
    try:
        df = run_raw_sql(
            engine,
            f"SELECT table_name FROM information_schema.tables "
            f"WHERE table_schema = {_q(db)} ORDER BY table_name",
        )
    except Exception:
        return []
    return df["table_name"].tolist() if not df.empty else []


def list_columns(engine, db: str, table: str) -> list[dict]:
    try:
        df = run_raw_sql(
            engine,
            f"SELECT column_name, data_type, column_comment FROM information_schema.columns "
            f"WHERE table_schema = {_q(db)} AND table_name = {_q(table)} "
            f"ORDER BY ordinal_position",
        )
    except Exception:
        return []
    if df.empty:
        return []
    return [
        {"name": r["column_name"], "type": r["data_type"], "comment": r["column_comment"] or ""}
        for _, r in df.iterrows()
    ]


def search_columns(engine, db: str, term: str, limit: int = 50) -> list[dict]:
    """按列名模糊搜索库内字段，返回 [{table, column, type, comment}]（供 Agent 定位字段所在表）。

    term 作为 LIKE 子串（转义单引号）；按表名、列名排序取前 limit 条，避免大库返回过多。
    """
    term = (term or "").strip()
    if not term:
        return []
    like = "%" + term.replace("'", "''") + "%"
    df = run_raw_sql(
        engine,
        f"SELECT table_name, column_name, data_type, column_comment FROM information_schema.columns "
        f"WHERE table_schema = {_q(db)} AND column_name LIKE '{like}' "
        f"ORDER BY table_name, ordinal_position LIMIT {int(limit)}",
    )
    if df.empty:
        return []
    return [
        {"table": r["table_name"], "column": r["column_name"],
         "type": r["data_type"], "comment": r["column_comment"] or ""}
        for _, r in df.iterrows()
    ]


def load_core_schema(engine, db: str) -> tuple[dict[str, list[dict]], int]:
    """加载目标库「核心表」结构，返回 (核心表结构, 全库表总数)。带缓存。"""
    with _lock:
        if db in _core_cache:
            return _core_cache[db], _core_total.get(db, 0)

    tables = list_tables(engine, db)
    game_key = db[len("pf_"):] if db.startswith("pf_") else ""
    patterns = config.core_table_patterns(game_key)
    core_tables = [t for t in tables if any(p in t for p in patterns)]
    if not core_tables:  # 兜底：过滤为空时退回全部（仅极端情况，可能很大）
        core_tables = tables

    result = {t: list_columns(engine, db, t) for t in core_tables}
    with _lock:
        _core_cache[db] = result
        _core_total[db] = len(tables)
    return result, len(tables)


def schema_summary(schema: dict[str, list[dict]], db: str, total_tables: int | None = None) -> str:
    """把 {table: [columns]} 拼成紧凑文本，供 SQL 生成 prompt 使用。

    表名写成 `库.表` 全限定名，提示 LLM 引用时也带库名前缀，避免落到错误默认库。
    """
    lines = [f"数据库 `{db}` 的表结构（已按核心业务表过滤；引用时请写全限定名 `{db}.表名`）：", ""]
    for table, cols in schema.items():
        col_str = ", ".join(
            f"{c['name']}:{c['type']}" + (f"({c['comment']})" if c["comment"] else "")
            for c in cols
        )
        lines.append(f"- {db}.{table} ({col_str})")
    if total_tables is not None and total_tables > len(schema):
        lines.append("")
        lines.append(
            f"（另有 {total_tables - len(schema)} 张表未列出；若问题涉及其它表，请基于上述字段风格谨慎推断，"
            f"或在需求中明确指定表名。）"
        )
    return "\n".join(lines)
