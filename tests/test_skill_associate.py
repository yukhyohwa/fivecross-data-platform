"""suggest_associations 确定性通道测试（2026-10-26 投放效果分析《买量投放KPI》自动关联不到）。

口径：描述里点名写出的 SQL/文档必须被关联——不依赖 LLM 提名、不受候选 top-N 截断影响；
LLM 提名只增不减过滤；已有绑定只增不减保留。
"""
import pytest

from analysis import kb_gen


class FakeChat:
    """替身 chat_completion_with_fallback：返回固定 JSON，并记录入参。"""

    def __init__(self, raw: str):
        self.raw = raw
        self.calls: list[dict] = []

    def __call__(self, model=None, messages=None, **kw):
        self.calls.append({"model": model, "messages": messages, "kw": kw})
        return self.raw, {}


@pytest.fixture
def env(monkeypatch):
    """隔离环境：LLM 替身、候选截断替身（切成前 3/2 个）、SQL 读取替身（不碰磁盘）。"""
    holder = {}

    def make(llm_raw: str):
        chat = FakeChat(llm_raw)
        monkeypatch.setattr(kb_gen, "chat_completion_with_fallback", chat)
        monkeypatch.setattr(
            kb_gen, "_retrieval_candidates",
            lambda desc, sqls, docs: (list(sqls[:3]), list(docs[:2])),
        )
        monkeypatch.setattr(kb_gen.sql_store, "read_sql", lambda n: "")
        holder["chat"] = chat
        return chat

    holder["make"] = make
    return holder


SQLS = [
    "买量投放KPI.sql",
    "喵果消耗.sql",
    "付费留存.sql",
    "DAU历史(rooc).sql",   # 第 4 名——截断后被切掉，仅点名可救回
    "KPI主表(rooc).sql",   # 第 5 名——截断后被切掉，仅点名可救回
    "短.sql",              # 主干 <4 字符，点名也不匹配
]
DOCS = ["买量数据知识库.md", "指标口径说明.md", "留存口径说明.md"]


def test_literal_mentioned_sql_force_included_when_llm_omits(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "本专项复用《买量投放KPI》资产作为主口径，再补《喵果消耗》看分渠道消耗。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert "买量投放KPI.sql" in r["sqls"]
    assert "喵果消耗.sql" in r["sqls"]


def test_literal_mention_survives_truncation_cut(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "以《KPI主表(rooc)》为底表统计。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    # KPI主表(rooc).sql 排第 5，被截断替身切掉；点名必须救回
    assert "KPI主表(rooc).sql" in r["sqls"]


def test_non_mentioned_names_not_force_added(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "本专项复用《买量投放KPI》资产。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert r["sqls"] == ["买量投放KPI.sql"]


def test_llm_nominated_valid_passes_invalid_filtered(env):
    env["make"]('{"sqls": ["付费留存.sql", "不存在.sql"], "docs": [], "forecast": null}')
    r = kb_gen.suggest_associations("m", "分析拉新情况。", list(SQLS), list(DOCS))
    assert "付费留存.sql" in r["sqls"]
    assert "不存在.sql" not in r["sqls"]


def test_existing_bindings_preserved_merge_only(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    r = kb_gen.suggest_associations(
        "m", "复用《买量投放KPI》。", list(SQLS), list(DOCS),
        existing_sqls=["快照内嵌.sql", "买量投放KPI.sql"],
        existing_docs=["老文档.md"],
    )
    # 只增不减：内嵌快照（不在全局 SQL 库）与点名 SQL 全保留
    assert "快照内嵌.sql" in r["sqls"]
    assert "买量投放KPI.sql" in r["sqls"]
    assert r["docs"] == ["老文档.md"]


def test_docs_literal_mention_force_included(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "口径以《指标口径说明》为准；另见《留存口径说明》（第 3 篇：注意被截断切掉）。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert "指标口径说明.md" in r["docs"]
    assert "留存口径说明.md" in r["docs"]


def test_short_stem_not_force_matched(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "看短、KPI 的变化。"  # 「短.sql」主干 <4 字符，不得点名命中
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert "短.sql" not in r["sqls"]


def test_suffixless_name_mentioned(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    r = kb_gen.suggest_associations(
        "m", "复用《买量投放KPI》，口径见《指标口径说明》。",
        ["买量投放KPI"], ["指标口径说明"])
    assert r["sqls"] == ["买量投放KPI"]
    assert r["docs"] == ["指标口径说明"]


def test_empty_description_no_crash_no_force(env):
    env["make"]('{"sqls": ["付费留存.sql"], "docs": ["买量数据知识库.md"], "forecast": null}')
    r = kb_gen.suggest_associations("m", "", list(SQLS), list(DOCS))
    assert r["sqls"] == ["付费留存.sql"]
    assert r["docs"] == ["买量数据知识库.md"]


def test_forecast_valid_id_passes(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": "fc1"}')
    r = kb_gen.suggest_associations(
        "m", "复用《买量投放KPI》。", list(SQLS), list(DOCS),
        forecast_caps=[{"id": "fc1", "name": "留存预测"}])
    assert r["forecast"] == "fc1"


def test_forecast_invalid_id_coerced_null(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": "ghost"}')
    r = kb_gen.suggest_associations(
        "m", "复用《买量投放KPI》。", list(SQLS), list(DOCS),
        forecast_caps=[{"id": "fc1"}])
    assert r["forecast"] is None


def test_prompt_mentions_existing_bindings(env):
    chat = env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    kb_gen.suggest_associations(
        "m", "复用《买量投放KPI》。", list(SQLS), list(DOCS),
        existing_sqls=["快照内嵌.sql"])
    user = chat.calls[0]["messages"][1]["content"]
    assert "已有选择" in user
    assert "快照内嵌.sql" in user
    # 系统提示含「点名必须列入」的约束
    assert "必须视为直接相关" in chat.calls[0]["messages"][0]["content"]


# ---- 对抗审查修复（2026-10-26）：否定语境 / 前缀族边界 / 坏输出兜底 / 生产形态 ----

def test_negated_mention_not_forced(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "本专项不复用《喵果消耗》，主口径用《买量投放KPI》。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert "喵果消耗.sql" not in r["sqls"]
    assert "买量投放KPI.sql" in r["sqls"]


def test_all_occurrences_negated_skipped(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "本专项不复用《喵果消耗》。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert r["sqls"] == []


def test_negation_not_crossing_sentence(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    desc = "不复用。复用《买量投放KPI》。"
    r = kb_gen.suggest_associations("m", desc, list(SQLS), list(DOCS))
    assert "买量投放KPI.sql" in r["sqls"]


PREFIX_SQLS = ["流水达成.sql", "流水达成_分周.sql"]


def test_prefix_family_only_long_name_bound(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    r = kb_gen.suggest_associations("m", "主口径用《流水达成_分周》。", list(PREFIX_SQLS), [])
    assert r["sqls"] == ["流水达成_分周.sql"]


def test_prefix_family_both_written_both_bound(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    r = kb_gen.suggest_associations("m", "《流水达成》和《流水达成_分周》都要看。", list(PREFIX_SQLS), [])
    assert set(r["sqls"]) == set(PREFIX_SQLS)


def test_non_json_llm_output_rescues_literal(env):
    env["make"]("截断的垃圾文本")  # _extract_json → {}
    r = kb_gen.suggest_associations("m", "复用《买量投放KPI》。", list(SQLS), list(DOCS))
    assert "买量投放KPI.sql" in r["sqls"]


def test_production_shape_long_description(env):
    env["make"]('{"sqls": [], "docs": [], "forecast": null}')
    names = ["流水达成.sql", "流水达成_分周.sql", "买量投放KPI.sql"]
    desc = (
        "# 流水达成分析专项（目标 vs 实际）\n\n"
        "本专项主口径复用《买量投放KPI》资产。\n"
        "第 2 节：按周输出《流水达成_分周》明细。\n"
    )
    r = kb_gen.suggest_associations("m", desc, names, [])
    # 标题里的「流水达成分析」不是点名（流水达成 后跟「分」是词内字符）→ 不绑定
    assert "流水达成.sql" not in r["sqls"]
    assert "买量投放KPI.sql" in r["sqls"]
    assert "流水达成_分周.sql" in r["sqls"]


def test_uppercase_suffix_still_matched():
    assert kb_gen._literal_mentions("复用《买量投放KPI》", ["买量投放KPI.SQL"]) == ["买量投放KPI.SQL"]


def test_summarize_skill_literal_rescue(env):
    chat = env["make"](
        '{"title": "测试专项", "content": "# 测试专项\\n\\n内容", "sqls": [], "docs": [], "forecast": null, "note": ""}'
    )
    desc = "以《KPI主表(rooc)》为底表统计。"
    r = kb_gen.summarize_skill("m", desc, list(SQLS), list(DOCS))
    # KPI主表(rooc).sql 排第 5，被截断替身切掉；生成路径也必须确定性救回
    assert "KPI主表(rooc).sql" in r["sqls"]
    user = chat.calls[0]["messages"][1]["content"]
    # 点名资产插回候选头部，LLM 能在提示词里看到它
    assert "KPI主表(rooc).sql" in user
    # 生成路径系统提示同样含「点名必须列入」约束
    assert "必须视为直接相关" in chat.calls[0]["messages"][0]["content"]
