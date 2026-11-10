"""LLM 前置闸门 ensure_llm_ready（2026-10-23 用户反馈：先检 LLM 再弹确认卡）回归测试。

背景：聊天窗口在 LLM 未配置/不可用时，此前会先弹「自由生成SQL」确认卡、点确认后才报错。
修复：ensure_llm_ready 在确认卡之前做「配了 Key 且服务可连通」检查（带 TTL 缓存），
失败抛 LLMNotConfigured，由聊天/深度分析入口直接呈现错误。

覆盖：
1. 非管理员未配个人 Key → resolve_llm 直接抛（既有权限规则不变）。
2. admin 回落全局 .env 但服务端无全局 Key → 立即报「系统未配置」，不再放行到确认卡。
3. 配了 Key 但网关不可达 / Key 无效 → 连通性探测失败，抛 LLMNotConfigured。
4. 探测结果带 TTL 缓存：成功/失败结论在缓存期内不重复探测；换 Key 重新探测。
5. 端点级：深度分析在探测失败时返回短 error 流，不进 agent 循环。
"""
import threading
import time
from collections import OrderedDict

import pytest

from backend.services import llm as llm_svc
from backend.services.llm import LLMNotConfigured


def _admin_user():
    """admin（dev_admin 身份，有 system 权限点 → 允许回落全局 .env）。"""
    return {"id": "u-admin", "identity": "dev_admin"}


@pytest.fixture(autouse=True)
def _fresh_conn_cache(monkeypatch):
    # 缓存实现是 OrderedDict（LRU 淘汰 + move_to_end），普通 dict 没有 move_to_end
    monkeypatch.setattr(llm_svc, "_conn_cache", OrderedDict())
    monkeypatch.setattr(llm_svc, "BASE_URL", "http://gw.test/v1")


def test_non_admin_without_personal_key_still_blocked(app_env):
    """非管理员未配个人 Key：resolve_llm 的权限规则不变，直接抛。"""
    with pytest.raises(LLMNotConfigured) as ei:
        llm_svc.ensure_llm_ready({"id": "u-alice", "identity": "default"})
    assert "个人 LLM API Key" in str(ei.value)


def test_admin_fallback_without_global_key_raises_immediately(seeded, monkeypatch):
    """admin 未配个人 Key + 服务端无全局 Key：立即报错（此前会放行到确认卡）。"""
    monkeypatch.setattr(llm_svc, "_global_env_key", lambda: "")
    with pytest.raises(LLMNotConfigured) as ei:
        llm_svc.ensure_llm_ready(_admin_user())
    assert "系统未配置 LLM API Key" in str(ei.value)


def test_probe_failure_blocks_and_caches_failure(seeded, monkeypatch):
    """配了 Key 但探测失败 → 抛错；失败结论在 TTL 内缓存，不重复打网关。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-global", "api_base": None, "model": None})
    calls = []

    def fake_probe(base, key):
        calls.append(base)
        return False, "网关不可达测试文案"

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    for _ in range(2):
        with pytest.raises(LLMNotConfigured) as ei:
            llm_svc.ensure_llm_ready({"id": "u-any"})
        assert "网关不可达测试文案" in str(ei.value)
    assert len(calls) == 1


def test_probe_401_reports_invalid_key(seeded, monkeypatch):
    """Key 无效（401）→ 文案指向检查/更新 Key。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-bad", "api_base": None, "model": None})
    monkeypatch.setattr(llm_svc, "_probe_llm", lambda base, key: (False, "LLM API Key 无效"))
    with pytest.raises(LLMNotConfigured) as ei:
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert "API Key" in str(ei.value)


def test_probe_success_cached(seeded, monkeypatch):
    """探测成功 → 放行；TTL 内重复调用不重新探测。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-personal", "api_base": None, "model": None})
    calls = []

    def fake_probe(base, key):
        calls.append(key)
        return True, ""

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    llm_svc.ensure_llm_ready({"id": "u-any"})
    llm_svc.ensure_llm_ready({"id": "u-any"})
    assert calls == ["sk-personal"]


def test_key_change_reprobes(seeded, monkeypatch):
    """换 Key → 缓存键不同 → 重新探测。"""
    keys = iter(["sk-a", "sk-b"])
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": next(keys), "api_base": None, "model": None})
    calls = []

    def fake_probe(base, key):
        calls.append(key)
        return True, ""

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    llm_svc.ensure_llm_ready({"id": "u-any"})
    llm_svc.ensure_llm_ready({"id": "u-any"})
    assert calls == ["sk-a", "sk-b"]


def test_deep_stream_llm_gate_short_error(client, seeded, monkeypatch):
    """端点级：深度分析在 LLM 探测失败时返回短 error 流，不进 agent 循环。"""
    import backend.routers.agent as agent_router

    def _raise(user):
        raise LLMNotConfigured("探测失败文案")

    monkeypatch.setattr(agent_router._llm_svc, "ensure_llm_ready", _raise)
    token = client.post("/api/auth/login",
                        json={"username": "admin", "password": "admin123"}).json()["access_token"]
    r = client.post(
        "/api/agent/chat/stream",
        json={"message": "分析一下流水", "history": []},
        headers={"Authorization": f"Bearer {token}", "X-Game": "kof"},
    )
    assert r.status_code == 200
    assert '"type": "error"' in r.text and "探测失败文案" in r.text
    assert '"type": "final"' in r.text and '"success": false' in r.text


def test_chat_llm_gate_errors_before_confirm_card(client, seeded, monkeypatch):
    """端点级：聊天窗口 LLM 探测失败 → 立即 error，不再先弹「自由生成SQL」确认卡。"""
    import backend.routers.chat as chat_router

    def _raise(user):
        raise LLMNotConfigured("探测失败文案")

    monkeypatch.setattr(chat_router, "ensure_llm_ready", _raise)
    token = client.post("/api/auth/login",
                        json={"username": "admin", "password": "admin123"}).json()["access_token"]
    r = client.post(
        "/api/chat",
        json={"model": "deepseek-chat", "message": "最近7天流水怎么样", "history": []},
        headers={"Authorization": f"Bearer {token}", "X-Game": "kof"},
    )
    assert r.status_code == 200
    assert '"type": "error"' in r.text and "探测失败文案" in r.text
    assert "ai_report_confirm" not in r.text


# ---- 对抗审查 2026-10-23 收口后的探测语义回归（3xx/404/405 可用、负缓存、单飞、上限）----

class _FakeResp:
    def __init__(self, code):
        self.status_code = code


def _mock_probe_response(monkeypatch, code):
    monkeypatch.setattr(llm_svc._requests, "get", lambda *a, **k: _FakeResp(code))
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-x", "api_base": None, "model": None})


def test_probe_404_treated_available(seeded, monkeypatch):
    """网关不实现 /models（404）但 chat 可用：视为可用，不再假阴性硬阻断。"""
    _mock_probe_response(monkeypatch, 404)
    llm = llm_svc.ensure_llm_ready({"id": "u-any"})
    assert llm["api_key"] == "sk-x"


def test_probe_405_and_3xx_treated_available(seeded, monkeypatch):
    """405 / 3xx（网关对 /models 的重定向应答）同样视为可用。"""
    for code in (405, 301, 307):
        _mock_probe_response(monkeypatch, code)
        monkeypatch.setattr(llm_svc, "_conn_cache", OrderedDict())  # 各状态码独立探测
        llm = llm_svc.ensure_llm_ready({"id": "u-any"})
        assert llm["api_key"] == "sk-x"


def test_probe_401_still_blocks_with_key_hint(seeded, monkeypatch):
    """401 仍是硬失败，文案指向检查 Key。"""
    _mock_probe_response(monkeypatch, 401)
    with pytest.raises(LLMNotConfigured) as ei:
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert "API Key" in str(ei.value)


def test_probe_500_blocks_with_status(seeded, monkeypatch):
    _mock_probe_response(monkeypatch, 500)
    with pytest.raises(LLMNotConfigured) as ei:
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert "500" in str(ei.value)


def test_failure_cache_expires_and_reprobes(seeded, monkeypatch):
    """失败结论 30s 后过期重探测；29s 内仍是负缓存命中。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-x", "api_base": None, "model": None})
    clock = [1000.0]
    monkeypatch.setattr(llm_svc, "_now", lambda: clock[0])
    calls = []

    def fake_probe(base, key):
        calls.append(1)
        return False, "失败文案"

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    for _ in range(2):
        with pytest.raises(LLMNotConfigured):
            llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(calls) == 1  # 30s 内负缓存命中
    clock[0] += 29
    with pytest.raises(LLMNotConfigured):
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(calls) == 1  # 29s 仍在 TTL 内
    clock[0] += 2  # 31s：过期
    with pytest.raises(LLMNotConfigured):
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(calls) == 2  # 重新探测


def test_singleflight_concurrent_probe_shared(seeded, monkeypatch):
    """并发首问共享一次探测（每键单飞锁），不重复打网关。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-x", "api_base": None, "model": None})
    calls = []
    call_guard = threading.Lock()

    def slow_probe(base, key):
        with call_guard:
            calls.append(1)
        time.sleep(0.2)
        return True, ""

    monkeypatch.setattr(llm_svc, "_probe_llm", slow_probe)
    barrier = threading.Barrier(5)
    results = []

    def worker():
        barrier.wait()
        results.append(llm_svc.ensure_llm_ready({"id": "u-any"}))

    threads = [threading.Thread(target=worker) for _ in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(calls) == 1
    assert len(results) == 5


def test_conn_cache_bounded(seeded, monkeypatch):
    """(base, key) 组合大量增长时缓存上限 256，不无限膨胀。"""
    keys = [f"sk-{i}" for i in range(400)]

    def fake_resolve(user):
        return {"api_key": keys.pop(0), "api_base": None, "model": None}

    monkeypatch.setattr(llm_svc, "resolve_llm", fake_resolve)
    monkeypatch.setattr(llm_svc, "_probe_llm", lambda base, key: (True, ""))
    for _ in range(400):
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(llm_svc._conn_cache) <= llm_svc._CONN_CACHE_MAX


def test_clear_probe_cache_forces_reprobe(seeded, monkeypatch):
    """test-llm 成功后清缓存 → 下次 ensure_llm_ready 立即重新探测。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-x", "api_base": None, "model": None})
    calls = []

    def fake_probe(base, key):
        calls.append(1)
        return True, ""

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(calls) == 1
    llm_svc.clear_probe_cache("http://gw.test/v1", "sk-x")
    llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(calls) == 2


def test_base_trailing_slash_normalized(seeded, monkeypatch):
    """同一网关地址带/不带尾斜杠命中同一缓存键（否则同 Key 会探测两次）。"""
    bases = iter(["http://gw.test/v1/", "http://gw.test/v1"])
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-x", "api_base": next(bases), "model": None})
    calls = []

    def fake_probe(base, key):
        calls.append(base)
        return True, ""

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    llm_svc.ensure_llm_ready({"id": "u-any"})
    llm_svc.ensure_llm_ready({"id": "u-any"})
    assert len(calls) == 1  # 尾斜杠归一后命中同一缓存键


# ---- 对抗审查 2026-10-23 二轮：条目身份守卫 / 在飞标记 ----

def test_finish_ignores_stale_entry_after_recreate(seeded, monkeypatch):
    """探测期间条目被 clear 后重建：旧探测的结论不得写进新条目（身份号守卫）。"""
    tgt = llm_svc._cache_key("http://gw.test/v1", "sk-target")
    old = llm_svc._entry(tgt)
    llm_svc.clear_probe_cache("http://gw.test/v1", "sk-target")
    new = llm_svc._entry(tgt)
    assert new["id"] != old["id"]
    llm_svc._finish(tgt, old["id"], True, "旧结论")
    assert new["ok"] is None and new["msg"] == ""  # 旧结论被丢弃
    llm_svc._finish(tgt, new["id"], False, "新结论")
    assert new["ok"] is False and new["msg"] == "新结论"


def test_reprobe_marks_expired_entry_inflight(seeded, monkeypatch):
    """过期条目重新探测前标记回 ok=None：期间不可被容量淘汰/当结论读取。"""
    tgt = llm_svc._cache_key("http://gw.test/v1", "sk-target")
    ent = llm_svc._entry(tgt)
    llm_svc._finish(tgt, ent["id"], True, "")
    assert ent["ok"] is True
    llm_svc._mark_inflight(tgt, ent["id"])
    assert ent["ok"] is None


def test_inflight_entry_not_evicted_under_pressure(seeded, monkeypatch):
    """探测中的条目（ok=None）在缓存容量压力下不被淘汰。"""
    tgt = llm_svc._cache_key("http://gw.test/v1", "sk-target")
    ent = llm_svc._entry(tgt)  # 新建即 in-flight
    for i in range(300):
        e = llm_svc._entry(("http://gw.test/v1", f"k{i}"))
        e["ok"] = True  # 已出结论的条目才是可淘汰对象（探测中条目不可淘汰）
    assert llm_svc._conn_cache.get(tgt) is ent
    assert len(llm_svc._conn_cache) <= llm_svc._CONN_CACHE_MAX


def test_clear_probe_cache_during_probe_no_stale_overwrite(seeded, monkeypatch):
    """在飞探测被 clear_probe_cache 打断、他人重建条目并探测：旧探测结论不得覆盖新条目。"""
    monkeypatch.setattr(
        llm_svc, "resolve_llm",
        lambda user: {"api_key": "sk-x", "api_base": None, "model": None})
    entered = threading.Event()
    calls = []

    def fake_probe(base, key):
        n = len(calls)
        calls.append(n)
        if n == 0:  # 线程 A：慢探测（期间被 clear + 重建）
            entered.set()
            time.sleep(0.3)
            return True, ""
        return False, "B 的新结论"  # 线程 B：重建条目后的快探测

    monkeypatch.setattr(llm_svc, "_probe_llm", fake_probe)
    results = []

    def worker_a():
        try:
            results.append(("a", llm_svc.ensure_llm_ready({"id": "u-any"})))
        except LLMNotConfigured as e:
            results.append(("a", str(e)))

    t = threading.Thread(target=worker_a)
    t.start()
    assert entered.wait(5), "探测未开始"
    llm_svc.clear_probe_cache("http://gw.test/v1", "sk-x")  # 打断 A 的探测周期
    with pytest.raises(LLMNotConfigured) as ei:  # B：重建条目并得出失败结论
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert "B 的新结论" in str(ei.value)
    t.join(10)

    # 缓存里是 B 的结论，未被 A 的旧结论覆盖；后续调用直接命中 B 的负缓存
    with pytest.raises(LLMNotConfigured) as ei2:
        llm_svc.ensure_llm_ready({"id": "u-any"})
    assert "B 的新结论" in str(ei2.value)
    assert len(calls) == 2  # 第三次是缓存命中，不再探测
