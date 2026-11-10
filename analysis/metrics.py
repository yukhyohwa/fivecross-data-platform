"""业务指标层（指标语义层）：机器可读的指标定义，作为 SQL 生成的「指标口径」单一事实来源。

对标业界（Wren AI 的 MDL / dbt MetricFlow / Cube）：把「充值金额」「ARPU」等命名指标的
公式、维度、粒度结构化沉淀，而非散落在 markdown 文档里，让 LLM 优先复用公式、避免口径漂移。

指标定义维护在 knowledge/metrics.json（JSON 数组，或 {"metrics": [...]}）。每个指标：
    key            内部键（唯一，可选）
    name           指标名（给 LLM 与用户看）
    aliases[]      口语同义词（用于按问题命中指标）
    description    说明
    formula        计算公式（引用真实列名，如 SUM(price_cny_from_api)）
    grain          时间粒度（day/week/month）
    dimensions[]   可下钻维度
    output_label   输出列标签

文件缺失/为空/解析失败时返回空串，完全不影响现有行为（零配置即用）。
"""
from __future__ import annotations

import json
from pathlib import Path

METRICS_PATH = Path(__file__).resolve().parent.parent / "knowledge" / "metrics.json"


def load_metrics() -> list[dict]:
    """读取指标定义；缺失/非法返回空列表。"""
    try:
        data = json.loads(METRICS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if isinstance(data, dict):
        data = data.get("metrics", [])
    if not isinstance(data, list):
        return []
    return [m for m in data if isinstance(m, dict)]


def _norm(s) -> str:
    return (s or "").strip().lower()


def _aliases(m: dict) -> list[str]:
    # name 可能缺失/为空：空别名会让 `_norm(a) in q` 恒真，导致无名指标匹配所有问题并挤掉真正命中的指标，故过滤掉。
    name = m.get("name")
    return ([name] if name else []) + [a for a in (m.get("aliases") or []) if a]


def metrics_hint(question: str | None = None) -> str:
    """渲染指标定义注入提示。

    question 非空时只注入问题命中的指标（按 name/aliases 子串命中），无命中则注入全部；
    question 为空时注入全部。空指标集返回空串。
    """
    metrics = load_metrics()
    if not metrics:
        return ""
    if question:
        q = _norm(question)
        hit = [m for m in metrics if any(_norm(a) in q for a in _aliases(m))]
        if hit:
            metrics = hit

    lines = ["# 业务指标定义（优先按此公式与口径计算，避免口径漂移）", ""]
    for m in metrics:
        name = m.get("name") or m.get("key") or ""
        aliases = " / ".join(a for a in (m.get("aliases") or []) if a)
        lines.append(f"- {name}" + (f"（别名：{aliases}）" if aliases else ""))
        if m.get("formula"):
            lines.append(f"    公式：{m['formula']}")
        dims = "、".join(m.get("dimensions") or [])
        if dims:
            grain = f"；粒度：{m['grain']}" if m.get("grain") else ""
            lines.append(f"    维度：{dims}{grain}")
        if m.get("description"):
            lines.append(f"    说明：{m['description']}")
    return "\n\n" + "\n".join(lines) + "\n"
