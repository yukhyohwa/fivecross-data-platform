"""按用户限流与并发闸（审计 P1-20 / P1-21）。

进程内实现（单进程 uvicorn 足够，无需 Redis）：
- 限流：固定窗口计数器（次/分钟），按用户 id；匿名/网关模式按来源 IP。
- 并发闸：有界信号量，同一用户同时最多 N 个分析流；名额已满的请求直接 429，不排队等。
  （chat 是同步 def 端点，跑在线程池里；无限并发会把线程池拖垮、拖慢所有人的请求。）

失败模式宽松：本模块只读 request.client，任何异常都不影响业务主流程。
"""
import threading
import time

from fastapi import HTTPException, Request

# ── 限流（P1-21）：固定窗口计数器，次/分钟 ──
CHAT_LIMIT_PER_MINUTE = 30      # 普通对话（含自动报告）
AGENT_LIMIT_PER_MINUTE = 10     # 深度分析最多 12 轮工具调用，更贵，单独收紧
_WINDOW_SECONDS = 60.0
_MAX_KEYS = 10000               # 顺带清理的桶上限，防匿名 IP 无限增长

_buckets: dict[str, tuple[int, float]] = {}  # key -> (count, window_start)
_lock = threading.Lock()


def _user_key(user: dict | None, request: Request | None) -> str:
    uid = (user or {}).get("id")
    if uid:
        return f"u:{uid}"
    ip = "unknown"
    try:
        ip = request.client.host if request and request.client else "unknown"
    except Exception:
        pass
    return f"ip:{ip}"


def _is_admin(user: dict | None) -> bool:
    """限流豁免（审计 P1-21）：仅登录用户且拥有 system 权限点才豁免。

    注意必须排除匿名：has_perm 对匿名用户恒真（全量权限回落），
    匿名流量仍按来源 IP 限流，否则未登录可无限刷 LLM。
    """
    if not (user or {}).get("id"):
        return False
    try:
        from backend.ide_app.services.permissions import has_perm
        return has_perm(user, "system")
    except Exception:
        return False


def _allow(key: str, limit: int) -> bool:
    now = time.monotonic()
    with _lock:
        entry = _buckets.get(key)
        if entry is None or now - entry[1] >= _WINDOW_SECONDS:
            _buckets[key] = (1, now)
            return True
        count, start = entry
        if count >= limit:
            return False
        _buckets[key] = (count + 1, start)
        if len(_buckets) > _MAX_KEYS:  # 清理过期桶，防无限增长
            stale = [k for k, (_c, s) in _buckets.items() if now - s >= _WINDOW_SECONDS]
            for k in stale:
                _buckets.pop(k, None)
        return True


def check_rate(user: dict | None, request: Request, limit: int) -> None:
    """每分钟超过 limit 次抛 429；管理员（system 权限点）不限流（审计 P1-21）。"""
    if _is_admin(user):
        return
    if _allow(_user_key(user, request), limit):
        return
    raise HTTPException(status_code=429, detail="请求过于频繁，请稍后再试（每分钟限流）。")


# ── 并发闸（P1-20）：同一用户同时最多 N 个分析流 ──
CHAT_MAX_CONCURRENT = 2
AGENT_MAX_CONCURRENT = 1

_slots: dict[str, threading.BoundedSemaphore] = {}


def acquire_slot(user: dict | None, request: Request, max_concurrent: int) -> str:
    """占用一个并发名额（非阻塞），返回 key 供 release_slot 释放；名额已满抛 429。"""
    key = _user_key(user, request)
    with _lock:
        sem = _slots.get(key)
        if sem is None:
            sem = threading.BoundedSemaphore(max_concurrent)
            _slots[key] = sem
    if not sem.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="当前分析任务较多，请等上一轮完成后再试。")
    return key


def release_slot(key: str) -> None:
    sem = _slots.get(key)
    if sem:
        sem.release()
