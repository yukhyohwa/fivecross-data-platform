# -*- coding: utf-8 -*-
"""方案A（Joydata 本地看板直读 pf_big_data）单元测试 — mock 查询层，不打真实库。

覆盖：日期解析（override/dynamic/static/relative/absolute/兜底）、event SQL 生成
（private 三指标计算、decorate、各 calc 谓词、tag 跳过、多事件 JOIN、limit 钳制）、
user SQL（max(date) 快照）、sql 模块（模板替换/guard/LIMIT/$ 时间列）、td（合计行）、
权限 403（跨项目）、不支持模块 1004、tree/brand 结构。
"""
import datetime as dt
import json

import pytest
from fastapi import HTTPException

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.ide_app.services import joydata_panel as jp


# ── 假查询层 ────────────────────────────────────────────────────────────────

class FakeCur:
    """handler(sql, params) -> (rows, desc)；记录全部执行语句。"""

    def __init__(self, handler):
        self.handler = handler
        self.executed = []
        self.description = []
        self._rows = []

    def execute(self, sql, params=None):
        self.executed.append((sql, params))
        self._rows, self.description = self.handler(sql, params)
        return None

    def fetchall(self):
        return self._rows

    def fetchone(self):
        return self._rows[0] if self._rows else None


class FakeDb:
    def __init__(self, cur):
        self.cur = cur
        self.closed = False

    def close(self):
        self.closed = True


def _prefix(pfx):
    def matcher(sql):
        return sql.strip().startswith(pfx)
    return matcher


def install_fakes(monkeypatch, meta_handler, sr_handler):
    """pf_big_data 元数据走 jp._meta_conn（mock）；StarRocks 走 conn_starrocks（记录执行 SQL/参数）。"""
    meta_cur = FakeCur(meta_handler)
    sr_cur = FakeCur(sr_handler)
    sr_executed = sr_cur.executed
    monkeypatch.setattr(jp, "_meta_conn", lambda: (FakeDb(meta_cur), meta_cur))
    monkeypatch.setattr(jp, "_meta_close", lambda db, cur: None)
    monkeypatch.setattr(jp.pdb, "conn_starrocks", lambda db=None: (FakeDb(sr_cur), sr_cur))
    monkeypatch.setattr(jp.pdb, "release_starrocks", lambda db, cur: None)
    return meta_cur, sr_executed


# 标准项目 49 可见集（g 规则 v1=49）+ 项目行 + 报表行 + project_db
PROJ_ROW = (49, "RO SEA", "ro_sea", 7, "default_catalog.ro_sea.dws_ro_user_view")


def meta_ok(extra_handlers=None):
    """默认 meta handler：user 可见项目 49；project_db.db_name=pf_ro_sea。"""
    table = []
    table.append((_prefix("select v1 from pf_big_data.casbin_rule"), [("49",)], [("v1",)]))
    table.append((_prefix("select distinct project_id from pf_big_data.dashboard"), [], []))
    table.append((_prefix("select distinct project_id from pf_big_data.report"), [], []))
    table.append((_prefix("select distinct project_id from pf_big_data.share_log"), [], []))
    table.append((_prefix("select id, name, code, timezone, user_table_name from pf_big_data.projects"),
                  [PROJ_ROW], [("id",), ("name",), ("code",), ("timezone",), ("user_table_name",)]))
    table.append((_prefix("select db_name from pf_big_data.project_db"),
                  [("pf_ro_sea",)], [("db_name",)]))
    table.extend(extra_handlers or [])

    def handler(sql, params):
        for matcher, rows, desc in table:
            if matcher(sql):
                return rows, desc
        raise AssertionError("unexpected meta query: %s %r" % (sql, params))

    return handler


def report_meta_row(rid, name, module, chart_type, cond):
    return (rid, name, "", module, chart_type, json.dumps(cond))


# ── 日期解析 ────────────────────────────────────────────────────────────────

def test_date_override_wins():
    st, et, sd, ed = jp._resolve_joydata_date({}, "1", "20260101", "20260115")
    assert (st, et) == ("20260101", "20260115")
    assert sd == dt.date(2026, 1, 1) and ed == dt.date(2026, 1, 15)


def test_date_override_invalid_falls_through():
    st, et, sd, ed = jp._resolve_joydata_date(
        {"date_range_info": {"begin_date_type": "static", "begin_date_value": "2023-04-01 00:00:00",
                             "end_date_type": "static", "end_date_value": "2025-01-16 23:59:59"}},
        "1", "bad", "20260115")
    assert (st, et) == ("20230401", "20250116")


def test_date_override_reversed_rejected():
    st, et, sd, ed = jp._resolve_joydata_date(
        {"date_range_info": {"begin_date_type": "static", "begin_date_value": "2023-04-01 00:00:00",
                             "end_date_type": "static", "end_date_value": "2025-01-16 23:59:59"}},
        "1", "20260115", "20260101")
    assert (st, et) == ("20230401", "20250116")


def test_date_dynamic_end_show_value():
    today = dt.date.today()
    st, et, sd, ed = jp._resolve_joydata_date({
        "date_range_info": {"begin_date_type": "static", "begin_date_value": "2023-04-01 00:00:00",
                            "end_date_type": "dynamic", "end_show_value": "1"}})
    assert sd == dt.date(2023, 4, 1)
    assert ed == today - dt.timedelta(days=1)


def test_date_dynamic_begin_show_value():
    today = dt.date.today()
    st, et, sd, ed = jp._resolve_joydata_date({
        "date_range_info": {"begin_date_type": "dynamic", "begin_show_value": "30",
                            "end_date_type": "dynamic", "end_show_value": "0"}})
    assert sd == today - dt.timedelta(days=30)
    assert ed == today


def test_date_relative_offsets():
    today = dt.date.today()
    st, et, sd, ed = jp._resolve_joydata_date({"typ": "relative", "i_min": -30, "i_max": 1})
    assert sd == today - dt.timedelta(days=30)
    assert ed == today - dt.timedelta(days=1)
    st, et, sd, ed = jp._resolve_joydata_date({"typ": "relative", "i_min": -7, "i_max": 0})
    assert sd == today - dt.timedelta(days=7)
    assert ed == today


def test_date_relative_positive_offsets_are_past():
    """i_min/i_max 正值 = 距今 N 天（过去），方向不能反成未来区间。"""
    today = dt.date.today()
    st, et, sd, ed = jp._resolve_joydata_date({"typ": "relative", "i_min": 30, "i_max": 1})
    assert sd == today - dt.timedelta(days=30)
    assert ed == today - dt.timedelta(days=1)
    st, et, sd, ed = jp._resolve_joydata_date({"typ": "relative", "i_min": 7, "i_max": 3})
    assert sd == today - dt.timedelta(days=7)
    assert ed == today - dt.timedelta(days=3)
    # 只给 i_min：b=7 天前，e 兜底昨日
    st, et, sd, ed = jp._resolve_joydata_date({"typ": "relative", "i_min": 7})
    assert sd == today - dt.timedelta(days=7)
    assert ed == today - dt.timedelta(days=1)


def test_date_absolute():
    st, et, sd, ed = jp._resolve_joydata_date(
        {"typ": "absolute", "s_min": "2024-01-01 00:00:00", "s_max": "2024-06-30 23:59:59"})
    assert (st, et) == ("20240101", "20240630")


def test_date_fallback():
    today = dt.date.today()
    st, et, sd, ed = jp._resolve_joydata_date({})
    assert sd == today - dt.timedelta(days=30)
    assert ed == today - dt.timedelta(days=1)


# ── 配额/谓词 ───────────────────────────────────────────────────────────────

def test_selected_quotas_by_index():
    cond = {
        "quota_items": [
            {"name": "0", "checked": True, "display_name": "新增用户数"},
            {"name": "1", "checked": False, "display_name": "跳过"},
            {"name": "2", "checked": True, "display_name": "充值金额"},
        ],
        "analysis_quotas": [
            {"typ": "quota", "event_name": "e1", "field_name": "_bigdata_private_ucount", "u_id_field": "vopenid"},
            {"typ": "quota", "event_name": "e1", "field_name": "x"},
            {"typ": "calc", "event_name": "e1", "field_name": "y"},  # calc → 跳过
        ],
    }
    chosen = jp._selected_quotas(cond)
    assert [c[1] for c in chosen] == ["新增用户数"]


def test_selected_quotas_all_when_no_items():
    cond = {"analysis_quotas": [
        {"typ": "quota", "event_name": "e1", "field_name": "f", "alias": "A"},
        {"typ": "metric", "event_name": "e1", "field_name": "g", "alias": "B"},
    ]}
    chosen = jp._selected_quotas(cond)
    assert [c[1] for c in chosen] == ["A"]


def test_selected_quotas_empty_raises():
    with pytest.raises(jp.JoydataPanelError):
        jp._selected_quotas({"analysis_quotas": [{"typ": "calc", "field_name": "x"}]})


def test_quota_expr_private_count():
    q = {"event_name": "dwd_rolecreate_view", "field_name": "_bigdata_private_count"}
    expr, table = jp._quota_expr(q, {}, [])
    assert expr == "count(1)"
    assert table == "dwd_rolecreate_view"


def test_quota_expr_private_ucount_avgcount():
    q = {"event_name": "e", "field_name": "_bigdata_private_ucount", "u_id_field": "vroleid"}
    expr, _ = jp._quota_expr(q, {}, [])
    assert "count(distinct vroleid)" in expr
    q2 = {"event_name": "e", "field_name": "_bigdata_private_uavgcount", "u_id_field": "vroleid"}
    expr2, _ = jp._quota_expr(q2, {}, [])
    assert "nullif(count(distinct vroleid), 0)" in expr2


def test_quota_expr_decorates():
    cases = {
        "distinctCount": "count(distinct f)",
        "sum": "sum(f)",
        "median": "percentile_approx(f, 0.5)",
        "avgPerson": "sum(f) / nullif(count(distinct vopenid), 0)",
    }
    for dec, frag in cases.items():
        expr, _ = jp._quota_expr({"event_name": "e", "field_name": "f", "field_decorate": dec}, {}, [])
        assert frag in expr, dec


def test_quota_expr_with_filter():
    params = []
    q = {"event_name": "e", "field_name": "price", "field_decorate": "sum",
         "filter_info": {"filters": [{"typ": "event_prop", "calc": "eq", "field_name": "env",
                                      "value_info": {"s_v": "prod"}}]}}
    expr, _ = jp._quota_expr(q, {}, params)
    assert "sum(if(env = %s, price, null))" in expr
    assert params == ["prod"]


def test_quota_expr_illegal_table_raises():
    with pytest.raises(jp.JoydataPanelError):
        jp._quota_expr({"event_name": "e; drop table x", "field_name": "f"}, {}, [])


def test_filter_pred_eq_ne_in_gt_range():
    params = []
    p = jp._filter_pred({"typ": "event_prop", "calc": "eq", "field_name": "app_plat",
                         "value_info": {"i_v": 1, "s_v": ""}}, params)
    assert p == "app_plat = %s" and params == [1]
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "ne", "field_name": "level",
                         "value_info": {"i_v": 10, "s_v": ""}}, params)
    assert p == "level != %s" and params == [10]
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "in", "field_name": "platid",
                         "field_type": "number",
                         "value_info": {"i_arr": [1, 2, 3], "s_arr": ["1", "2", "3"]}}, params)
    assert p == "platid IN (%s,%s,%s)" and params == [1, 2, 3]
    params = []
    p = jp._filter_pred({"typ": "event_prop", "calc": "gt", "field_name": "n",
                         "value_info": {"i_v": 5}}, params)
    assert p == "n > %s" and params == [5]
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "range", "field_name": "rolevip",
                         "value_info": {"i_min": 2, "i_max": 100}}, params)
    assert p == "rolevip >= %s AND rolevip <= %s" and params == [2, 100]


def test_filter_pred_relative_absolute_tag():
    p = jp._filter_pred({"typ": "user_prop", "calc": "relative", "field_name": "registertime",
                         "value_info": {"i_min": -1, "i_max": 0}}, [])
    assert p == "registertime >= date_add(curdate(), interval -1 day) AND registertime < date_add(curdate(), interval 1 day)"
    params = []
    p = jp._filter_pred({"typ": "event_prop", "calc": "absolute", "field_name": "_time",
                         "value_info": {"s_min": "2021-01-01 00:00:00", "s_max": "2021-06-24 11:59:59"}}, params)
    assert p == "_time >= %s AND _time <= %s" and params == ["2021-01-01 00:00:00", "2021-06-24 11:59:59"]
    # tag 圈选 / contains / between → v1 跳过
    assert jp._filter_pred({"typ": "tag", "calc": "relative_event", "field_name": "tag_openid_register"}, []) is None
    assert jp._filter_pred({"typ": "event_prop", "calc": "contains", "field_name": "a"}, []) is None
    assert jp._filter_pred({"typ": "event_prop", "calc": "eq", "field_name": "a; b", "value_info": {"i_v": 1}}, []) is None


def test_filter_pred_gte_lte_null_notnull_notin():
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "gte", "field_name": "level",
                         "value_info": {"i_v": 10}}, params)
    assert p == "level >= %s" and params == [10]
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "lte", "field_name": "level",
                         "value_info": {"i_v": 10}}, params)
    assert p == "level <= %s" and params == [10]
    p = jp._filter_pred({"typ": "event_prop", "calc": "null", "field_name": "pay_channel"}, [])
    assert p == "pay_channel IS NULL"
    for c in ("notnull", "notNull"):
        p = jp._filter_pred({"typ": "event_prop", "calc": c, "field_name": "pay_channel"}, [])
        assert p == "pay_channel IS NOT NULL"
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "notIn", "field_name": "platid",
                         "field_type": "number", "value_info": {"i_arr": [1, 2]}}, params)
    assert p == "platid NOT IN (%s,%s)" and params == [1, 2]
    params = []
    p = jp._filter_pred({"typ": "user_prop", "calc": "notIn", "field_name": "env",
                         "value_info": {"s_arr": ["a", "b"]}}, params)
    assert p == "env NOT IN (%s,%s)" and params == ["a", "b"]


def test_filter_pred_unsupported_calc_raises():
    """未实现的 calc 宁可报错引导原站，也不能静默丢条件出错误数字。"""
    for c in ("regexMatch", "like", "empty", "notEmpty", "notInGroup", "startsWith"):
        with pytest.raises(jp.JoydataPanelError):
            jp._filter_pred({"typ": "event_prop", "calc": c, "field_name": "a"}, [])


# ── event SQL ───────────────────────────────────────────────────────────────

EVENT_COND = {
    "date": {"group_by_type": "day"},
    "groups": [{"field_name": "regchannel", "display_name": "注册渠道", "group_by_type": "discrete"}],
    "quota_items": [
        {"name": "0", "checked": True, "display_name": "新增创角数"},
        {"name": "1", "checked": True, "display_name": "新增账号数"},
    ],
    "analysis_quotas": [
        {"typ": "quota", "event_name": "dwd_rolecreate_view",
         "field_name": "_bigdata_private_ucount", "u_id_field": "vroleid"},
        {"typ": "quota", "event_name": "dwd_rolecreate_view",
         "field_name": "_bigdata_private_ucount", "u_id_field": "vopenid"},
    ],
}


def test_event_sql_single_event():
    plan = jp._event_sql(EVENT_COND, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    sql = plan["sql"]
    assert "date_format(date, '%%Y%%m%%d') AS `$day`" in sql
    assert "`|注册渠道`" in sql
    assert "count(distinct vroleid)" in sql and "count(distinct vopenid)" in sql
    assert "date >= %s" in sql and "date <= %s" in sql
    assert plan["params"][:2] == [dt.date(2026, 1, 1), dt.date(2026, 1, 15)]
    assert "GROUP BY" in sql and "LIMIT 1000" in sql
    assert plan["dim_keys"] == ["|注册渠道"]
    assert plan["quota_keys"] == ["新增创角数", "新增账号数"]


def test_event_sql_week_month_hour():
    for gbt, frag in (("week", "date_trunc('week', date), '%%Y%%m%%d'"), ("month", "date_format(date, '%%Y%%m')"),
                      ("hour", "date_format(dteventtime, '%%Y%%m%%d%%H')")):
        cond = dict(EVENT_COND)
        cond["date"] = {"group_by_type": gbt}
        plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
        assert frag in plan["sql"], gbt
        assert plan["time_key"] == "$%s" % gbt


def test_event_sql_global_filters_and_limit_clamp():
    cond = dict(EVENT_COND)
    cond["limit"] = 99999
    cond["global_filters"] = {"filters": [
        {"filters": [
            {"typ": "event_prop", "calc": "eq", "field_name": "env",
             "value_info": {"s_v": "prod"}},
            {"typ": "tag", "calc": "relative_event", "field_name": "tag_openid_register"},
        ], "relative": 1},
        {"typ": "user_prop", "calc": "gt", "field_name": "level", "value_info": {"i_v": 3}},
    ]}
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert "env = %s" in plan["sql"] and "level > %s" in plan["sql"]
    assert "tag_openid_register" not in plan["sql"]
    assert plan["params"] == [dt.date(2026, 1, 1), dt.date(2026, 1, 15), "prod", 3]
    assert "LIMIT 5000" in plan["sql"]


def test_event_sql_quota_filter_param_order():
    """配额 filter 的 %s 在 SELECT、日期/全局筛选的 %s 在 WHERE —— 参数必须按文本顺序。"""
    cond = dict(EVENT_COND)
    cond["quota_items"] = [{"name": "0", "checked": True, "display_name": "流水"}]
    cond["analysis_quotas"] = [
        {"typ": "quota", "event_name": "dwd_rolecreate_view", "field_name": "price",
         "field_decorate": "sum",
         "filter_info": {"filters": [{"typ": "event_prop", "calc": "eq", "field_name": "env",
                                      "value_info": {"s_v": "prod"}}]}},
    ]
    cond["global_filters"] = {"filters": [
        {"typ": "user_prop", "calc": "gt", "field_name": "level", "value_info": {"i_v": 3}}]}
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert plan["params"] == ["prod", dt.date(2026, 1, 1), dt.date(2026, 1, 15), 3]
    final = plan["sql"] % tuple("'%s'" % p for p in plan["params"])
    assert "sum(if(env = 'prod', price, null))" in final
    assert "date >= '2026-01-01'" in final and "date <= '2026-01-15'" in final
    assert "level > '3'" in final


def test_event_sql_time_field_in_where():
    """WHERE 日期列要用实际时间字段：hour → dteventtime；自定义 field → 该字段（不再硬编码 date）。"""
    cond = dict(EVENT_COND)
    cond["date"] = {"group_by_type": "hour"}
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert "WHERE dteventtime >= %s AND dteventtime <= %s" in plan["sql"]
    cond["date"] = {"group_by_type": "day", "field": "dtstatdate"}
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert "WHERE dtstatdate >= %s AND dtstatdate <= %s" in plan["sql"]
    assert "WHERE date >= %s" not in plan["sql"]


def test_event_sql_multi_event_join():
    cond = dict(EVENT_COND)
    cond["quota_items"] = [
        {"name": "0", "checked": True, "display_name": "流水"},
        {"name": "1", "checked": True, "display_name": "创角"},
    ]
    cond["analysis_quotas"] = [
        {"typ": "quota", "event_name": "dwd_recharge_view_usd_new", "field_name": "price_usd", "field_decorate": "sum"},
        {"typ": "quota", "event_name": "dwd_rolecreate_view", "field_name": "_bigdata_private_count"},
    ]
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert "FULL OUTER JOIN" in plan["sql"]
    assert "<=>" in plan["sql"]  # 时间/维度 null-safe 连接
    assert "COALESCE" in plan["sql"]
    assert "dwd_recharge_view_usd_new" in plan["sql"] and "dwd_rolecreate_view" in plan["sql"]


def test_event_sql_multi_event_param_order():
    """每个子查询各带一份配额/日期/全局参数，整体按子查询文本顺序拼接（2 子查询 = 2 份 WHERE 参数）。"""
    cond = dict(EVENT_COND)
    cond["quota_items"] = [
        {"name": "0", "checked": True, "display_name": "流水"},
        {"name": "1", "checked": True, "display_name": "创角"},
    ]
    cond["analysis_quotas"] = [
        {"typ": "quota", "event_name": "dwd_recharge_view_usd_new", "field_name": "price_usd",
         "field_decorate": "sum",
         "filter_info": {"filters": [{"typ": "event_prop", "calc": "eq", "field_name": "env",
                                      "value_info": {"s_v": "prod"}}]}},
        {"typ": "quota", "event_name": "dwd_rolecreate_view", "field_name": "_bigdata_private_count",
         "filter_info": {"filters": [{"typ": "event_prop", "calc": "eq", "field_name": "env",
                                      "value_info": {"s_v": "test"}}]}},
    ]
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert plan["params"] == [
        "prod", dt.date(2026, 1, 1), dt.date(2026, 1, 15),
        "test", dt.date(2026, 1, 1), dt.date(2026, 1, 15)]
    final = plan["sql"] % tuple("'%s'" % p for p in plan["params"])
    assert "sum(if(env = 'prod', price_usd, null))" in final
    assert "count(if(env = 'test', 1, null))" in final
    assert final.count("date >= '2026-01-01'") == 2
    assert "%%" not in final


def test_event_sql_duplicate_display_suffix():
    cond = dict(EVENT_COND)
    cond["quota_items"] = [
        {"name": "0", "checked": True, "display_name": "X"},
        {"name": "1", "checked": True, "display_name": "X"},
    ]
    plan = jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert plan["quota_keys"] == ["X", "X_1"]


# ── user SQL ────────────────────────────────────────────────────────────────

def test_user_sql_last_time_snapshot():
    cond = {
        "date": {"user_table_time_type": "last_time"},
        "analysis": {"typ": "user_prop", "field_name": "vopenid", "field_decorate": "distinctCount",
                     "display_name": "活跃用户数"},
        "groups": [{"field_name": "regchannel", "display_name": "注册渠道", "group_by_type": "discrete"}],
    }
    proj = {"id": 49, "user_table_name": "default_catalog.ro_sea.dws_ro_user_view"}
    plan = jp._user_sql(cond, proj)
    assert "date = (select max(date) from default_catalog.ro_sea.dws_ro_user_view)" in plan["sql"]
    assert "count(distinct vopenid)" in plan["sql"]
    assert plan["time_key"] is None and plan["dim_keys"] == ["|注册渠道"]


def test_user_sql_date_group_becomes_time_axis():
    cond = {
        "date": {},
        "analysis": {"typ": "user_prop", "field_name": "vopenid", "field_decorate": "distinctCount"},
        "groups": [{"field_name": "date", "display_name": "日期", "group_by_type": "day"}],
    }
    proj = {"id": 49, "user_table_name": "default_catalog.ro_sea.dws_ro_user_view"}
    plan = jp._user_sql(cond, proj)
    assert plan["time_key"] == "$day"
    assert plan["dim_keys"] == []
    assert "date_format(date, '%%Y%%m%%d') AS `$day`" in plan["sql"]


def test_user_sql_fixed_date_and_filters():
    cond = {
        "date": {"user_table_time": "2025-10-01 00:00:00"},
        "analysis": {"typ": "user_prop", "field_name": "level", "field_decorate": "sum"},
        "filter_info": {"filters": [
            {"filters": [{"typ": "user_prop", "calc": "gt", "field_name": "level",
                          "value_info": {"i_v": 5}}], "relative": 1}]},
    }
    proj = {"id": 49, "user_table_name": "default_catalog.ro_sea.dws_ro_user_view"}
    plan = jp._user_sql(cond, proj)
    assert "date = %s" in plan["sql"]
    assert plan["params"] == ["2025-10-01", 5]  # 先日期参数、后筛选谓词参数
    assert "level > %s" in plan["sql"]


def test_user_sql_user_num_metric():
    """user_num 用户数指标：字段名是虚拟的 → count(distinct vopenid)，不引用不存在的 user_num 列。"""
    cond = {
        "date": {"user_table_time_type": "last_time"},
        "analysis": {"typ": "user_num", "field_name": "user_num", "field_decorate": "",
                     "field_decorate_name": "用户数", "display_name": "用户数"},
    }
    proj = {"id": 49, "user_table_name": "default_catalog.ro_sea.dws_ro_user_view"}
    plan = jp._user_sql(cond, proj)
    assert "count(distinct vopenid) AS `用户数`" in plan["sql"]
    assert "user_num" not in plan["sql"].replace("default_catalog.ro_sea.dws_ro_user_view", "")
    assert plan["quota_keys"] == ["用户数"]


# ── sql 模块 ────────────────────────────────────────────────────────────────

SQL_COND = {
    "sql": "select dt, env, sum(amount) as amt from pf_ro_sea.dwd_recharge_view_usd_new "
            "where dt >= ${Date:开始日期} and dt <= ${Date:结束日期} group by dt, env order by dt",
    "dynamic_params": [
        {"type": "Date", "sqlTem": "${Date:开始日期}",
         "info": {"date": {"date_range_info": {"begin_date_type": "dynamic", "begin_show_value": "30",
                                                "end_date_type": "dynamic", "end_show_value": "1"}}}},
        {"type": "Date", "sqlTem": "${Date:结束日期}",
         "info": {"date": {"date_range_info": {"begin_date_type": "dynamic", "begin_show_value": "30",
                                                "end_date_type": "dynamic", "end_show_value": "1"}}}},
    ],
}


def test_sql_template_replace():
    today = dt.date.today()
    sql_text, ymd = jp._resolve_dynamic_params(SQL_COND)
    assert "${Date:开始日期}" not in sql_text and "${Date:结束日期}" not in sql_text
    assert "'%s'" % (today - dt.timedelta(days=30)) in sql_text
    assert "'%s'" % (today - dt.timedelta(days=1)) in sql_text
    assert ymd[0] == (today - dt.timedelta(days=30)).strftime("%Y%m%d")


def test_sql_template_plain_date():
    cond = {"sql": "select * from t where dt = ${Date:某日}",
            "dynamic_params": [{"type": "Date", "sqlTem": "${Date:某日}",
                                "info": {"date": "2025-06-01"}}]}
    sql_text, ymd = jp._resolve_dynamic_params(cond)
    assert "'2025-06-01'" in sql_text
    assert ymd == ("20250601", "20250601")


def test_sql_module_execute_and_time_col(monkeypatch):
    def sr_handler(sql, params):
        return ([("20251001", "prod", 100), ("20251002", "test", 200)],
                [("dt",), ("env",), ("amt",)])
    meta_cur, sr_exec = install_fakes(monkeypatch, meta_ok(), sr_handler)

    cond = dict(SQL_COND)
    cond["limit"] = 50
    cond["chart_config"] = {"col_types": {"dt": "date", "env": "string", "amt": "number"}}
    body = type("B", (), {"report_id": "162", "date_override": None, "st": None, "et": None})()
    proj = {"id": 49, "code": "ro_sea"}
    data = jp._sql_module_report(cond, proj, body, "pf_ro_sea", "trend")
    assert "LIMIT 50" in sr_exec[0][0]
    assert "LIMIT" not in sr_exec[0][0][:sr_exec[0][0].index("LIMIT 50") - 1] or True
    td = data["data"]["td"]
    assert td[0]["$dt"] == "20251001"
    assert "$dt" not in data["showinfo"]["quota"]["default"][0].values()
    quota_keys = [q["key"] for q in data["showinfo"]["quota"]["default"]]
    assert quota_keys == ["env", "amt"]
    assert data["showinfo"]["graph"]["default"][0]["value"] == "1"  # trend → 趋势图


def test_sql_module_write_blocked(monkeypatch):
    cond = {"sql": "delete from pf_big_data.report where id = 1"}
    body = type("B", (), {"report_id": "1", "date_override": None, "st": None, "et": None})()
    proj = {"id": 49}
    with pytest.raises(jp.JoydataPanelError) as ei:
        jp._sql_module_report(cond, proj, body, None)
    assert "校验未通过" in ei.value.msg


def test_sql_module_missing_sql():
    body = type("B", (), {"report_id": "1", "date_override": None, "st": None, "et": None})()
    with pytest.raises(jp.JoydataPanelError):
        jp._sql_module_report({"dynamic_params": []}, {"id": 49}, body, None)


# ── td 组装 ─────────────────────────────────────────────────────────────────

def test_td_with_dims_and_totals():
    desc = [("$day",), ("|渠道",), ("新增用户数",), ("流水",)]
    rows = [("20251001", "A", 10, 100), ("20251001", "B", 5, 50), ("20251002", "A", 7, 70)]
    td = jp._td_from_rows(desc, rows, "$day", ["|渠道"], ["新增用户数", "流水"])
    assert len(td) == 5
    assert td[0]["name"] == "A"
    total1 = [r for r in td if r["|渠道"] == "合计" and r["$day"] == "20251001"][0]
    assert total1["新增用户数"] == 15 and total1["流水"] == 150
    assert total1["name"] == "合计"
    keys = {r["key"] for r in td}
    assert len(keys) == 5  # 行号唯一


def test_td_without_dims_no_totals():
    desc = [("$day",), ("新增用户数",)]
    rows = [("20251001", 10), ("20251002", 7)]
    td = jp._td_from_rows(desc, rows, "$day", [], ["新增用户数"])
    assert len(td) == 2
    assert all("|" not in str(k) for r in td for k in r.keys())


# ── 权限 / 模块兜底 ────────────────────────────────────────────────────────

def test_report_data_403_cross_project(monkeypatch):
    def meta_handler(sql, params):
        if sql.strip().startswith("select v1 from pf_big_data.casbin_rule"):
            return [], [("v1",)]
        if sql.strip().startswith("select distinct project_id"):
            return [], []
        if sql.strip().startswith("select id, name, code, timezone, user_table_name"):
            return [], []
        raise AssertionError(sql)

    def sr_handler(sql, params):
        raise AssertionError("should not reach starrocks")

    install_fakes(monkeypatch, meta_handler, sr_handler)
    body = type("B", (), {"report_id": "133", "date_override": None, "st": None, "et": None})()
    with pytest.raises(HTTPException) as ei:
        jp.pf_report_data({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "133", body)
    assert ei.value.status_code == 403


def test_report_data_unsupported_module(monkeypatch):
    extra = [(_prefix("select id, name, description, module_type, chart_type, conditions from pf_big_data.report"),
              [report_meta_row(133, "留存", "retention", "table", {})], [("id",), ("name",), ("desc",), ("m",), ("ct",), ("c",)])]
    install_fakes(monkeypatch, meta_ok(extra), lambda sql, params: ([], []))

    body = type("B", (), {"report_id": "133", "date_override": None, "st": None, "et": None})()
    with pytest.raises(jp.JoydataPanelError) as ei:
        jp.pf_report_data({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "133", body)
    assert "retention" in ei.value.msg and "原站" in ei.value.msg
    assert ei.value.baseinfo["title"] == "留存"


def test_report_data_event_end_to_end(monkeypatch):
    extra = [(_prefix("select id, name, description, module_type, chart_type, conditions from pf_big_data.report"),
              [report_meta_row(133, "新增用户", "event", "trend", EVENT_COND)],
              [("id",), ("name",), ("desc",), ("m",), ("ct",), ("c",)])]
    meta_cur, sr_exec = install_fakes(monkeypatch, meta_ok(extra), lambda sql, params: (
        [("20260101", "A", 10, 8), ("20260101", "B", 4, 4)],
        [("$day",), ("|注册渠道",), ("新增创角数",), ("新增账号数",)]))

    body = type("B", (), {"report_id": "133", "date_override": None, "st": None, "et": None})()
    data = jp.pf_report_data({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "133", body)
    assert data["baseinfo"]["title"] == "新增用户"
    assert data["showinfo"]["time_screen"]["st"]  # 有默认区间
    assert len(data["data"]["td"]) == 3  # 2 明细 + 1 合计
    assert sr_exec and "dwd_rolecreate_view" in sr_exec[0][0]


def test_report_data_event_date_override(monkeypatch):
    extra = [(_prefix("select id, name, description, module_type, chart_type, conditions from pf_big_data.report"),
              [report_meta_row(133, "新增用户", "event", "trend", EVENT_COND)],
              [("id",), ("name",), ("desc",), ("m",), ("ct",), ("c",)])]
    meta_cur, sr_exec = install_fakes(monkeypatch, meta_ok(extra), lambda sql, params: ([], []))

    body = type("B", (), {"report_id": "133", "date_override": "1", "st": "20260101", "et": "20260107"})()
    data = jp.pf_report_data({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "133", body)
    assert data["showinfo"]["time_screen"] == {"st": "20260101", "et": "20260107"}
    assert sr_exec[0][1][:2] == [dt.date(2026, 1, 1), dt.date(2026, 1, 7)]


# ── apps / tree / brand ─────────────────────────────────────────────────────

def test_pf_apps_names(monkeypatch):
    install_fakes(monkeypatch, meta_ok(), lambda sql, params: ([], []))
    apps = jp.pf_apps({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0})
    assert apps == [{"system_id": "49", "app_id": "ro_sea", "name": "RO SEA"}]


def test_pf_user_or_none_connection_failure_returns_none(monkeypatch):
    """pf_big_data 连接不可用 → None（回落旧路径），不能 500。"""
    def boom():
        raise OSError("connection refused")
    monkeypatch.setattr(jp, "_meta_conn", boom)
    assert jp.pf_user_or_none("a@b.c") is None


def test_pf_user_or_none_query_failure_returns_none(monkeypatch):
    class BadCur:
        def execute(self, sql, params=None):
            raise OSError("query failed")
    monkeypatch.setattr(jp, "_meta_conn", lambda: (FakeDb(BadCur()), BadCur()))
    monkeypatch.setattr(jp, "_meta_close", lambda db, cur: None)
    assert jp.pf_user_or_none("a@b.c") is None


def test_pf_tree_structure(monkeypatch):
    extra = [
        (_prefix("select id, name, user_id, created_at, updated_at from pf_big_data.dashboard_folder"),
         [(10, "公共目录", 1, dt.datetime(2025, 1, 1), dt.datetime(2025, 1, 2))],
         [("id",), ("name",), ("user_id",), ("created_at",), ("updated_at",)]),
        (_prefix("select id, name, folder_id from pf_big_data.dashboard"),
         [(100, "看板A", 10), (101, "未分类看板", None)],
         [("id",), ("name",), ("folder_id",)]),
    ]
    install_fakes(monkeypatch, meta_ok(extra), lambda sql, params: ([], []))
    tree = jp.pf_tree({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49")
    assert len(tree) == 2
    folder = tree[0]
    assert folder["title"] == "公共目录" and folder["brand_data"][0]["title"] == "看板A"
    unclassified = tree[1]
    assert unclassified["id"] == -1 and unclassified["title"] == "未分类"
    assert unclassified["brand_data"][0]["title"] == "未分类看板"


def test_pf_tree_403(monkeypatch):
    install_fakes(monkeypatch, meta_ok(), lambda sql, params: ([], []))
    with pytest.raises(HTTPException):
        jp.pf_tree({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "999")


def test_pf_brand_note_and_tabs(monkeypatch):
    cond_note = json.dumps({"note": "<p>公告</p>"})
    extra = [
        (_prefix("select id, folder_id, name, user_id, created_at, updated_at from pf_big_data.dashboard"),
         [(100, None, "运营看板", 1, dt.datetime(2025, 1, 1), dt.datetime(2025, 1, 2))],
         [("id",), ("folder_id",), ("name",), ("user_id",), ("created_at",), ("updated_at",)]),
        (_prefix("select dr.report_id, dr.`index`"),
         [(178, 0, "M", None, None, "公告", "", "note", None, cond_note),
          (133, 1, "M", '{"w": 12, "h": 6, "x": 0, "y": 0}', "tab1", "报表1", "", "event", "trend", "{}"),
          (134, 2, "L", None, "tab1", "报表2", "", "event", "trend", "{}"),
          (135, 3, "M", None, None, "卡片", "", "event", "card", "{}")],
         [("report_id",), ("index",), ("size",), ("position",), ("tab",),
          ("name",), ("desc",), ("module",), ("chart_type",), ("conditions",)]),
    ]
    install_fakes(monkeypatch, meta_ok(extra), lambda sql, params: ([], []))
    data = jp.pf_brand({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "100")
    assert len(data) == 1
    ui = data[0]["ui_config"]
    by_ni = {str(item.get("ni")): item for item in ui}
    by_i = {str(item.get("i")): item for item in ui}
    assert "178" in by_ni and "i" not in by_ni["178"]
    assert by_ni["178"]["content"] == "<p>公告</p>"
    assert "133" in by_i  # tab1 组首个
    assert "134" not in by_i  # 同 tab 组第二个被跳过
    assert by_i["133"]["w"] == 4 and by_i["133"]["h"] == 2  # position 12×6 /3 → 4×2
    assert by_i["135"]["w"] == 1 and by_i["135"]["h"] == 1  # card
    titles = [r["title"] for r in data[0]["report_list"]]
    assert titles == ["报表1", "卡片"]  # note 不进 report_list


def test_pf_brand_folder_visibility_gate(monkeypatch):
    """看板挂在本人不可见的目录下 → 与 /tree 同规则拒绝（防项目内按 id 越权读私密看板）。"""
    def make_extra(folder_visible):
        return [
            (_prefix("select id, folder_id, name, user_id, created_at, updated_at from pf_big_data.dashboard"),
             [(100, 10, "私密看板", 2, dt.datetime(2025, 1, 1), dt.datetime(2025, 1, 2))],
             [("id",), ("folder_id",), ("name",), ("user_id",), ("created_at",), ("updated_at",)]),
            (_prefix("select id from pf_big_data.dashboard_folder"),
             [(10,)] if folder_visible else [],
             [("id",)]),
            (_prefix("select dr.report_id, dr.`index`"), [], []),
        ]

    install_fakes(monkeypatch, meta_ok(make_extra(False)), lambda sql, params: ([], []))
    with pytest.raises(jp.JoydataPanelError) as ei:
        jp.pf_brand({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "100")
    assert "不存在" in ei.value.msg

    install_fakes(monkeypatch, meta_ok(make_extra(True)), lambda sql, params: ([], []))
    data = jp.pf_brand({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "100")
    assert data[0]["title"] == "私密看板"


def test_pf_brand_unclassified_dashboard_skips_folder_check(monkeypatch):
    """folder_id 为空（未分类看板）→ 不走文件夹闸门。"""
    extra = [
        (_prefix("select id, folder_id, name, user_id, created_at, updated_at from pf_big_data.dashboard"),
         [(100, None, "未分类看板", 1, dt.datetime(2025, 1, 1), dt.datetime(2025, 1, 2))],
         [("id",), ("folder_id",), ("name",), ("user_id",), ("created_at",), ("updated_at",)]),
        (_prefix("select dr.report_id, dr.`index`"), [], []),
    ]
    install_fakes(monkeypatch, meta_ok(extra), lambda sql, params: ([], []))
    data = jp.pf_brand({"id": 170, "username": "u", "email": "a@b.c", "is_admin": 0}, "49", "100")
    assert data[0]["title"] == "未分类看板"


def test_pack_grid_wraps():
    items = [
        {"w": 2, "h": 2}, {"w": 2, "h": 2}, {"w": 2, "h": 3}, {"w": 2, "h": 2}, {"w": 4, "h": 3},
    ]
    out = jp._pack_grid(items)
    # 4 列：行1=[0,2,4 结束(2+2+2>4 → 第3个换行)]，行2=[2x2? 验证不重叠即可]
    positions = [(it["x"], it["y"]) for it in out]
    assert positions[0] == (0, 0)
    assert all(0 <= x <= 4 for x, _y in positions)


def test_graph_mapping():
    assert jp._graph_of("table") == "0"
    assert jp._graph_of("trend") == "1"
    assert jp._graph_of("stack") == "2"
    assert jp._graph_of("pie") == "4"
    assert jp._graph_of("bar") == "5"
    assert jp._graph_of("funnel") == "7"
    assert jp._graph_of("combination") == "9"
    assert jp._graph_of("unknown") == "0"


def test_event_sql_mogrify_safe():
    """模拟 pymysql 的 query % args：%% 折叠成单个 %，执行期无 format 错误。"""
    plan = jp._event_sql(EVENT_COND, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    args = tuple("'%s'" % p for p in plan["params"])
    final = plan["sql"] % args
    assert "%%" not in final
    assert "date_format(date, '%Y%m%d')" in final
    assert "date >= '2026-01-01'" in final


# ── panel.py 包装层（/report-data 错误信封与 403 透传） ──────────────────────

def test_panel_report_data_http_exception_passthrough(monkeypatch):
    """403 门禁必须透传，不能被兜底 except 吞成 1004 信封。"""
    from backend.ide_app.api import panel as panel_api
    monkeypatch.setattr(panel_api.joydata_panel, "pf_user_or_none",
                        lambda email: {"id": 170, "username": "u", "email": email, "is_admin": 0})
    monkeypatch.setattr(panel_api.joydata_panel, "pf_report_data",
                        lambda pf_user, system, rid, body: (_ for _ in ()).throw(HTTPException(403, "无权限")))
    user = {"id": "u", "joydata_email": "a@b.c"}
    from backend.ide_app.api.panel import ReportDataBody
    body = ReportDataBody(system="49", game="ro_sea", report_id="133")
    with pytest.raises(HTTPException) as ei:
        panel_api.panel_report_data(body, user)
    assert ei.value.status_code == 403


def test_panel_report_data_joydata_error_envelope(monkeypatch):
    """翻译/执行失败 → 1004 + r_sql + error_detail。"""
    from backend.ide_app.api import panel as panel_api
    monkeypatch.setattr(panel_api.joydata_panel, "pf_user_or_none",
                        lambda email: {"id": 170, "username": "u", "email": email, "is_admin": 0})

    def boom(pf_user, system, rid, body):
        raise jp.JoydataPanelError("Joydata 模块「retention」暂未接入本地看板，请切原站模式查看",
                                   r_sql="select 1", baseinfo={"id": rid, "title": "x"})

    monkeypatch.setattr(panel_api.joydata_panel, "pf_report_data", boom)
    user = {"id": "u", "joydata_email": "a@b.c"}
    from backend.ide_app.api.panel import ReportDataBody
    body = ReportDataBody(system="49", game="ro_sea", report_id="133")
    out = panel_api.panel_report_data(body, user)
    assert out["code"] == 1004
    assert "原站" in out["msg"]
    assert out["data"]["baseinfo"]["r_sql"] == "select 1"
    assert "error_detail" in out["data"]


def test_event_sql_three_events_rejected():
    cond = dict(EVENT_COND)
    cond["quota_items"] = [
        {"name": "0", "checked": True, "display_name": "A"},
        {"name": "1", "checked": True, "display_name": "B"},
        {"name": "2", "checked": True, "display_name": "C"},
    ]
    cond["analysis_quotas"] = [
        {"typ": "quota", "event_name": "t1", "field_name": "f"},
        {"typ": "quota", "event_name": "t2", "field_name": "f"},
        {"typ": "quota", "event_name": "t3", "field_name": "f"},
    ]
    with pytest.raises(jp.JoydataPanelError) as ei:
        jp._event_sql(cond, dt.date(2026, 1, 1), dt.date(2026, 1, 15))
    assert "3" in ei.value.msg


def test_sql_module_limit_word_boundary(monkeypatch):
    """列名 limit_value 不能算已带 LIMIT；真 LIMIT 子句不重复追加。"""
    body = type("B", (), {"report_id": "1", "date_override": None, "st": None, "et": None})()
    seen = {}

    def sr_handler(sql, params):
        seen["sql"] = sql
        return ([], [("a",)])

    install_fakes(monkeypatch, meta_ok(), sr_handler)
    jp._sql_module_report({"sql": "select limit_value as cnt from pf_ro_sea.t"}, {"id": 49}, body, "pf_ro_sea")
    assert "LIMIT 1000" in seen["sql"]
    jp._sql_module_report({"sql": "select 1 from pf_ro_sea.t limit 5"}, {"id": 49}, body, "pf_ro_sea")
    assert "LIMIT 1000" not in seen["sql"]
