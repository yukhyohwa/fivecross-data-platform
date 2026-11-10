"""专项「自动生成快照」（/plan → build_planned_snapshot）回归测试。

2026-10-28 优化：多条步骤 SQL 的改写/生成从串行改为并发 4（对齐保存/刷新路径
build_sql_snapshots），是「自动生成快照」慢的主因修复。这里锁三条口径：
1. 并发化后结果与串行一致（已有→改写、缺失→生成、溯源 mode 正确）；
2. 多条 SQL 确实落在多个线程（旧串行实现只会是 1 个线程）；
3. 边界：单条 SQL 走串行兜底、内嵌件（源不在全局库）只重盖章不 LLM 改写。
"""
import threading
import time

from backend.services import skill_bundle


def _existing(name, step="步骤"):
    return {"name": name, "status": "existing", "step": step, "section": "", "brief": ""}


def _missing(name, step="步骤", brief="取数要求"):
    return {"name": name, "status": "missing", "step": step, "section": "", "brief": brief}


def test_planned_snapshot_builds_existing_and_missing(app_env, monkeypatch):
    """已有 SQL 走改写、缺失 SQL 走生成，溯源 mode 分别 follow/pin（并发化后结果不变）。"""
    monkeypatch.setattr(skill_bundle.sql_store, "read_sql",
                        lambda name: "SELECT 1" if name in ("a.sql", "b.sql") else "")
    monkeypatch.setattr(skill_bundle, "rewrite_sql",
                        lambda model, original, prompts, skill_text=None: (f"REWRITTEN:{original}", "raw"))
    monkeypatch.setattr(skill_bundle, "generate_sql",
                        lambda model, schema, q, docs=None: ("GENERATED", "raw"))

    plan_sqls = [_existing("a.sql"), _existing("b.sql"), _missing("c.sql"), _missing("d.sql")]
    out = skill_bundle.build_planned_snapshot("m", "专项文本", plan_sqls, "schema", [], [], None)

    assert set(out["sqls"].keys()) == {"a.sql", "b.sql", "c.sql", "d.sql"}
    assert out["sqls"]["a.sql"].startswith("REWRITTEN:SELECT 1")
    assert out["sqls"]["c.sql"].startswith("GENERATED")
    prov = out["provenance"]["sql"]
    assert prov["a.sql"]["mode"] == "follow" and prov["a.sql"]["source"] == "a.sql"
    assert prov["c.sql"]["mode"] == "pin" and prov["c.sql"]["source"] == ""
    assert out["knowledge"] == {} and out["models"] == {} and out["pred_sql"] is None


def test_planned_snapshot_sql_build_is_concurrent(app_env, monkeypatch):
    """多条步骤 SQL 的改写必须真正并发（旧串行实现同一时刻最多 1 条在跑，是慢的主因）。"""
    seen_threads = set()
    active = 0
    max_active = 0
    lock = threading.Lock()

    def fake_rewrite(model, original, prompts, skill_text=None):
        nonlocal active, max_active
        with lock:
            active += 1
            max_active = max(max_active, active)
            seen_threads.add(threading.get_ident())
        time.sleep(0.05)  # 让并发窗口可观测（sleep 释放 GIL，4 个 worker 得以同时进入）
        with lock:
            active -= 1
        return original, "raw"

    monkeypatch.setattr(skill_bundle, "rewrite_sql", fake_rewrite)
    monkeypatch.setattr(skill_bundle.sql_store, "read_sql", lambda name: "SELECT 1")

    plan_sqls = [_existing(f"s{i}.sql", step=f"步骤{i}") for i in range(4)]
    skill_bundle.build_planned_snapshot("m", "文本", plan_sqls, "", [], [], None)
    assert max_active >= 2  # 串行 max_active 恒为 1
    assert len(seen_threads) >= 2


def test_planned_snapshot_single_sql_serial_path(app_env, monkeypatch):
    """单条 SQL 走串行兜底分支（不建线程池），结果照常改写。"""
    calls = []
    monkeypatch.setattr(skill_bundle, "rewrite_sql",
                        lambda model, original, prompts, skill_text=None: calls.append(original) or (f"R:{original}", "raw"))
    monkeypatch.setattr(skill_bundle.sql_store, "read_sql", lambda name: "SELECT 1")

    out = skill_bundle.build_planned_snapshot("m", "文本", [_existing("a.sql")], "", [], [], None)
    assert len(calls) == 1
    assert out["sqls"]["a.sql"].startswith("R:SELECT 1")


def test_planned_snapshot_embedded_snapshot_frozen_without_llm(app_env, monkeypatch):
    """源不在全局 SQL 库的内嵌快照：只重盖章冻结，不触发 LLM 改写。"""
    rewritten = []
    monkeypatch.setattr(skill_bundle, "rewrite_sql",
                        lambda *a, **k: rewritten.append(1) or ("X", "raw"))
    monkeypatch.setattr(skill_bundle.sql_store, "read_sql", lambda name: "")  # 源不在全局库

    out = skill_bundle.build_planned_snapshot(
        "m", "文本", [_existing("e.sql", step="新步骤")], "", [], [], None,
        embedded_sqls={"e.sql": "SELECT 1"},
    )
    assert rewritten == []  # 内嵌件不 LLM 改写
    assert out["sqls"]["e.sql"] == "SELECT 1"
    assert out["provenance"]["sql"]["e.sql"]["mode"] == "follow"
