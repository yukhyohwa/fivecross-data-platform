"""报告缺口分析：读一份已生成报告，识别"因数据/口径/方法受限而未做到"的点，
并给出可落地的补救建议（新增/修改 SQL、修改专项、补充知识库、新增算法模型）。

只分析、只建议，不落盘、不执行任何 SQL/代码；下游工具（如订阅报告页）据此提供跳转。
跨工具共用：data_ai 与飞书等可调用同一份 analyze_gaps。
"""
from __future__ import annotations

import json
import re

from .ai_client import chat_completion_with_fallback
from . import sql_store
from .sql_rewriter import detect_hardcoded_dates

_VALID_TYPES = {"sql", "skill", "kb", "model"}
_VALID_SEVERITY = {"high", "medium", "low"}
_VALID_ACTION = {"create", "modify"}

_GAP_SYSTEM = """你是资深的数据分析能力缺口评审专家。你阅读一份已经生成的数据分析报告，找出报告里"因为数据/口径/方法受限而没有做到、没有算清、没有确认"的地方（缺口），并为每个缺口给出可落地的补救建议。

每条缺口只对应一个可执行动作，补救类型固定为以下四选一：
- sql：需要新增或修改取数 SQL（缺某张表/某列/某统计口径）
- skill：需要修改专项（分析结构/步骤/绑定关系不完整）
- kb：需要补充知识库文档（缺口径定义/业务背景/外部日历等说明）
- model：需要新增或修改算法模型（缺预测/归因等算法能力）

严格只输出一个 JSON 数组，不要输出任何 JSON 以外的文字、解释或 markdown 代码围栏。数组每个元素是一个对象，字段固定：
{
  "issue": "缺失/未做到的具体内容（简短）",
  "quote": "报告原文里能佐证的摘录（定位用，尽量原句，可为空字符串）",
  "severity": "high|medium|low",
  "remedy_type": "sql|skill|kb|model",
  "remedy_action": "create|modify",
  "remedy_target": "已有工件名（modify 时给出，create 或不确定时为 null）",
  "remedy_detail": "具体建议（1-2 句，说清补什么、怎么补）"
}
要求：
- 只提取真正"没做到"的点，报告已经完成的分析不要列为缺口；
- 每条建议必须落到上面四类之一，且 remedy_detail 里写清具体动作（如"新增 SQL：xxx，输出 yyy 列"）；
- 若没有缺口，输出空数组 []。"""


def _extract_json_array(raw: str) -> list:
    """从模型输出里稳健地提取首个 JSON 数组（容忍代码围栏/前后缀文字）。"""
    if not raw:
        return []
    text = raw.strip()
    fence = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    if fence:
        text = fence.group(1).strip()
    try:
        data = json.loads(text)
        if isinstance(data, list):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    m = re.search(r"\[[\s\S]*\]", text)
    if m:
        try:
            data = json.loads(m.group(0))
            if isinstance(data, list):
                return data
        except (json.JSONDecodeError, TypeError):
            pass
    return []


def _normalize_gaps(raw_gaps: list) -> list[dict]:
    """归一化并过滤：字段合法化、非法项丢弃。"""
    gaps = []
    for g in raw_gaps:
        if not isinstance(g, dict):
            continue
        issue = str(g.get("issue", "")).strip()
        if not issue:
            continue
        remedy_type = str(g.get("remedy_type", "")).strip().lower()
        if remedy_type not in _VALID_TYPES:
            remedy_type = "kb"
        severity = str(g.get("severity", "")).strip().lower()
        if severity not in _VALID_SEVERITY:
            severity = "medium"
        action = str(g.get("remedy_action", "")).strip().lower()
        if action not in _VALID_ACTION:
            action = "create"
        target = g.get("remedy_target")
        target = str(target).strip() if target not in (None, "") else None
        gaps.append(
            {
                "issue": issue,
                "quote": str(g.get("quote", "")).strip(),
                "severity": severity,
                "remedy_type": remedy_type,
                "remedy_action": action,
                "remedy_target": target,
                "remedy_detail": str(g.get("remedy_detail", "")).strip(),
            }
        )
    return gaps


def _compact_report(md: str, max_chars: int = 60000) -> str:
    """压表 + 截断：报告里的数据表（动辄 200 行）对缺口识别是纯噪声，
    只保留表头与前几行、其余从略，正文 prose（缺口语句所在）完整保留，再按上限截断。"""
    lines = md.split("\n")
    out = []
    in_table = False
    row_count = 0
    keep_rows = 4  # 表头 + 分隔行 + 前 2 行数据
    for line in lines:
        stripped = line.strip()
        is_table_row = stripped.startswith("|") and "|" in stripped[1:]
        if is_table_row:
            if not in_table:
                in_table = True
                row_count = 0
            row_count += 1
            if row_count <= keep_rows:
                out.append(line)
            elif row_count == keep_rows + 1:
                out.append("| …（数据表行从略）… |")
        else:
            in_table = False
            out.append(line)
    text = "\n".join(out)
    if len(text) > max_chars:
        text = text[:max_chars] + "\n\n（报告过长，已截断）"
    return text


def _hardcoded_date_gaps(meta: dict) -> list[dict]:
    """确定性识别（不依赖 LLM）：报告引用的 SQL 若硬编码了日期字面量，产出补救缺口。

    硬编码日期无法随专项/对话动态调整，是能力缺口里最确定的一类，直接按规则识别。
    """
    gaps = []
    names = meta.get("selected_sql") or []
    for name in names:
        if not isinstance(name, str) or not name:
            continue
        sql = sql_store.read_sql(name)
        if not sql and not name.endswith(".sql"):
            sql = sql_store.read_sql(name + ".sql")
        dates = detect_hardcoded_dates(sql)
        if not dates:
            continue
        gap_name = name if name.endswith(".sql") else name + ".sql"
        gaps.append(
            {
                "issue": f"SQL《{gap_name}》硬编码了日期范围（{'、'.join(dates)}），无法随专项/对话动态调整时间",
                "quote": "",
                "severity": "high",
                "remedy_type": "sql",
                "remedy_action": "modify",
                "remedy_target": gap_name,
                "remedy_detail": f"将该 SQL 的硬编码日期（{'、'.join(dates)}）改为 current_date() 相对表达式，使时间范围可被专项/对话动态调整。",
            }
        )
    return gaps


def analyze_gaps(model: str, report_md: str, meta: dict | None = None) -> dict:
    """读一份报告正文，提取缺口 + 补救建议，返回 {"gaps": [...]}。"""
    meta = meta or {}
    parts = []
    meta_lines = []
    if meta.get("skill"):
        meta_lines.append(f"关联专项：{meta['skill']}")
    if meta.get("selected_sql"):
        meta_lines.append("取数 SQL：" + "、".join(meta["selected_sql"]))
    if meta.get("selected_docs"):
        meta_lines.append("知识库文档：" + "、".join(meta["selected_docs"]))
    if meta.get("start_date") or meta.get("end_date"):
        meta_lines.append(f"数据区间：{meta.get('start_date', '')} ~ {meta.get('end_date', '')}")
    if meta_lines:
        parts.append("报告元信息：\n" + "\n".join(meta_lines))
    parts.append("报告正文：\n" + _compact_report(report_md or ""))

    raw, _used = chat_completion_with_fallback(
        model,
        [
            {"role": "system", "content": _GAP_SYSTEM},
            {"role": "user", "content": "\n\n---\n\n".join(parts)},
        ],
        max_tokens=16384,
    )
    llm_gaps = _normalize_gaps(_extract_json_array(raw))
    # 确定性识别的硬编码日期缺口置顶；LLM 未见过 SQL 原文，几乎不会重复报这类缺口
    return {"gaps": _hardcoded_date_gaps(meta) + llm_gaps}
