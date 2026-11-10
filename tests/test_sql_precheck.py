"""P1-5 SQL 保存预检：只读闸门 + 占位符填充（EXPLAIN 干跑需真实库，单测只覆盖纯逻辑层）。"""
import pytest

from analysis.sql_rewriter import validate_sql
from backend.services.sql_checks import fill_default_placeholders, precheck_sql


@pytest.mark.parametrize("bad", [
    "DELETE FROM t WHERE 1=1",
    "DROP TABLE t",
    "UPDATE t SET a=1",
    "INSERT INTO t VALUES (1)",
    "TRUNCATE TABLE t",
])
def test_validate_sql_rejects_write_statements(bad):
    with pytest.raises(ValueError):
        validate_sql(bad)


def test_validate_sql_accepts_readonly():
    assert validate_sql("SELECT 1")
    assert validate_sql("WITH x AS (SELECT 1) SELECT * FROM x")


def test_fill_default_placeholders():
    sql = "SELECT * FROM t WHERE date >= '{开始日期}' AND date <= '{结束日期}'"
    out = fill_default_placeholders(sql)
    assert "{开始日期}" not in out and "{结束日期}" not in out
    assert "date_sub(current_date(), interval 7 day)" in out
    assert "current_date()" in out


def test_precheck_blocks_write_sql_without_engine():
    problems = precheck_sql("DROP TABLE t", None, "pf_kof")
    assert problems


def test_precheck_surfaces_engine_error():
    class _BoomEngine:
        def connect(self):
            raise RuntimeError("dry-run boom")

    problems = precheck_sql("SELECT 1", _BoomEngine(), "pf_kof")
    assert problems and "预检" in problems[0]
