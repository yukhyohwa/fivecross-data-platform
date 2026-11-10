# -*- coding: utf-8 -*-
"""Joydata 集成对抗审查修复的回归测试（XSS / OAuth 终态 / 刷新单飞 / 条件保存 / 白名单 / 意图 / flexsql / 脱敏）。

覆盖：_result_page XSS 转义、abort_pending 终态、complete_oauth 异常终态、
get_valid_token 刷新单飞（跨线程）、条件保存（断开竞态）、DB 级条件保存、
call_tool 白名单 + 写 SQL 前置拦截、_joydata_intent 咨询/取数区分、
flexsql 括号校验（数组下标/字符串/注释不再误报）、_redact 凭据脱敏。
"""
import asyncio
import threading
import time

import pytest

from backend.ide_app.services import joydata_mcp


def _pend(state: str, user_id: str) -> dict:
    return {
        "user_id": user_id,
        "verifier": "v",
        "client_id": "cid",
        "redirect_uri": "http://localhost:8000/api/joydata/oauth/callback",
        "created_at": time.time(),
    }


@pytest.fixture(autouse=True)
def _clean_joy_state():
    """清空进程级授权会话/结果/锁残留，保证测试互不污染。"""
    joydata_mcp._pending.clear()
    joydata_mcp._results.clear()
    yield
    joydata_mcp._pending.clear()
    joydata_mcp._results.clear()


# ── 1. 回调结果页 XSS 转义 ────────────────────────────────────────────────────

def test_callback_result_page_escapes_error_description(client):
    """未鉴权回调把外部 error_description 原样回显会被 XSS：必须 HTML 转义。"""
    r = client.get("/api/joydata/oauth/callback", params={
        "error": "access_denied",
        "error_description": "<script>alert('xss')</script>",
        "state": "nope",
    })
    assert r.status_code == 200
    assert "<script>" not in r.text
    assert "&lt;script&gt;" in r.text


# ── 2. abort_pending / pending_status 终态 ────────────────────────────────────

def test_abort_pending_records_terminal_error():
    joydata_mcp._pending["s-abort"] = _pend("s-abort", "u1")
    joydata_mcp.abort_pending("s-abort", "授权被拒绝：用户取消")
    st = joydata_mcp.pending_status("s-abort", "u1")
    assert st["status"] == "error"
    assert not st.get("ok")
    assert "授权被拒绝" in st.get("error", "")


def test_pending_status_forbidden_and_expired():
    joydata_mcp._pending["s-fb"] = _pend("s-fb", "u1")
    assert joydata_mcp.pending_status("s-fb", "u2")["status"] == "forbidden"
    assert joydata_mcp.pending_status("s-gone", "u1")["status"] == "expired"


# ── 3. complete_oauth 任何异常都记录终态 ──────────────────────────────────────

def test_complete_oauth_records_terminal_on_unexpected_error(monkeypatch):
    async def boom():
        raise RuntimeError("boom eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
                           "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0."
                           "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")

    joydata_mcp._pending["s-boom"] = _pend("s-boom", "u1")
    monkeypatch.setattr(joydata_mcp, "discover", boom)
    # 非 OAuthError 的意外异常也不上抛：包装成终态结果返回，轮询方一定收敛
    res = asyncio.run(joydata_mcp.complete_oauth("s-boom", "code"))
    assert res.get("ok") is False
    assert "boom" in res.get("error", "")
    assert "eyJ" not in res.get("error", "")  # JWT 已脱敏
    st = joydata_mcp.pending_status("s-boom", "u1")
    assert st["status"] == "error"            # 不再卡 pending 直到 TTL 过期


# ── 4. get_valid_token 刷新单飞（跨线程）─────────────────────────────────────

def test_refresh_single_flight_across_threads(app_env, monkeypatch):
    from backend.ide_app.services import db_service as dbs

    dbs.save_joydata_auth("u-joy-1", "old", "old-rt", expires_at=1, client_id="cid")
    calls = {"n": 0}

    async def fake_discover():
        return {"token_endpoint": "http://fake/token",
                "authorization_endpoint": "http://fake/authz"}

    async def fake_refresh(url, refresh_token, client_id):
        calls["n"] += 1
        await asyncio.sleep(0.3)
        return {"access_token": "fresh-token", "refresh_token": "fresh-rt", "expires_in": 3600}

    monkeypatch.setattr(joydata_mcp, "discover", fake_discover)
    monkeypatch.setattr(joydata_mcp.oauth, "refresh_access_token", fake_refresh)

    results: list = []

    def worker():
        results.append(asyncio.run(joydata_mcp.get_valid_token("u-joy-1")))

    t1, t2 = threading.Thread(target=worker), threading.Thread(target=worker)
    t1.start(); t2.start(); t1.join(); t2.join()

    assert calls["n"] == 1                     # 并发刷新只打一次远端
    assert results == ["fresh-token", "fresh-token"]


# ── 5. 刷新期间被断开：条件保存失败 → 报错且不复活 ─────────────────────────────

def test_refresh_conditional_save_skip_raises_disconnected(monkeypatch):
    row = {"refresh_token": "rt", "access_token": "old", "expires_at": 1,
           "client_id": "cid", "updated_at": "2026-01-01 00:00:00.000"}

    async def fake_discover():
        return {"token_endpoint": "http://fake/token",
                "authorization_endpoint": "http://fake/authz"}

    async def fake_refresh(url, refresh_token, client_id):
        return {"access_token": "fresh-token", "refresh_token": "fresh-rt", "expires_in": 3600}

    monkeypatch.setattr(joydata_mcp, "get_joydata_auth", lambda uid: dict(row))
    monkeypatch.setattr(joydata_mcp, "discover", fake_discover)
    monkeypatch.setattr(joydata_mcp.oauth, "refresh_access_token", fake_refresh)
    monkeypatch.setattr(joydata_mcp, "save_joydata_auth", lambda *a, **k: False)

    with pytest.raises(joydata_mcp.JoydataAuthError, match="断开"):
        asyncio.run(joydata_mcp.get_valid_token("u1"))


# ── 6. DB 级条件保存 ──────────────────────────────────────────────────────────

def test_db_conditional_save(app_env):
    from backend.ide_app.services import db_service as dbs

    assert dbs.save_joydata_auth("u1", "a", "r", 100, client_id="c") is True
    row = dbs.get_joydata_auth("u1")
    assert row and row["updated_at"]

    # 行未变 → 条件保存成功
    assert dbs.save_joydata_auth("u1", "a2", "r2", 200, client_id="c",
                                 expect_updated_at=row["updated_at"]) is True
    # 断开后条件保存 → False，且行保持删除状态（不复活）
    dbs.delete_joydata_auth("u1")
    assert dbs.save_joydata_auth("u1", "a3", "r3", 300, client_id="c",
                                 expect_updated_at=row["updated_at"]) is False
    assert dbs.get_joydata_auth("u1") is None


# ── 7. call_tool 白名单 + 写 SQL 前置拦截 ─────────────────────────────────────

def test_call_tool_blocks_non_whitelisted_tool():
    out = asyncio.run(joydata_mcp.call_tool("u1", "joydata_write_something", {}))
    assert not out.get("ok")
    assert "白名单" in out.get("error", "")


def test_call_tool_guards_write_sql_before_token(monkeypatch):
    called = {"n": 0}

    async def boom_token(uid):  # 若被调用说明闸门没在前面拦住
        called["n"] += 1
        raise AssertionError("不应取 token")

    monkeypatch.setattr(joydata_mcp, "get_valid_token", boom_token)
    out = asyncio.run(joydata_mcp.call_tool("u1", "joydata_query_sql",
                                            {"sql": "DROP TABLE t"}))
    assert not out.get("ok")
    assert "校验" in out.get("error", "")
    assert called["n"] == 0


def test_call_tool_allows_read_sql_past_guard(monkeypatch):
    async def fake_token(uid):
        raise joydata_mcp.JoydataAuthError("尚未连接 Joydata")

    monkeypatch.setattr(joydata_mcp, "get_valid_token", fake_token)
    out = asyncio.run(joydata_mcp.call_tool("u1", "joydata_query_sql", {"sql": "select 1"}))
    assert not out.get("ok")
    assert out.get("needs_auth") is True  # 只读 SQL 过闸门，进入正常鉴权流程


# ── 8. _joydata_intent：咨询类不劫持，取数类才走 Joydata 环节 ──────────────────

def test_joydata_intent_consult_vs_data():
    from backend.routers.chat import _joydata_intent

    assert _joydata_intent("joydata 是什么") is False
    assert _joydata_intent("怎么连接 joydata？") is False
    assert _joydata_intent("帮我查一下 joydata 看板里的收入数据") is True
    assert _joydata_intent("Joydata 的活跃报表有哪些") is True
    assert _joydata_intent("查一下收入") is False


# ── 9. flexsql 括号校验：数组下标/字符串/注释不再误报，真问题仍拦截 ────────────

def _bracket_problems(sql: str) -> list[str]:
    from backend.services.flexsql import _validate_template
    return [p for p in _validate_template(sql)
            if "未配对" in p or "未知占位符" in p]


def test_flexsql_bracket_validation_no_false_positives():
    assert _bracket_problems("select split(x, ',')[1] as a from t") == []
    assert _bracket_problems("select '[ok]' as label from t") == []
    assert _bracket_problems("select 1 from t -- [维度] 注释\n") == []


def test_flexsql_bracket_validation_still_catches_problems():
    from backend.services.flexsql import _validate_template
    probs = _validate_template("select [screen2] from t")
    assert any("未知占位符" in p for p in probs)
    probs = _validate_template("select [screen from t")
    assert any("未配对" in p for p in probs)


# ── 10. _redact 凭据脱敏 ──────────────────────────────────────────────────────

def test_redact_masks_credentials():
    jwt = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
           "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0."
           "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
    text = f"error: Bearer abcDEF123.-_~+/=xx and refresh_token=ABCDEFGHIJKLMNOPQRST and {jwt}"
    out = joydata_mcp._redact(text)
    assert "Bearer [REDACTED]" in out
    assert "abcDEF123" not in out
    assert "refresh_token=[REDACTED]" in out
    assert "ABCDEFGHIJKLMNOPQRST" not in out
    assert "eyJ" not in out
    assert "SflKxw" not in out


# ── 11. 连接完成「黑窗」回归：处理期间轮询仍见 pending，token 落库即终态 ok ────

def test_complete_oauth_state_visible_during_processing(app_env, monkeypatch):
    """回调处理期间（换 token 的网络往返中）state 不得从 _pending 消失：
    否则 pending_status 落入 pending/results 黑窗误报 expired，前端会提前放弃。"""
    entered = threading.Event()
    release = threading.Event()

    async def fake_discover():
        return {"token_endpoint": "http://fake/token",
                "authorization_endpoint": "http://fake/authz"}

    async def slow_exchange(url, **kw):
        entered.set()
        while not release.is_set():
            await asyncio.sleep(0.05)
        return {"access_token": "a", "refresh_token": "r", "expires_in": 3600}

    async def fake_probe(uid):  # 后台探测挂在测试线程的 asyncio.run loop 上，
        return {"ok": True, "tools_count": 6, "tools": []}  # loop 关闭即取消；这里兜底防真连网

    monkeypatch.setattr(joydata_mcp, "discover", fake_discover)
    monkeypatch.setattr(joydata_mcp.oauth, "exchange_code", slow_exchange)
    monkeypatch.setattr(joydata_mcp, "probe_tools", fake_probe)

    joydata_mcp._pending["s-proc"] = _pend("s-proc", "u1")
    result: dict = {}

    def run():
        result["v"] = asyncio.run(joydata_mcp.complete_oauth("s-proc", "code"))

    t = threading.Thread(target=run)
    t.start()
    assert entered.wait(5), "回调未进入换 token 阶段"
    for _ in range(5):  # 处理中轮询：仍是 pending，而不是 expired（黑窗）
        st = joydata_mcp.pending_status("s-proc", "u1")
        assert st["status"] == "pending", st
        time.sleep(0.1)
    release.set()
    t.join(10)

    assert result["v"].get("ok") is True
    assert result["v"].get("verifying") is True
    st = joydata_mcp.pending_status("s-proc", "u1")
    assert st["status"] == "ok"  # 终态立刻收敛，无需等探测往返


def test_complete_oauth_rejects_duplicate_callback():
    pend = _pend("s-dup", "u1")
    pend["processing"] = True
    joydata_mcp._pending["s-dup"] = pend
    with pytest.raises(joydata_mcp.oauth.OAuthError, match="处理中"):
        asyncio.run(joydata_mcp.complete_oauth("s-dup", "code2"))


# ── 12. 后台连通性探测回填轮询结果 ─────────────────────────────────────────────

def test_verify_after_connect_updates_result(monkeypatch):
    joydata_mcp._results["s-v"] = {"user_id": "u1",
                                   "result": {"ok": True, "verifying": True,
                                              "tools_count": 0, "error": ""},
                                   "at": time.time()}

    async def fake_probe(uid):
        return {"ok": False, "tools_count": 0, "error": "initialize 失败"}

    monkeypatch.setattr(joydata_mcp, "probe_tools", fake_probe)
    asyncio.run(joydata_mcp._verify_after_connect("s-v", "u1"))

    st = joydata_mcp.pending_status("s-v", "u1")
    assert st["status"] == "error"
    assert st.get("verifying") is False
    assert "initialize" in st.get("error", "")


def test_verify_after_connect_wrong_user_no_update(monkeypatch):
    joydata_mcp._results["s-v2"] = {"user_id": "u1",
                                    "result": {"ok": True, "verifying": True},
                                    "at": time.time()}

    async def fake_probe(uid):
        return {"ok": False, "error": "x"}

    monkeypatch.setattr(joydata_mcp, "probe_tools", fake_probe)
    asyncio.run(joydata_mcp._verify_after_connect("s-v2", "u-other"))

    st = joydata_mcp.pending_status("s-v2", "u1")
    assert st["status"] == "ok"
    assert st.get("verifying") is True  # 非本用户的验证结果不回填


# ── 13. 回调会话绑定 + Host 推断附加校验（对抗审查 2026-10-23）─────────────────

def _admin_token(client) -> str:
    return client.post("/api/auth/login",
                       json={"username": "admin", "password": "admin123"}).json()["access_token"]


def test_oauth_start_sets_state_cookie(client, monkeypatch):
    """发起授权下发 httponly state cookie（回调会话绑定的一半）。"""
    import backend.routers.joydata as joy_router

    async def fake_start(uid, redirect_uri):
        return {"authorize_url": "https://joy/authz", "state": "st-1"}

    monkeypatch.setattr(joy_router.joydata_mcp, "start_oauth", fake_start)
    r = client.post("/api/joydata/oauth/start",
                    headers={"Authorization": f"Bearer {_admin_token(client)}",
                             "Host": "localhost"})
    assert r.status_code == 200
    assert r.json()["state"] == "st-1"
    assert "joy_oauth_state" in str(r.headers.get("set-cookie", ""))
    assert "httponly" in str(r.headers.get("set-cookie", "")).lower()


def test_callback_without_session_cookie_rejected(client, monkeypatch):
    """无会话 cookie 的回调（跨浏览器回放 state 绑定攻击）→ 校验失败页，不进换 token。"""
    import backend.routers.joydata as joy_router

    async def fake_complete(state, code):
        raise AssertionError("无会话凭据的回调不应进入换 token")

    monkeypatch.setattr(joy_router.joydata_mcp, "complete_oauth", fake_complete)
    r = client.get("/api/joydata/oauth/callback", params={"code": "c", "state": "st-x"})
    assert r.status_code == 200
    assert "校验失败" in r.text


def test_callback_with_session_cookie_proceeds(client, monkeypatch):
    """state 与发起会话的 cookie 一致 → 正常换 token 展示成功页。"""
    import backend.routers.joydata as joy_router
    called = {"n": 0}

    async def fake_complete(state, code):
        called["n"] += 1
        return {"ok": True, "verifying": True}

    monkeypatch.setattr(joy_router.joydata_mcp, "complete_oauth", fake_complete)
    r = client.get("/api/joydata/oauth/callback",
                   params={"code": "c", "state": "st-ok"},
                   cookies={"joy_oauth_state": "st-ok"})
    assert r.status_code == 200
    assert "连接成功" in r.text
    assert called["n"] == 1


def test_oauth_start_rejects_nonstandard_port_host(client, monkeypatch):
    """Host 白名单内但带非标准端口（如 :8000）→ 拒绝（端口变体可刷 DCR 注册）。"""
    import backend.routers.joydata as joy_router

    async def fake_start(uid, redirect_uri):
        raise AssertionError("非法端口应被 Host 校验拦截")

    monkeypatch.setattr(joy_router.joydata_mcp, "start_oauth", fake_start)
    r = client.post("/api/joydata/oauth/start",
                    headers={"Authorization": f"Bearer {_admin_token(client)}",
                             "Host": "joydata_ai.123u.com:8000"})
    assert r.status_code == 400
    assert "端口" in r.json()["detail"]


def test_oauth_start_rejects_unlisted_host(client, monkeypatch):
    """Host 不在白名单（伪造 Host 注册 redirect_uri 到攻击者域名）→ 400。"""
    import backend.routers.joydata as joy_router

    async def fake_start(uid, redirect_uri):
        raise AssertionError("未识别 Host 应被拦截")

    monkeypatch.setattr(joy_router.joydata_mcp, "start_oauth", fake_start)
    r = client.post("/api/joydata/oauth/start",
                    headers={"Authorization": f"Bearer {_admin_token(client)}",
                             "Host": "evil.example.com"})
    assert r.status_code == 400
    assert "JOYDATA_PUBLIC_BASE" in r.json()["detail"]


# ── 14. 畸形端口 / cookie 失败终态（对抗审查 2026-10-23 二轮）───────────────────

def test_oauth_start_rejects_malformed_port(client, monkeypatch):
    """Host 端口畸形（:99999/:abc，urlsplit .port 抛 ValueError）→ 干净 400 而非 500。"""
    import backend.routers.joydata as joy_router

    async def fake_start(uid, redirect_uri):
        raise AssertionError("畸形端口应被 Host 校验拦截")

    monkeypatch.setattr(joy_router.joydata_mcp, "start_oauth", fake_start)
    for host in ("localhost:99999", "localhost:abc"):
        r = client.post("/api/joydata/oauth/start",
                        headers={"Authorization": f"Bearer {_admin_token(client)}",
                                 "Host": host})
        assert r.status_code == 400, host
        assert "主机头" in r.json()["detail"]


def test_callback_cookie_fail_aborts_pending_terminal(client):
    """会话 cookie 校验失败：pending 会话置终态（error），不再卡 pending 等 TTL。"""
    import backend.routers.joydata as joy_router

    joydata_mcp._pending["s-cookie"] = _pend("s-cookie", "u1")
    r = client.get("/api/joydata/oauth/callback", params={"code": "c", "state": "s-cookie"})
    assert r.status_code == 200
    assert "校验失败" in r.text
    st = joydata_mcp.pending_status("s-cookie", "u1")
    assert st["status"] == "error"
