"""STE 汇报规则（2026-10-23 用户要求）接线回归测试。

规则全文注入所有「文本解释数据」的生成入口（三模型报告/聊天解读/深度分析/简短解读），
并注册为 chatbi::report_rules 工具供深度分析按需取用。
"""
from analysis import prompts as analysis_prompts
from analysis.report_rules import STE_REPORT_RULES, ste_rules_block
from backend.services import analyze, agent_tools


def test_ste_rules_contain_seven_clauses():
    for marker in ("开头先写结论", "一句只讲一件事", "粒度", "全称（代号）",
                   "需要你：", "顺带", "原样保留"):
        assert marker in STE_REPORT_RULES
    assert "汇报规则（STE" in ste_rules_block()


def test_report_prompts_inject_ste():
    """三模型报告产出轮（生成/汇总/定稿）都注入规则。"""
    for block in (analysis_prompts._GENERATE_SYSTEM,
                  analysis_prompts._SUMMARIZE_SYSTEM,
                  analysis_prompts._VERIFY_FINAL_SYSTEM):
        assert "汇报规则（STE" in block and "顺带" in block


def test_analyze_prompts_inject_ste():
    """聊天解读（完整/简短）都注入规则。"""
    assert "汇报规则（STE" in analyze._SYSTEM
    assert "汇报规则（STE" in analyze._BRIEF_SYSTEM


def test_deep_agent_system_prompt_injects_ste(app_env):
    from backend.services import agent_deep
    from backend.services import games as games_svc

    prompt = agent_deep.build_agent_system_prompt(game=games_svc.resolve("kof"))
    assert "汇报规则（STE" in prompt
    assert "顺带" in prompt


def test_report_rules_tool_removed_from_dispatch(app_env):
    """对抗审查 2026-10-23 二轮：report_rules 工具与 system prompt 注入完全重复，
    已从 agent 工具清单下线（规则一律直接注入），dispatch 也不再认识它。"""
    names = [t["function"]["name"] for t in agent_tools.TOOL_SCHEMAS]
    assert "report_rules" not in names
    result = agent_tools.dispatch_tool("report_rules", {}, {"engine": None, "game": None})
    assert result.get("ok") is False


def test_ste_exclude_semantics():
    """exclude 语义：紧凑通道（简短解读/简报）不得出现⑤⑥条款标记，全量块必须齐全。"""
    assert "需要你：" not in analyze._BRIEF_SYSTEM
    assert "顺带" not in analyze._BRIEF_SYSTEM
    full = ste_rules_block()
    assert "需要你：" in full and "顺带" in full
    # Joydata 简报同样豁免⑤⑥（⑥与「不再另起顺带段」互斥）
    from backend.routers import chat as chat_router
    import inspect
    src = inspect.getsource(chat_router._joydata_summary)
    assert "exclude=(\"need_you\", \"bonus\")" in src or "exclude=('need_you', 'bonus')" in src
