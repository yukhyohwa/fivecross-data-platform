"""审计 P2-7 并发修复：线程池并行 worker 不能并发 run 同一个 Context（不可重入），
必须各自 clone_context 一份再 run，否则「刷新快照」/并行检索抛 RuntimeError already entered。"""
import contextvars
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from analysis.usage_tracker import clone_context


def test_clone_context_carries_values_but_is_independent():
    cv = contextvars.ContextVar("cv", default="DEFAULT")
    cv.set("CALLER")
    parent = contextvars.copy_context()

    child = clone_context(parent)
    assert child.run(cv.get) == "CALLER"

    # 独立进入：子上下文可以再进入一次，父上下文不受影响
    assert child.run(cv.get) == "CALLER"
    assert parent.run(cv.get) == "CALLER"


def test_clone_context_shares_mutable_values_by_reference():
    # 用量桶是 contextvars 里的可变 list：clone 后必须仍共享同一 list，worker 里 record() 才能记回本请求
    bucket = contextvars.ContextVar("bucket", default=None)
    bucket.set([])
    parent = contextvars.copy_context()

    child = clone_context(parent)
    child.run(lambda: bucket.get().append("x"))
    assert parent.run(lambda: bucket.get()) == ["x"]


def test_concurrent_clone_run_does_not_raise_already_entered():
    cv = contextvars.ContextVar("cv", default="DEFAULT")
    cv.set("CALLER")
    parent = contextvars.copy_context()

    def worker(name):
        time.sleep(0.05)  # 强制重叠，暴露「同 Context 并发 run」的竞态
        return (name, cv.get())

    with ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(lambda n: clone_context(parent).run(worker, n), range(8)))

    assert all(value == "CALLER" for _, value in results)
    assert len(results) == 8
