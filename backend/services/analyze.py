"""查询结果 → 自然语言解读。复用 analysis/prompts 的 build_data_block 拼数据块。"""
import pandas as pd

from .llm import complete_with_fallback
from analysis.prompts import _FORMAL_STE_BLOCK, build_data_block, build_ref_section
from analysis.report_rules import ste_rules_block

_SYSTEM = """你是资深游戏数据分析师。基于用户提供的真实查询结果，给出简洁、可执行的解读。
要求：
- 严格依据传入数据下结论，不得臆测；某方面数据不足时直接说明；
- 数值结论保留合理精度（金额两位小数，比例一位小数）；
- 金额类结论必须标注币种（人民币/CNY 或 美金/USD），不要只写裸数字；
- 固定按以下小节结构输出（用 Markdown 二级标题 `## `，标题文字照抄，不要输出顶层 `# 标题`）：
  ## 📌 核心结论 —— 2~4 条最关键发现，关键数字用 **加粗**；
  ## 📈 数据解读 —— 趋势 / 差异 / 成因；
  ## 🎯 建议 —— 可执行的下一步；
- 不要逐行复述整张表，挑关键结论讲。"""

# STE 汇报规则（2026-10-23）：所有数据解读统一遵守。
# 本通道有固定小节结构（## 📌/## 📈/## 🎯），与⑤⑥「放末尾」条款的衔接用正式报告说明
# （对抗审查 2026-10-23：无说明时模型易自创「## 需要你」小节破坏固定结构）。
_SYSTEM += "\n\n" + _FORMAL_STE_BLOCK


def build_messages(data_block: str) -> list[dict]:
    return [
        {"role": "system", "content": _SYSTEM},
        {"role": "user", "content": data_block + "\n\n请基于以上数据给出解读。"},
    ]


def analyze(model: str, df: pd.DataFrame, title: str = "查询结果", user: dict | None = None) -> str:
    """用模型解读查询结果，返回 Markdown 文本。"""
    block = build_data_block({title: df})
    text, _ = complete_with_fallback(model=model, messages=build_messages(block), max_tokens=8192, user=user)
    return text


def analyze_combined(
    model: str,
    query_results: dict[str, pd.DataFrame],
    skill_texts: list[str] | None = None,
    doc_texts: list[tuple[str, str]] | None = None,
    history: str | None = None,
    user: dict | None = None,
) -> str:
    """解读多张查询结果，可附加专项说明与知识库文档作参考，及多轮对话历史。"""
    block = build_data_block(query_results)
    parts = [block]
    if history and history.strip():
        parts.append(history.strip())
    ref = build_ref_section(skill_texts or [], doc_texts or [])
    if ref:
        parts.append(ref)
    parts.append("请基于以上数据给出解读。")
    text, _ = complete_with_fallback(
        model=model,
        messages=[{"role": "system", "content": _SYSTEM},
                  {"role": "user", "content": "\n\n".join(parts)}],
        max_tokens=8192,
        user=user,
    )
    return text


_BRIEF_SYSTEM = (
    "你是数据分析助手。基于用户提供的真实查询结果，用 2~4 句话给出最关键的结论，"
    "关键数字用 **加粗**；不要分小节、不要给建议，直接说重点，不要逐行复述整张表。"
)

# STE 汇报规则（2026-10-23）：简短解读只追加不冲突条款——⑤「需要你：」段与⑥「顺带」发现
# 强制分段落/给建议，与上面「2~4 句话、不要分小节、不要给建议」直接互斥（对抗审查 2026-10-23）。
_BRIEF_SYSTEM += "\n\n" + ste_rules_block(
    exclude=("need_you", "bonus"),
    intro="汇报规则（STE，与本通道「2~4 句话直说重点、不要给建议」不冲突的条款，务必遵守）：",
)


def analyze_brief(
    model: str,
    query_results: dict[str, pd.DataFrame],
    source_line: str | None = None,
    skill_texts: list[str] | None = None,
    doc_texts: list[tuple[str, str]] | None = None,
    history: str | None = None,
    user: dict | None = None,
) -> str:
    """只查SQL 通道的简短解读：几句话说清关键结论（不套完整报告框架）。

    source_line 为数据来源说明（如「来自既有SQL《x》」或「AI生成·准确率无法保证」），
    会作为一段引用块置于解读前，帮助用户判断结果可信度。
    可选传入专项说明 / 知识库文档 / 多轮对话历史，让 AI 结合 SQL 结果与既有业务口径、
    历史上下文进行判断（对应「命中后把聊天内容带进去、结合知识库与专项一起处理」）。
    """
    block = build_data_block(query_results)
    parts = []
    if source_line and source_line.strip():
        parts.append(source_line.strip())
    if history and history.strip():
        parts.append(history.strip())
    ref = build_ref_section(skill_texts or [], doc_texts or [])
    if ref:
        parts.append(ref)
    parts.append(block)
    parts.append("请结合以上参考口径与历史对话，用几句话给出最关键结论。")
    text, _ = complete_with_fallback(
        model=model,
        messages=[{"role": "system", "content": _BRIEF_SYSTEM},
                  {"role": "user", "content": "\n\n".join(parts)}],
        max_tokens=2048,
        user=user,
    )
    return text

