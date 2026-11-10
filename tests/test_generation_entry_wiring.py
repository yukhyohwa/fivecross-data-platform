"""P1-4 生成入口落点（对抗审查 LOW 补测）：chat/suggest 与 chat_history/to-kb 必须经
resolve_model_for_task 单出口取模型 + 温度，不能绕过。用 spy + 下游 stub 验证任务键与模型透传。"""
import pytest

from backend.routers.chat import SuggestReq, chat_suggest
from backend.routers.chat_history import ToKbReq, to_kb


@pytest.fixture()
def alice_dict(seeded):
    from backend.ide_app.services.db_service import _conn
    row = _conn().execute("SELECT * FROM users WHERE id=?", (seeded["alice"]["id"],)).fetchone()
    return dict(row)


def test_chat_suggest_routes_via_resolve_model_for_task(monkeypatch, alice_dict):
    import backend.routers.chat as chat_router

    seen = {}

    def spy(task, user, explicit):
        seen["task"], seen["user"], seen["explicit"] = task, user, explicit
        return "spy-model"

    monkeypatch.setattr(chat_router, "resolve_model_for_task", spy)

    got = {}

    def fake_build(model, **kw):
        got["model"] = model
        got["kw"] = kw
        return {"ok": True, "draft": "SELECT 1;"}

    monkeypatch.setattr(chat_router.refine, "build_suggestion", fake_build)

    out = chat_suggest(SuggestReq(model="", skill=None, question="q"), user=alice_dict, game={"key": "kof"})
    assert out["ok"] is True
    assert seen == {"task": "chat", "user": alice_dict, "explicit": ""}
    assert got["model"] == "spy-model"
    assert got["kw"]["game_key"] == "kof"


def test_to_kb_routes_via_resolve_model_for_task(monkeypatch, alice_dict):
    import backend.routers.chat_history as ch

    seen = {}

    def spy(task, user, explicit):
        seen["task"], seen["user"], seen["explicit"] = task, user, explicit
        return "spy-model"

    monkeypatch.setattr(ch, "resolve_model_for_task", spy)
    monkeypatch.setattr(ch.chat_history, "get_session",
                        lambda sid, owner: {"messages": [{"role": "user", "content": "hi"}], "title": "测试会话"})
    monkeypatch.setattr(ch.sql_store, "list_sql_files", lambda game_key: ["other.sql"])
    monkeypatch.setattr(ch.kb_summarize, "summarize_to_sql",
                        lambda model, messages, extra: "SELECT 1;")
    monkeypatch.setattr(ch.kb_gen, "annotate_fields", lambda model, sql_text, fields: fields)

    out = to_kb("s1", ToKbReq(model="", kind="sql"), user=alice_dict, game={"key": "kof"})
    assert out["kind"] == "sql"
    assert out["draft"] == "SELECT 1;"
    assert seen["task"] == "kb"
    assert seen["explicit"] == ""
    assert seen["user"] == alice_dict
