"""P1-20/21：按用户限流与并发闸（进程内实现，纯单元测试，不依赖外部服务）。"""
import pytest
from fastapi import HTTPException

from backend.services import rate_limit as rl


class _FakeRequest:
    def __init__(self, host="1.2.3.4"):
        self.client = type("_C", (), {"host": host})()


@pytest.fixture()
def fresh(monkeypatch):
    """每个用例重置模块级状态（限流桶/并发信号量）。"""
    monkeypatch.setattr(rl, "_buckets", {})
    monkeypatch.setattr(rl, "_slots", {})
    return rl


def _req(host="1.2.3.4"):
    return _FakeRequest(host)


def test_check_rate_blocks_over_limit(fresh):
    u = {"id": "u1"}
    fresh.check_rate(u, _req(), 2)  # 1
    fresh.check_rate(u, _req(), 2)  # 2
    with pytest.raises(HTTPException) as ei:
        fresh.check_rate(u, _req(), 2)  # 3 → 429
    assert ei.value.status_code == 429


def test_check_rate_per_user_isolated(fresh):
    u1, u2 = {"id": "u1"}, {"id": "u2"}
    fresh.check_rate(u1, _req(), 1)
    with pytest.raises(HTTPException):
        fresh.check_rate(u1, _req(), 1)
    fresh.check_rate(u2, _req(), 1)  # u2 不受 u1 影响


def test_anonymous_uses_ip(fresh):
    # 匿名（无 id）按来源 IP 归桶：同一 IP 共享额度
    fresh.check_rate(None, _req(), 1)
    with pytest.raises(HTTPException):
        fresh.check_rate(None, _req(), 1)
    fresh.check_rate(None, _req(host="5.6.7.8"), 1)  # 另一 IP 不受影响


def test_window_resets(fresh, monkeypatch):
    fake_now = [1000.0]
    monkeypatch.setattr(rl.time, "monotonic", lambda: fake_now[0])
    u = {"id": "u1"}
    fresh.check_rate(u, _req(), 1)
    with pytest.raises(HTTPException):
        fresh.check_rate(u, _req(), 1)
    fake_now[0] += 61.0  # 窗口滑过
    fresh.check_rate(u, _req(), 1)  # 重新放行


def test_acquire_slot_blocks_when_full(fresh):
    u = {"id": "u1"}
    k1 = fresh.acquire_slot(u, _req(), 2)
    k2 = fresh.acquire_slot(u, _req(), 2)
    assert k1 == k2 == "u:u1"
    with pytest.raises(HTTPException) as ei:
        fresh.acquire_slot(u, _req(), 2)  # 第 3 个 → 429（不排队）
    assert ei.value.status_code == 429


def test_release_frees_slot(fresh):
    u = {"id": "u1"}
    fresh.acquire_slot(u, _req(), 1)
    with pytest.raises(HTTPException):
        fresh.acquire_slot(u, _req(), 1)
    fresh.release_slot("u:u1")
    fresh.acquire_slot(u, _req(), 1)  # 释放后可再占
