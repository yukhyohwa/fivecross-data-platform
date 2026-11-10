# -*- coding: utf-8 -*-
"""Joydata 普通聊天管线新能力回归测试：不用点名扫描、分游戏选项目、时间语义改写 SQL。

核心原则：带时间范围的取数必须把时间语义施加到报表 SQL（确定性 apply_date_range
或 LLM 注入），改写失败返回 None → 调用方报错中止，绝不静默回落报表默认范围。
"""
import datetime as dt

import pytest

from backend.routers import chat as chat_mod

# Joydata 项目 code 与 data_ai 游戏 key 同构（分游戏取数的映射基础）
PROJECTS = [
    {"id": "95", "name": "ROOC亚服", "code": "rooc"},
    {"id": "102", "name": "ROOC南北美", "code": "rooc_am"},
    {"id": "93", "name": "拳皇国服", "code": "kof"},
    {"id": "104", "name": "拳皇东南亚", "code": "kof_sea"},
]


# ── 1. _joydata_scan_worthy：不用点名，信号扫描 ────────────────────────────────

def test_scan_worthy_signals():
    # ≥2 拉丁词（英文报表名，如 Sales by Pay_type）
    assert chat_mod._joydata_scan_worthy("取一下 Sales by Pay_type 最近3天的数据") is True
    # 引号/书名号包起的名称
    assert chat_mod._joydata_scan_worthy("把「留存日报」最近一周的数据拉出来") is True
    # 看板/报表类关键词
    assert chat_mod._joydata_scan_worthy("看板里收入统计最近怎么样") is True


def test_scan_worthy_negatives():
    # 纯中文普通取数：不触发扫描（避免已连接用户每问都白加 MCP 往返，未命中也会静默回落）
    assert chat_mod._joydata_scan_worthy("查一下最近7天活跃") is False
    assert chat_mod._joydata_scan_worthy("查一下收入") is False
    # 咨询 Joydata 本身不触发
    assert chat_mod._joydata_scan_worthy("joydata 是什么") is False
    assert chat_mod._joydata_scan_worthy("怎么连接 joydata？") is False
    assert chat_mod._joydata_scan_worthy("") is False


# ── 2. _joydata_pick_project：按 data_ai 当前游戏选 Joydata 项目 ───────────────

def test_pick_project_prefers_current_game_code():
    p, how = chat_mod._joydata_pick_project(
        PROJECTS, {"key": "rooc", "name": "ROOC亚服"},
        "取一下 Sales by Pay_type 最近3天的数据")
    assert p["id"] == "95"
    assert how == "game"


def test_pick_project_question_game_then_word_then_default(monkeypatch):
    # 当前游戏（ro3）无对应项目 → 问题点名其它游戏按 code 匹配
    monkeypatch.setattr(chat_mod.games, "match_game_in_text", lambda q: {"key": "kof_sea"})
    p, how = chat_mod._joydata_pick_project(PROJECTS, {"key": "ro3"}, "拳皇东南亚的活跃怎么样")
    assert p["id"] == "104"
    assert how == "question_game"

    # 问题点名的游戏无对应项目 → 按问题词义匹配项目名（词与词之间需有空格/标点分段）
    monkeypatch.setattr(chat_mod.games, "match_game_in_text", lambda q: None)
    p, how = chat_mod._joydata_pick_project(PROJECTS, {"key": "ro3"}, "查一下 拳皇国服 的收入")
    assert p["id"] == "93"
    assert how == "question"

    # 全不命中 → 回落第一个项目（显式标 default，供调用方知晓）
    p, how = chat_mod._joydata_pick_project(PROJECTS, {"key": "ro3"}, "查一下收入")
    assert p["id"] == "95"
    assert how == "default"


def test_pick_project_no_code_no_game(monkeypatch):
    # 项目列表缺 code 字段时也能按词义/默认走通，不抛错
    monkeypatch.setattr(chat_mod.games, "match_game_in_text", lambda q: None)
    plain = [{"id": "1", "name": "中台通用"}, {"id": "2", "name": "拳皇国服"}]
    p, how = chat_mod._joydata_pick_project(plain, {"key": "kof"}, "看下 拳皇国服 的收入")
    assert p["id"] == "2"
    assert how == "question"


# ── 3. _joydata_time_range：时间语义解析（复用 analysis.time_range 口径）───────

def test_time_range_rolling_window_ends_yesterday():
    today = dt.date(2026, 10, 16)
    s, e, label = chat_mod._joydata_time_range("最近3天的数据", today=today)
    assert (s, e) == ("2026-10-13", "2026-10-15")  # 滚动窗截止昨天
    assert label == "2026-10-13 ~ 2026-10-15"


def test_time_range_none_without_intent():
    assert chat_mod._joydata_time_range("查一下收入", today=dt.date(2026, 10, 16)) == ("", "", "")
    assert chat_mod._joydata_time_range("", today=dt.date(2026, 10, 16)) == ("", "", "")


# ── 4. _joydata_rewrite_sql：确定性替换优先，失败 None（绝不回落默认范围）──────

def test_rewrite_sql_deterministic_path_no_llm(monkeypatch):
    """报表 SQL 含相对日期表达式 → apply_date_range 确定性替换成字面量，不调 LLM。"""

    def boom(*a, **k):
        raise AssertionError("确定性路径不应调 LLM")

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", boom)
    sql = ("select a, count(*) as cnt from t "
           "where dt >= date_sub(current_date(), interval 3 day) group by a")
    out = chat_mod._joydata_rewrite_sql("m", "最近3天", sql, "2026-10-13", "2026-10-15")
    assert out
    assert "2026-10-13" in out
    assert "date_sub" not in out.lower()
    assert "select" in out.lower()


def test_rewrite_sql_llm_injection(monkeypatch):
    """报表 SQL 无相对日期表达式（日期过滤在报表参数里）→ LLM 注入时间条件。"""

    def fake_complete(model, messages, user=None):
        return ("```sql\nselect a, count(*) from t "
                "where dt >= '2026-10-13' and dt < '2026-10-16' group by a\n```", model)

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", fake_complete)
    sql = "select a, count(*) from t group by a"
    out = chat_mod._joydata_rewrite_sql("m", "最近3天", sql, "2026-10-13", "2026-10-15")
    assert out
    assert "2026-10-13" in out


def test_rewrite_sql_fails_loud_instead_of_default_range():
    # 非 SELECT 直接失败
    assert chat_mod._joydata_rewrite_sql("m", "最近3天", "not a sql",
                                         "2026-10-13", "2026-10-15") is None


def test_rewrite_sql_fails_when_llm_returns_unchanged(monkeypatch):
    def fake_complete(model, messages, user=None):
        return ("```sql\nselect a from t group by a\n```", model)

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", fake_complete)
    sql = "select a from t group by a"
    assert chat_mod._joydata_rewrite_sql("m", "最近3天", sql,
                                         "2026-10-13", "2026-10-15") is None


def test_rewrite_sql_fails_when_llm_not_configured(monkeypatch):
    def boom(*a, **k):
        raise chat_mod.LLMNotConfigured("未配置")

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", boom)
    sql = "select a from t group by a"
    assert chat_mod._joydata_rewrite_sql("m", "最近3天", sql,
                                         "2026-10-13", "2026-10-15") is None


def test_rewrite_sql_guard_blocks_hidden_write(monkeypatch):
    """确定性替换结果含写语句 → 只读闸门拦下返回 None。"""

    def boom(*a, **k):
        raise AssertionError("闸门失败时不应调 LLM")

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", boom)
    sql = ("select * from t where dt = date_sub(current_date(), interval 1 day); "
           "drop table x")
    assert chat_mod._joydata_rewrite_sql("m", "最近3天", sql,
                                         "2026-10-13", "2026-10-15") is None


# ── 4b. 窗口钉死：绝不把报表原生滚动窗口宽度当成请求区间 ──────────────────────

def test_unpinned_window_regex_signals():
    # 日期字面量锚点后仍带 interval 运算 → 窗口未钉死（仍是报表默认口径）
    assert chat_mod._UNPINNED_WINDOW_RE.search(
        "date_trunc('day', convert_tz('2026-10-15', @@global.time_zone, '+7')) - interval 6 day")
    assert chat_mod._UNPINNED_WINDOW_RE.search(
        "where dt >= date_sub(current_date(), interval 3 day)")
    # 纯字面量比较 → 已钉死
    assert not chat_mod._UNPINNED_WINDOW_RE.search(
        "where dt >= '2026-10-13' and dt < '2026-10-16'")


def test_rewrite_sql_rolling_window_template_pinned_deterministically(monkeypatch):
    """Joydata 滚动窗口模板（between 锚点±interval）→ 整个 between 换成请求区间字面量，零 LLM。"""

    def boom(*a, **k):
        raise AssertionError("模板 between 应确定性钉死，不调 LLM")

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", boom)
    sql = ("select * from t where date between "
           "date_trunc('day', convert_tz(now(), @@global.time_zone, '+7')) - interval 6 day "
           "and date_trunc('day', convert_tz(now(), @@global.time_zone, '+7')) "
           "- interval 1 second - interval 0 day + interval 1 day and platform = 'ios'")
    out = chat_mod._joydata_rewrite_sql("m", "最近3天", sql, "2026-10-13", "2026-10-15")
    assert out
    assert "date between '2026-10-13' and '2026-10-15'" in out
    assert "interval" not in out.lower()


def test_rewrite_sql_corrective_retry_when_llm_keeps_interval(monkeypatch):
    """LLM 第一次仍保留 interval 窗口 → 追加纠正消息重试一次；第二次钉死 → 采用。"""
    seq = {"n": 0}
    unpinned = ("```sql\nselect * from t where date between "
                "date_trunc('day', convert_tz('2026-10-15', @@global.time_zone, '+7')) - interval 6 day "
                "and date_trunc('day', convert_tz('2026-10-15', @@global.time_zone, '+7')) "
                "- interval 1 second + interval 1 day\n```")

    def fake_complete(model, messages, user=None):
        seq["n"] += 1
        if seq["n"] == 1:
            return (unpinned, model)
        assert len(messages) == 4  # 纠正消息已追加
        return ("```sql\nselect * from t "
                "where date >= '2026-10-13' and date < '2026-10-16'\n```", model)

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", fake_complete)
    out = chat_mod._joydata_rewrite_sql("m", "最近3天", "select * from t",
                                        "2026-10-13", "2026-10-15")
    assert seq["n"] == 2
    assert out and "2026-10-13" in out


def test_rewrite_sql_retry_still_unpinned_fails_loud(monkeypatch):
    """纠正后仍保留 interval 窗口 → None（调用方报错中止，绝不返回默认范围数据）。"""

    def fake_complete(model, messages, user=None):
        return ("```sql\nselect * from t where date between "
                "date_trunc('day', convert_tz('2026-10-15', @@global.time_zone, '+7')) "
                "- interval 6 day and now()\n```", model)

    monkeypatch.setattr("backend.services.llm.complete_with_fallback", fake_complete)
    assert chat_mod._joydata_rewrite_sql("m", "最近3天", "select * from t",
                                         "2026-10-13", "2026-10-15") is None


# ── 5. _joydata_items：容错提取 {id, name, code}（含 camelCase 兼容）──────────

def test_items_code_extraction():
    raw = {"list": [
        {"projectId": 93, "projectName": "拳皇国服", "game_code": "kof"},
        {"id": "104", "name": "拳皇东南亚", "code": "kof_sea"},
        "junk",
        {"id": "95"},  # 无 name → name 回落 id
    ]}
    items = chat_mod._joydata_items(raw)
    assert items == [
        {"id": "93", "name": "拳皇国服", "code": "kof"},
        {"id": "104", "name": "拳皇东南亚", "code": "kof_sea"},
        {"id": "95", "name": "95"},
    ]
