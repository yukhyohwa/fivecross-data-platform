"""STE 汇报规则（中文版）—— data_ai 所有「文本解释数据」的统一写作规范。

适用范围（2026-10-23 用户要求）：聊天解读、深度分析结论、SQL 取数说明、
专项/自动生成报告、Joydata 简报等一切面向用户的文本结论。
- 直接注入：各生成入口的 system prompt 追加 ste_rules_block()（analysis/prompts 三模型、
  backend/services/analyze 解读、agent_deep 深度分析、chat Joydata 简报）。
  紧凑通道可豁免互斥条款（如简短解读豁免⑤⑥，见 ste_rules_block(exclude=...)）。

对抗审查 2026-10-23 收口：条款拆成独立片段，允许按通道豁免——
⑤「需要你：」段与⑥「顺带」发现会强制分段落/给建议，与「2~4 句话直说重点」
「简报 ≤200 字」等紧凑约束直接互斥，此前无条件追加导致模型必然违反其中一组指令。
对抗审查 2026-10-23 收口（二轮）：chatbi::report_rules 工具已下线——工具返回的正是
system prompt 已注入的同一段全文，纯冗余往返还挤占深度分析的有限轮次；规则一律
走直接注入（豁免用 exclude=），不再提供按需取用路径。
"""

# 条款片段（key 供 ste_rules_block 按通道豁免；STE_REPORT_RULES 保持原文全量）。
_STE_CLAUSES = (
    ("lead", "① 开头先写结论，不超过两句。"),
    ("sentence", "② 一句只讲一件事。结论句和指令句不超过 60 字。"),
    ("consistency", "③ 同一个概念全程只用一个词。数字旁写明粒度和口径（单日/整周、去重/不去重、订单/张）。"),
    ("names", "④ 不用没解释过的代号（方案 D、C1、M-A、§S2）。写全称，或首次出现时写「全称（代号）」。"),
    ("need_you", "⑤ 需要用户决定的事放在末尾，单独成段，以「需要你：」开头。每项写明推荐选项和一句理由。"
                 "只有用户才知道答案的事实性问题（例如「方案是否已上线」）不用给推荐。"),
    ("bonus", "⑥ 只回答所问。顺带发现最多 3 条，放末尾，标「顺带」。"),
    ("verbatim", "⑦ 库名、表名、字段名、业务术语原样保留，不换成「更简单的词」。"),
)

STE_REPORT_RULES = "\n".join(t for _, t in _STE_CLAUSES)


def ste_rules_block(exclude: tuple[str, ...] = (), intro: str | None = None) -> str:
    """追加到 system prompt 的规则段（带标题与约束声明）。

    exclude：按条款 key 豁免（'lead'|'sentence'|'consistency'|'names'|'need_you'|'bonus'|'verbatim'）。
    intro：替换默认约束声明「所有文本结论/解读/报告必须遵守」（豁免场景用它说明豁免范围）。
    """
    header = intro or "汇报规则（STE，所有文本结论/解读/报告必须遵守）："
    return header + "\n" + "\n".join(t for k, t in _STE_CLAUSES if k not in exclude)
