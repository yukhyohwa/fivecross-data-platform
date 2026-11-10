"""算法能力通道：按能力名独立选择（不依赖专项绑定）。

对应对话四通道路由的「算法/预测」通道：用户明确要预测/建模时，从注册表挑最匹配的
预测能力，交给 chat.py 的 _run_forecast 取数并执行。本模块只负责「选能力」（单次 LLM 判定）。
"""
import json
import re

from .llm import complete_with_fallback

from . import forecast

_SYSTEM = (
    "你是一名数据分析助手。给定用户问题与一份「预测/算法能力」清单，"
    "判断用户问题命中哪个能力、或与哪个能力最相关。"
    "只输出一个 JSON 对象：{\"method\": \"能力id\"} 或 {\"method\": null}。"
    "只有确实相关时才返回能力 id（须与清单里的 id 完全一致），否则返回 null。"
    "不要输出 JSON 以外的任何内容。"
)


def _parse(raw: str) -> dict:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    m = re.search(r'"method"\s*:\s*"([^"]*)"', raw)
    if m:
        return {"method": m.group(1)}
    if re.search(r'"method"\s*:\s*null', raw):
        return {"method": None}
    return {}


def match_model(model: str, question: str, game: str | None = None, user: dict | None = None) -> str | None:
    """返回最匹配的预测能力 id；无匹配或 AI 判定 null 时返回 None。"""
    caps = [c for c in forecast.visible_capabilities(game) if c.get("input") == "sql"]
    if not caps:
        return None
    listing = "\n".join(
        f"- {c.get('id')}（{c.get('name', '')}）：{c.get('desc', '')}" for c in caps
    )
    user_prompt = (
        "# 预测/算法能力清单\n\n"
        f"{listing}\n\n"
        "# 用户问题\n\n"
        f"{(question or '').strip()}\n\n"
        "请判断命中哪个能力。"
    )
    try:
        raw = complete_with_fallback(
            model=model,
            messages=[{"role": "system", "content": _SYSTEM},
                      {"role": "user", "content": user_prompt}],
            user=user,
        )[0]
    except Exception:
        return None
    method = (_parse(raw).get("method") or "").strip()
    return method if method in {c.get("id") for c in caps} else None
