"""Token 用量 → 费用估算：读 data_ai/pricing.json，按每模型输入/输出单价计算。

单价单位：元 / 百万 token。缺文件/坏档/缺模型时回退到 usage_tracker.DEFAULT_PRICING。
"""
import json

from .. import config
from analysis import usage_tracker


def read_pricing() -> dict:
    """返回 {model: {"input": float, "output": float}}，缺失项回退默认价。"""
    pricing = {k: dict(v) for k, v in usage_tracker.DEFAULT_PRICING.items()}
    path = config.PRICING_PATH
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
        if isinstance(data, dict):
            for model, p in data.items():
                if not isinstance(p, dict):
                    continue
                entry = pricing.setdefault(model, {"input": 0.0, "output": 0.0})
                if isinstance(p.get("input"), (int, float)):
                    entry["input"] = float(p["input"])
                if isinstance(p.get("output"), (int, float)):
                    entry["output"] = float(p["output"])
    return pricing


def cost_of(finish_result: dict) -> float:
    """按 finish_result（usage_tracker.finish() 的返回）估算总费用（元）。"""
    pricing = read_pricing()
    total = 0.0
    for call in finish_result.get("calls", []):
        p = pricing.get(call.get("model")) or {"input": 0.0, "output": 0.0}
        total += call.get("prompt_tokens", 0) / 1e6 * p.get("input", 0.0)
        total += call.get("completion_tokens", 0) / 1e6 * p.get("output", 0.0)
    return total


def build_usage_event(finish_result: dict) -> dict:
    """把 finish_result 拼成 chat SSE 的 usage 事件体。"""
    return {
        "type": "usage",
        "prompt_tokens": finish_result.get("prompt_tokens", 0),
        "completion_tokens": finish_result.get("completion_tokens", 0),
        "total_tokens": finish_result.get("total_tokens", 0),
        "cost": round(cost_of(finish_result), 4),
        "calls": finish_result.get("calls", []),
    }
