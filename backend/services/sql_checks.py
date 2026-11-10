"""SQL 保存质量预检（审计 P1-5）：只读闸门 + 占位符填充 + EXPLAIN 干跑。

chat.py 有同款 _fill_default_placeholders / _dry_run_sql（对话执行路径）；这里收敛一份
供「保存/编辑 SQL 文件」落盘前预检共用，口径与执行路径保持一致。
"""
from . import games  # backend/services/games.py（apply_sql=apply_db+fill_active_tz），非 analysis.games（家族/隔离）
from analysis.db import run_raw_sql
from analysis.sql_rewriter import validate_sql


def fill_default_placeholders(sql: str) -> str:
    """与 chat.py:_fill_default_placeholders 同口径：{开始日期}/{结束日期} → 相对表达式。"""
    if not sql:
        return sql
    try:
        sql = sql.replace("{开始日期}", "date_sub(current_date(), interval 7 day)")
        sql = sql.replace("{结束日期}", "current_date()")
        return sql
    except Exception:
        return sql


def precheck_sql(sql: str, engine, db: str) -> list[str]:
    """保存前质量预检，返回问题列表（空列表 = 通过）；任一问题即应阻止落盘。

    1. validate_sql 只读闸门：写语句 / 多语句 / 文件写出 → 拒绝；
    2. 占位符填充 + 库名替换后 EXPLAIN 干跑：语法 / 表名 / 列名错误 → 报错文本。
    {时区条件} 由 games.apply_sql → fill_active_tz 一并替换，无需单独处理。
    """
    try:
        validated = validate_sql(sql)
    except ValueError as exc:
        return [str(exc)]
    try:
        probe = games.apply_sql(fill_default_placeholders(validated), db)
        run_raw_sql(engine, f"EXPLAIN {probe}")
    except Exception as exc:
        return [f"SQL 预检未通过：{exc}"]
    return []
