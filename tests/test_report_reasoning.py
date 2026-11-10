"""报告三模型（生成/验证/汇总）LLM 入口 _complete_report 的推理/超时口径。

- deep_thinking=False（默认快速档）：关推理 + 16384 预算 + 放宽读超时到 DEEP_READ_TIMEOUT
  （2026-10-26：实测单轮最长 ~240s 贴边 300s 默认预算，生成/验证轮多次 300s 读超时）。
- deep_thinking=True（深度思考档）：保留推理 + 32768 预算 + 同样放宽读超时。
"""
from analysis.ai_client import CONNECT_TIMEOUT, DEEP_READ_TIMEOUT, INTERACTIVE_MAX_TOKENS
from backend.services import report_analyze


def _capture(monkeypatch):
    captured = {}

    def spy(model, messages, user=None, **kwargs):
        captured["model"] = model
        captured["kwargs"] = kwargs
        return ("ok", model)

    monkeypatch.setattr(report_analyze, "complete_with_fallback", spy)
    return captured


def test_complete_report_disables_deepseek_reasoning(monkeypatch):
    captured = _capture(monkeypatch)
    report_analyze._complete_report("deepseek-v4-pro", [{"role": "user", "content": "x"}], None)
    assert captured["model"] == "deepseek-v4-pro"
    assert captured["kwargs"]["reasoning_effort"] == "none"
    assert captured["kwargs"]["max_tokens"] == 16384
    # 2026-10-26：快速档也放宽读超时（300s 曾多次被生成/验证轮读超时打穿）
    assert captured["kwargs"]["timeout"] == (CONNECT_TIMEOUT, DEEP_READ_TIMEOUT)


def test_complete_report_disables_claude_thinking(monkeypatch):
    captured = _capture(monkeypatch)
    report_analyze._complete_report("claude-opus-4-6", [{"role": "user", "content": "x"}], None)
    assert captured["kwargs"]["thinking"] == {"type": "disabled"}
    assert captured["kwargs"]["timeout"] == (CONNECT_TIMEOUT, DEEP_READ_TIMEOUT)


def test_complete_report_no_reasoning_flag_for_other_models(monkeypatch):
    captured = _capture(monkeypatch)
    report_analyze._complete_report("gpt-5-5", [{"role": "user", "content": "x"}], None)
    assert "reasoning_effort" not in captured["kwargs"]
    assert "thinking" not in captured["kwargs"]
    assert captured["kwargs"]["max_tokens"] == 16384
    assert captured["kwargs"]["timeout"] == (CONNECT_TIMEOUT, DEEP_READ_TIMEOUT)


def test_deep_thinking_keeps_reasoning_and_raises_budget(monkeypatch):
    captured = _capture(monkeypatch)
    report_analyze._complete_report("deepseek-v4-pro", [{"role": "user", "content": "x"}], None, deep_thinking=True)
    # 深度思考：不关推理（不传 reasoning_effort/thinking），放大输出预算，放宽读超时
    assert "reasoning_effort" not in captured["kwargs"]
    assert "thinking" not in captured["kwargs"]
    assert captured["kwargs"]["max_tokens"] == INTERACTIVE_MAX_TOKENS
    timeout = captured["kwargs"]["timeout"]
    assert timeout == (CONNECT_TIMEOUT, DEEP_READ_TIMEOUT)


def test_deep_thinking_keeps_claude_thinking(monkeypatch):
    captured = _capture(monkeypatch)
    report_analyze._complete_report("claude-opus-4-6", [{"role": "user", "content": "x"}], None, deep_thinking=True)
    assert "thinking" not in captured["kwargs"]
    assert "reasoning_effort" not in captured["kwargs"]
    assert captured["kwargs"]["max_tokens"] == INTERACTIVE_MAX_TOKENS
