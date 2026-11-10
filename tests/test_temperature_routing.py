"""P1-4 接线：任务固定 temperature——config 任务→类型映射 + ai_client 上下文注入 + resolve_model_for_task 注入。"""
from backend import config
from backend.services.llm import resolve_model_for_task
from analysis import ai_client


def _fake_post(captured: list):
    """替身 _post_chat：捕获本次请求的 call_kwargs，返回 choices[0]（含正文），不触发任何重试路径。"""
    def _post(api_key, model, messages, call_kwargs, timeout, base_url=None):
        captured.append(dict(call_kwargs))
        return {"message": {"content": "ok"}, "finish_reason": "stop"}
    return _post


def test_task_temperature_mapping():
    # 结构化抽取 0 / 生成类 0.3；未知任务回落 generation（见 config._TASK_TEMP_KIND）
    assert config.task_temperature("sql") == config._TEMPERATURES["structured"]
    assert config.task_temperature("kb") == config._TEMPERATURES["structured"]
    assert config.task_temperature("skill") == config._TEMPERATURES["structured"]
    assert config.task_temperature("model") == config._TEMPERATURES["structured"]
    assert config.task_temperature("report_ver") == config._TEMPERATURES["structured"]
    assert config.task_temperature("gap") == config._TEMPERATURES["structured"]
    assert config.task_temperature("split") == config._TEMPERATURES["structured"]
    assert config.task_temperature("chat") == config._TEMPERATURES["generation"]
    assert config.task_temperature("agent") == config._TEMPERATURES["generation"]
    assert config.task_temperature("report_gen") == config._TEMPERATURES["generation"]
    assert config.task_temperature("report_sum") == config._TEMPERATURES["generation"]
    assert config.task_temperature("unknown-task") == config._TEMPERATURES["generation"]


def test_task_temperature_injected_when_not_explicit(monkeypatch):
    captured = []
    monkeypatch.setattr(ai_client, "_post_chat", _fake_post(captured))
    tok = ai_client.set_task_temperature(0.3)
    try:
        out = ai_client.chat_completion("m", [{"role": "user", "content": "hi"}], api_key="k", base_url="http://b")
    finally:
        ai_client._TASK_TEMPERATURE.reset(tok)
    assert out == "ok"
    assert captured[0]["temperature"] == 0.3


def test_explicit_temperature_wins(monkeypatch):
    captured = []
    monkeypatch.setattr(ai_client, "_post_chat", _fake_post(captured))
    tok = ai_client.set_task_temperature(0.3)
    try:
        ai_client.chat_completion("m", [{"role": "user", "content": "hi"}], api_key="k", base_url="http://b", temperature=0.9)
    finally:
        ai_client._TASK_TEMPERATURE.reset(tok)
    assert captured[0]["temperature"] == 0.9


def test_no_temperature_without_task_context(monkeypatch):
    captured = []
    monkeypatch.setattr(ai_client, "_post_chat", _fake_post(captured))
    tok = ai_client.set_task_temperature(None)  # 显式清空（其它用例可能经 resolve_model_for_task 注入残留）
    try:
        ai_client.chat_completion("m", [{"role": "user", "content": "hi"}], api_key="k", base_url="http://b")
        assert "temperature" not in captured[0]  # 无任务上下文 → 不注入，回落网关默认
    finally:
        ai_client._TASK_TEMPERATURE.reset(tok)


def test_chat_completion_message_also_injects(monkeypatch):
    captured = []
    monkeypatch.setattr(ai_client, "_post_chat", _fake_post(captured))
    tok = ai_client.set_task_temperature(0)
    try:
        ai_client.chat_completion_message("m", [{"role": "user", "content": "hi"}], api_key="k", base_url="http://b")
    finally:
        ai_client._TASK_TEMPERATURE.reset(tok)
    assert captured[0]["temperature"] == 0


def test_resolve_model_for_task_injects_temperature(seeded):
    # 注意：这只验证同线程（非流式端点）注入；SSE 生成器步间上下文被 anyio 重置，
    # 流式路径由 inject_temperature 包装器补（见下方用例）
    from backend.ide_app.services.db_service import _conn
    admin = dict(_conn().execute("SELECT * FROM users WHERE id=?", (seeded["admin"]["id"],)).fetchone())
    tok = ai_client.set_task_temperature(None)  # 清残留，避免其它用例污染
    try:
        resolve_model_for_task("sql", admin)
        assert ai_client._TASK_TEMPERATURE.get() == config._TEMPERATURES["structured"]
        resolve_model_for_task("chat", admin)
        assert ai_client._TASK_TEMPERATURE.get() == config._TEMPERATURES["generation"]
    finally:
        ai_client._TASK_TEMPERATURE.reset(tok)


def test_inject_temperature_reapplies_each_step(monkeypatch):
    """流式补丁（对抗审查 HIGH）：SSE 生成器步间 contextvars 被 anyio 每步复制重置
    （见 chat.py _usage_scope），包装器必须每步推进前重新注入。这里模拟「每步后清空
    ContextVar」验证步内 LLM 调用仍带本任务固定温度。"""
    from backend.services.llm import inject_temperature

    captured = []
    monkeypatch.setattr(ai_client, "_post_chat", _fake_post(captured))

    def gen():
        yield ai_client.chat_completion("m", [{"role": "user", "content": "s1"}], api_key="k", base_url="http://b")
        yield ai_client.chat_completion("m", [{"role": "user", "content": "s2"}], api_key="k", base_url="http://b")

    it = inject_temperature(gen(), "chat")
    # 模拟 anyio 每步 copy_context：每步消费前把上下文重置为「新任务上下文」（token 只 reset 一次）
    for _ in range(2):
        tok = ai_client.set_task_temperature(None)
        try:
            next(it)
        finally:
            ai_client._TASK_TEMPERATURE.reset(tok)
    assert [c.get("temperature") for c in captured] == [config._TEMPERATURES["generation"]] * 2


def test_inject_temperature_explicit_wins_and_task_kind(monkeypatch):
    """包装器注入的是任务固定温度；调用方显式 temperature 仍优先（agent 任务温度同 generation）。"""
    from backend.services.llm import inject_temperature

    captured = []
    monkeypatch.setattr(ai_client, "_post_chat", _fake_post(captured))

    def gen():
        yield ai_client.chat_completion("m", [{"role": "user", "content": "s1"}],
                                        api_key="k", base_url="http://b", temperature=0.9)

    tok = ai_client.set_task_temperature(None)
    try:
        list(inject_temperature(gen(), "agent"))
    finally:
        ai_client._TASK_TEMPERATURE.reset(tok)
    assert captured[0]["temperature"] == 0.9


def test_user_llm_kwargs_routes_per_user(monkeypatch):
    # P1-24：per-user LLM 路由——有用户上下文时经注册的 resolver 取个人 key/base；无上下文回落全局
    monkeypatch.setattr(
        ai_client, "_USER_LLM_RESOLVER",
        lambda u: {"api_key": f"key-{u['id']}", "api_base": f"base-{u['id']}"},
    )
    assert ai_client._user_llm_kwargs() == (None, None)
    tok = ai_client.set_current_user({"id": "u9"})
    try:
        assert ai_client._user_llm_kwargs() == ("key-u9", "base-u9")
    finally:
        ai_client.reset_current_user(tok)
