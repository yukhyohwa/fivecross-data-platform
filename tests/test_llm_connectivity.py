"""LLM 连通性测试（/api/agent/test-llm）的 SSRF 口径。

- 用户提交的内网/本机地址 → 拒绝（SSRF 防护必须保留）。
- api_base 留空回落服务端默认网关（.env 的 BASE_URL，可信配置）→ 不做内网拦截、可连通。
"""
from backend.routers import agent


def test_validate_api_base_rejects_private_and_local():
    for url in (
        "http://127.0.0.1",
        "http://10.0.0.1",
        "http://192.168.1.1",
        "http://169.254.169.254",
    ):
        assert agent._validate_api_base(url) == "API 地址不允许指向内网或本机地址"


def test_test_llm_falls_back_to_server_gateway_without_ssrf_reject(monkeypatch):
    # 服务端默认网关设成内网地址（.env 可信配置），模拟 litellm-internal 内网网关场景
    monkeypatch.setattr(agent.ai_client, "BASE_URL", "http://10.0.0.1")
    calls = []

    class _Resp:
        status_code = 200
        text = "{}"

    def fake_get(url, **kwargs):
        calls.append(url)
        return _Resp()

    monkeypatch.setattr(agent.requests, "get", fake_get)

    body = agent.TestLLMBody(api_key="sk-test", model="deepseek-chat", api_base="")
    result = agent.test_llm(body, user={"id": "u1"})
    assert result["success"] is True
    assert calls == ["http://10.0.0.1/models"]


def test_test_llm_still_rejects_user_private_base(monkeypatch):
    monkeypatch.setattr(agent.ai_client, "BASE_URL", "http://10.0.0.1")
    body = agent.TestLLMBody(api_key="sk-test", model="deepseek-chat", api_base="http://192.168.1.1")
    result = agent.test_llm(body, user={"id": "u1"})
    assert result["success"] is False
    assert result["message"] == "API 地址不允许指向内网或本机地址"
