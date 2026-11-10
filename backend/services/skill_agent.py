"""专项 agent 编排：把「专项 → 分步取数 → 下钻」的编排逻辑从路由层抽出。

一个专项（skill）由「分析方法 .md + 步骤配置 steps + 若干 SQL」构成，整体作为一个
可执行 agent：先跑固定步骤（required=true），再依据中间结果由模型决定触发哪些可选
下钻（required=false），最后把全部结果交给三模型交叉验证产出报告。

这里只放纯编排辅助（不碰路由/SSE）：
- normalize_steps：把 read_skill_meta 结果规范化为 [{name, sql, required}]
- summarize_results：把已执行步骤的结果压成简短摘要（供下钻规划判断）
- plan_drilldowns：一次 LLM 调用，决定触发哪些可选下钻
"""
import json
import re

import pandas as pd

from .llm import complete_with_fallback


def normalize_steps(meta: dict) -> list[dict]:
    """返回 [{name, sql, required}]，去掉缺 sql 的条目；无 steps 时由 sqls 兜底合成。"""
    steps = meta.get("steps") or []
    out = []
    for st in steps:
        sql = (st.get("sql") or "").strip()
        if not sql:
            continue
        out.append({
            "name": (st.get("name") or sql).strip(),
            "sql": sql,
            "required": bool(st.get("required", True)),
        })
    if out:
        return out
    return [{"name": s, "sql": s, "required": True} for s in (meta.get("sqls") or [])]


def summarize_results(query_results: dict) -> str:
    """把已执行步骤的结果压成简短摘要，供下钻规划判断哪些维度值得再钻。"""
    parts = []
    for name, df in query_results.items():
        if df is None or not isinstance(df, pd.DataFrame) or df.empty:
            parts.append(f"- {name}: 无数据")
            continue
        cols = ", ".join(str(c) for c in list(df.columns)[:8])
        parts.append(f"- {name}: {len(df)} 行，字段 [{cols}]")
        sample = df.head(3).to_markdown(index=False)
        parts.append("  " + sample.replace("\n", "\n  "))
    return "\n".join(parts) if parts else "（无已执行结果）"


_PLAN_SYSTEM = (
    "你是数据分析编排器。给定一份专项的分析方法、若干已完成的固定步骤结果摘要，"
    "以及一组可选下钻步骤，判断哪些下钻步骤值得执行（能帮助定位流水波动来源、量化用户/商品/国家贡献）。"
    "只输出一个 JSON 对象：{\"steps\": [\"步骤名\", ...]}，都不需要则 {\"steps\": []}。"
    "不要输出 JSON 以外的任何内容。"
)


def plan_drilldowns(model: str, skill_text: str, optional_steps: list[dict], summary: str, user: dict | None = None) -> list[str]:
    """依据中间结果 + 专项下钻方法，返回要触发的可选下钻步骤名列表。

    解析失败/模型不可用时保守返回空列表（不触发下钻，保证流程不崩）。
    """
    if not optional_steps:
        return []
    listing = "\n".join(f"- {s['name']}（SQL: {s['sql']}）" for s in optional_steps)
    user_prompt = (
        "# 专项分析方法\n\n" + (skill_text or "") + "\n\n"
        "# 已完成的固定步骤结果摘要\n\n" + summary + "\n\n"
        "# 可选下钻步骤\n\n" + listing + "\n\n"
        "请判断哪些可选下钻步骤值得执行，只输出 JSON。"
    )
    try:
        raw, _ = complete_with_fallback(model=model, messages=[
            {"role": "system", "content": _PLAN_SYSTEM},
            {"role": "user", "content": user_prompt},
        ], user=user)
    except Exception:
        return []
    names = _parse_step_names(raw)
    valid = {s["name"] for s in optional_steps}
    return [n for n in names if n in valid]


def _parse_step_names(raw: str) -> list[str]:
    """从模型输出解析步骤名列表，先按 JSON 解析，失败再从引号里抓。"""
    raw = (raw or "").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and isinstance(data.get("steps"), list):
            return [str(x) for x in data["steps"]]
    except (json.JSONDecodeError, TypeError):
        pass
    return re.findall(r'"([^"]+)"', raw)
