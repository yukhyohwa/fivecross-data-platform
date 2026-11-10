"""线程安全 token 用量累加器（审计 P2-7：contextvars 上下文桶，并发多用户互不串桶）。

`chat_completion` 每次调用时把返回的 `usage` 记入当前请求的累加桶；调用方（如聊天
端点）在请求入口 `start()`、出口 `finish()` 汇总。

并发模型（审计 P2-7 由「模块级全局 + 锁」改造而来；原实现假设同时至多一个活跃请求，
多用户并发时会把不同请求的用量混进同一个桶）：
- 桶是 `contextvars.ContextVar` 里的可变 list：每个请求/调用链有自己的上下文副本，
  同一链路的线程（含并行 worker）共享同一个 list 对象，跨请求的上下文互不可见。
- FastAPI 同步端点 + 同步 SSE 生成器跑在线程池，且每个生成器步的 contextvars 都从
  「路由任务上下文」复制一份（步内设置不会传给后续步），因此桶必须在路由任务上下文
  里先建好：chat 端点经 async 依赖 `_usage_scope` 调 start()，后续每个生成器步与
  finish() 才能看到同一个桶。
- ThreadPoolExecutor 不会自动传播 contextvars：并行 worker 需各自用 `clone_context(ctx).run`
  把当前上下文（含用量桶）带进去（backend/services/retrieval.py、skill_bundle.py），
  worker 线程里的 record() 才能记回本请求的桶；不可直接并发 `ctx.run`（不可重入）。
非聊天调用（未 `start()`）`record()` 直接 no-op，保持原行为。
"""
import contextvars
import threading

# 当前调用链的累加桶：值为 list（可变对象），同链路各上下文副本共享同一个 list、写入互见；
# 跨请求的上下文互不共享，杜绝全局桶混算。
_bucket: contextvars.ContextVar[list | None] = contextvars.ContextVar(
    "usage_tracker_bucket", default=None
)
# 仅保护对桶 list 的并发写入（同链路的并行 worker 线程可能同时 append）。
_lock = threading.Lock()


def clone_context(ctx: contextvars.Context) -> contextvars.Context:
    """返回 ctx 的一份新副本，可独立（含并发）进入。

    ``Context.run`` 不可重入：同一个 Context 对象不能同时被多个线程 run，否则抛
    ``RuntimeError: cannot enter context: ... is already entered``（「刷新快照」并发
    改写、并行检索正是踩到这里）。线程池并行 worker 需各自 clone 一份再 run：每份是
    独立 Context 对象、只进入一次，彼此互不干扰；ctx 里的可变对象（如用量桶 list）仍
    按引用共享，worker 里的 record() 照常记回本请求的桶。
    """
    child = contextvars.Context()
    for var, value in ctx.items():
        child.run(var.set, value)
    return child

# 价格表（元 / 百万 token，输入 / 输出）——估算占位值，可在 data_ai/pricing.json 覆盖
DEFAULT_PRICING = {
    "claude-opus-4-6": {"input": 75.0, "output": 375.0},
    "claude-haiku-4-5": {"input": 7.0, "output": 35.0},
    "gpt-5-5": {"input": 9.0, "output": 36.0},
    "gpt-5-mini": {"input": 1.5, "output": 6.0},
    "gemini-3.1-pro": {"input": 9.0, "output": 36.0},
    "gemini-3-6-flash": {"input": 0.5, "output": 2.0},
    "deepseek-v4-flash": {"input": 0.5, "output": 1.5},
    "deepseek-v4-pro": {"input": 2.0, "output": 6.0},
    "glm-5-2": {"input": 1.0, "output": 4.0},
    "glm-flash-latest": {"input": 0.5, "output": 1.5},
}


def start() -> None:
    """开启一次请求的用量收集：在当前上下文建空桶（重复调用会重置当前上下文的桶）。"""
    _bucket.set([])


def record(model: str, usage: dict | None) -> None:
    """记一次 LLM 调用的用量；当前上下文无桶（未 start）时 no-op。"""
    if not usage:
        return
    bucket = _bucket.get()
    if bucket is None:
        return
    prompt = int(usage.get("prompt_tokens") or 0)
    completion = int(usage.get("completion_tokens") or 0)
    total = int(usage.get("total_tokens") or (prompt + completion))
    with _lock:
        bucket.append({
            "model": model,
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": total,
        })


def finish() -> dict:
    """汇总并清空当前上下文的累加桶。返回 {calls, prompt_tokens, completion_tokens, total_tokens}。

    当前上下文无桶（未 start）时返回全零结构，保持旧行为。
    """
    bucket = _bucket.get()
    if not bucket:
        return {"calls": [], "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    with _lock:
        calls = list(bucket)
        bucket.clear()
    return {
        "calls": calls,
        "prompt_tokens": sum(c["prompt_tokens"] for c in calls),
        "completion_tokens": sum(c["completion_tokens"] for c in calls),
        "total_tokens": sum(c["total_tokens"] for c in calls),
    }
