"""模型管理（2026-10-26）：全站 LLM 模型槽位 store（model_config.json）+
/api/admin/config/models 端点 + 任务选型接入（config.task_model / 兜底模型）。

解析优先级：模型管理 store > 环境变量 > 任务默认 > 系统默认；
老 report_config.json 一次性迁移进 store。conftest 已全量隔离 store 路径。
"""
import json

import pytest

from backend import config
from backend.services import model_config
from backend.services import report_config


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """清掉机器环境里可能存在的模型相关变量，保证来源断言稳定。

    注意：AGENT_MODEL/AGENT_FALLBACK_MODEL/SPLIT_MODEL 是 import 期从环境读取的常量，
    只删环境变量不够（本机若有 AGENT_MODEL=xyz，常量已固化为 xyz），需一并归一。
    """
    for k in ("TASK_MODEL_CHAT", "TASK_MODEL_SQL", "TASK_MODEL_KB", "TASK_MODEL_SKILL",
              "TASK_MODEL_MODEL", "TASK_MODEL_REPORT_GEN", "TASK_MODEL_REPORT_VER",
              "TASK_MODEL_REPORT_SUM", "TASK_MODEL_GAP", "AGENT_MODEL",
              "AGENT_FALLBACK_MODEL", "SPLIT_MODEL", "LITELLM_FALLBACK_MODEL", "DEFAULT_MODEL"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setattr(config, "AGENT_MODEL", "deepseek-v4-pro")
    monkeypatch.setattr(config, "AGENT_FALLBACK_MODEL", "deepseek-v4-flash")
    monkeypatch.setattr(config, "SPLIT_MODEL", "deepseek-v4-flash")


# ---- store 读写 ----

def test_read_missing_store_returns_empty():
    assert model_config.read_model_config() == {}


def test_read_ignores_garbage_and_unknown_keys(monkeypatch, tmp_path):
    p = tmp_path / "model_config.json"
    p.write_text('{"sql": "x", "nope": "deepseek-v4-pro", "chat": ["bad"]}', encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    assert model_config.read_model_config() == {}


def test_read_non_dict_json_does_not_crash(monkeypatch, tmp_path):
    p = tmp_path / "model_config.json"
    p.write_text("[]", encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    assert model_config.read_model_config() == {}


def test_write_valid_and_clear(monkeypatch, tmp_path):
    p = tmp_path / "model_config.json"
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    good = config.available_models()[-1]
    model_config.write_model_config({"sql": good, "report_ver": good})
    assert model_config.read_model_config() == {"sql": good, "report_ver": good}
    # 空串 = 清除覆盖
    model_config.write_model_config({"sql": "", "report_ver": ""})
    assert model_config.read_model_config() == {}


def test_write_ignores_invalid_and_unknown_keys(monkeypatch, tmp_path):
    p = tmp_path / "model_config.json"
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    good = config.available_models()[-1]
    stored = model_config.write_model_config({"sql": good, "kb": "x", "nope": good})
    assert stored == {"sql": good}


def test_migration_from_legacy_report_config(monkeypatch, tmp_path):
    # 老 report_config.json（报告三模型）→ 首次读 store 时一次性迁移落盘
    legacy = tmp_path / "report_config.json"
    good = config.available_models()[-1]
    legacy.write_text(json.dumps({"model_gen": good, "model_ver": "", "model_sum": good}), encoding="utf-8")
    monkeypatch.setattr(config, "REPORT_CONFIG_PATH", legacy)
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    cfg = model_config.read_model_config()
    assert cfg == {"report_gen": good, "report_sum": good}
    written = json.loads((tmp_path / "model_config.json").read_text(encoding="utf-8"))
    assert written == {"report_gen": good, "report_sum": good}


def test_migration_ignores_garbage_legacy(monkeypatch, tmp_path):
    legacy = tmp_path / "report_config.json"
    legacy.write_text('{"model_gen": "x", "model_ver": "y", "model_sum": "z"}', encoding="utf-8")
    monkeypatch.setattr(config, "REPORT_CONFIG_PATH", legacy)
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    assert model_config.read_model_config() == {}


def test_migration_is_one_shot_and_preserves_later_writes(monkeypatch, tmp_path):
    """迁移只跑一次：后续写不改回老文件；store 被删后也不再从老文件重新迁移（对抗审查）。"""
    legacy = tmp_path / "report_config.json"
    good = config.available_models()[-1]
    legacy.write_text(json.dumps({"model_gen": good}), encoding="utf-8")
    store_path = tmp_path / "model_config.json"
    monkeypatch.setattr(config, "REPORT_CONFIG_PATH", legacy)
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", store_path)
    assert model_config.read_model_config() == {"report_gen": good}
    # 迁移后继续写其它槽位：不重跑迁移、不丢已迁移的覆盖
    model_config.write_model_config({"sql": good})
    assert model_config.read_model_config() == {"report_gen": good, "sql": good}
    # 老文件被改坏/删 store：读时已记账，绝不重新迁移（否则脏数据复活）
    legacy.write_text('{"model_sum": "x"}', encoding="utf-8")
    store_path.unlink()
    assert model_config.read_model_config() == {}


def test_empty_write_does_not_create_file(monkeypatch, tmp_path):
    """空写不落盘：store 从未存在且无可写内容时，不创建文件（保留「未迁移」状态，后续读仍可迁移）。"""
    p = tmp_path / "model_config.json"
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    model_config.write_model_config({})
    assert not p.exists()


def test_corrupt_store_reads_empty_and_write_backs_up(monkeypatch, tmp_path):
    """损坏的 store 读为空、不崩；下一次合法写先备份原损坏文件到 .bak（对抗审查）。"""
    p = tmp_path / "model_config.json"
    p.write_text("{not json", encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    assert model_config.read_model_config() == {}
    good = config.available_models()[-1]
    model_config.write_model_config({"sql": good})
    bak = tmp_path / "model_config.json.bak"
    assert bak.exists()
    assert bak.read_text(encoding="utf-8") == "{not json"
    assert model_config.read_model_config() == {"sql": good}


def test_concurrent_writes_do_not_lose_updates(monkeypatch, tmp_path):
    """并发写两个槽位：锁内读-改-写串行化，两个覆盖都落盘（不丢更新）。"""
    import threading

    p = tmp_path / "model_config.json"
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    models = config.available_models()
    good1, good2 = models[-1], (models[-2] if len(models) > 1 else models[-1])
    barrier = threading.Barrier(2)

    def w_sql():
        barrier.wait()
        model_config.write_model_config({"sql": good1})

    def w_kb():
        barrier.wait()
        model_config.write_model_config({"kb": good2})

    t1, t2 = threading.Thread(target=w_sql), threading.Thread(target=w_kb)
    t1.start(); t2.start(); t1.join(); t2.join()
    assert model_config.read_model_config() == {"sql": good1, "kb": good2}


# ---- 解析优先级 ----

def test_resolve_store_wins_over_env(monkeypatch, tmp_path):
    monkeypatch.setenv("TASK_MODEL_SQL", "deepseek-v4-flash")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    good = config.available_models()[-1]
    model_config.write_model_config({"sql": good})
    assert config.task_model("sql") == good
    assert model_config._resolve("sql")[1] == "模型管理"


def test_resolve_env_wins_over_default(monkeypatch):
    monkeypatch.setenv("TASK_MODEL_SQL", "deepseek-v4-flash")
    assert config.task_model("sql") == "deepseek-v4-flash"
    assert model_config._resolve("sql")[1] == "环境变量"


def test_resolve_special_defaults():
    assert config.task_model("agent") == config.AGENT_MODEL
    assert config.task_model("split") == config.SPLIT_MODEL
    assert config.task_model("report_ver") == "deepseek-v4-flash"  # 2026-10-26 验证轮快速档
    assert config.agent_fallback_model() == "deepseek-v4-flash"
    assert config.global_fallback_model() == "deepseek-v4-pro"
    assert model_config._resolve("report_ver")[1] == "任务默认"
    assert model_config._resolve("sql")[1] == "系统默认"


def test_resolve_store_overrides_special_default(monkeypatch, tmp_path):
    good = config.available_models()[-1]
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    model_config.write_model_config({"report_ver": good, "fallback": good, "agent_fallback": good})
    assert config.task_model("report_ver") == good
    assert config.agent_fallback_model() == good
    assert config.global_fallback_model() == good


def test_effective_models_covers_all_slots():
    slots = model_config.effective_models()
    keys = [s["key"] for s in slots]
    assert keys == ["chat", "agent", "agent_fallback", "sql", "kb", "skill", "model",
                    "report_gen", "report_ver", "report_sum", "gap", "split", "fallback"]
    for s in slots:
        assert s["model"] and s["source"] in ("模型管理", "环境变量", "任务默认", "系统默认")


def test_effective_models_auto_model_field(monkeypatch, tmp_path):
    """auto_model = 忽略 store 覆盖后的自动档：有覆盖时展示「清除后回落值」，无覆盖时与生效模型一致。"""
    good = config.available_models()[-1]
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    model_config.write_model_config({"sql": good})
    by_key = {s["key"]: s for s in model_config.effective_models()}
    assert by_key["sql"]["model"] == good
    assert by_key["sql"]["source"] == "模型管理"
    assert by_key["sql"]["auto_model"] == config.default_model()  # sql 无任务默认 → 回落系统默认
    assert by_key["report_ver"]["auto_model"] == "deepseek-v4-flash"  # 任务默认快速档
    for s in by_key.values():
        if s["override"] is None:
            assert s["model"] == s["auto_model"]


# ---- report_config 适配器 ----

def test_report_config_adapter_reads_store(monkeypatch, tmp_path):
    good = config.available_models()[-1]
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    model_config.write_model_config({"report_gen": good, "report_sum": good})
    d = report_config.read_report_config()
    assert d == {"model_gen": good, "model_ver": "deepseek-v4-flash", "model_sum": good}


def test_report_config_adapter_writes_store(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", tmp_path / "model_config.json")
    good = config.available_models()[-1]
    report_config.write_report_config({"model_gen": good, "model_ver": good, "model_sum": good})
    stored = model_config.read_model_config()
    assert stored == {"report_gen": good, "report_ver": good, "report_sum": good}


# ---- ai_client 兜底模型同步 ----

def test_fallback_model_setter():
    from analysis import ai_client
    try:
        ai_client.set_fallback_model("deepseek-v4-flash")
        assert ai_client.fallback_model() == "deepseek-v4-flash"
        ai_client.set_fallback_model(None)
        assert ai_client.fallback_model() == ai_client._FALLBACK_MODEL
    finally:
        ai_client.set_fallback_model(None)


# ---- 端点 ----

def _admin_headers(seeded):
    from backend.ide_app.core.auth import create_token
    access, _, _ = create_token(seeded["admin"]["id"])
    return {"Authorization": f"Bearer {access}"}


def _alice_headers(seeded):
    from backend.ide_app.core.auth import create_token
    access, _, _ = create_token(seeded["alice"]["id"])
    return {"Authorization": f"Bearer {access}"}


def test_get_model_config_endpoint(client, seeded):
    r = client.get("/api/admin/config/models", headers=_admin_headers(seeded))
    assert r.status_code == 200
    body = r.json()
    assert len(body["slots"]) == 13
    assert set(body["models"]) == set(config.available_models())
    assert body["default"] == config.default_model()


def test_put_model_config_requires_system(client, seeded):
    r = client.put("/api/admin/config/models",
                   json={"overrides": {"sql": config.available_models()[-1]}},
                   headers=_alice_headers(seeded))
    assert r.status_code == 403


def test_put_model_config_roundtrip_and_fallback_sync(client, seeded):
    from analysis import ai_client
    good = config.available_models()[-1]
    try:
        r = client.put("/api/admin/config/models",
                       json={"overrides": {"report_ver": good, "fallback": good, "bad_key": good}},
                       headers=_admin_headers(seeded))
        assert r.status_code == 200
        slots = {s["key"]: s for s in r.json()["slots"]}
        assert slots["report_ver"]["model"] == good
        assert slots["report_ver"]["source"] == "模型管理"
        assert slots["report_ver"]["override"] == good
        assert "bad_key" not in r.json()["stored"]
        # 全局兜底模型即时同步到 ai_client
        assert ai_client.fallback_model() == good
        assert config.global_fallback_model() == good
        # 清除覆盖 → 回落任务默认（report_ver=flash；fallback=pro）
        r2 = client.put("/api/admin/config/models",
                        json={"overrides": {"report_ver": "", "fallback": ""}},
                        headers=_admin_headers(seeded))
        assert r2.status_code == 200
        slots2 = {s["key"]: s for s in r2.json()["slots"]}
        assert slots2["report_ver"]["model"] == "deepseek-v4-flash"
        assert slots2["report_ver"]["source"] == "任务默认"
        assert slots2["fallback"]["model"] == "deepseek-v4-pro"
        assert ai_client.fallback_model() == "deepseek-v4-pro"
    finally:
        ai_client.set_fallback_model(None)


def test_task_model_consults_store_from_endpoint_write(client, seeded):
    from analysis import ai_client
    good = config.available_models()[-1]
    try:
        r = client.put("/api/admin/config/models", json={"overrides": {"sql": good}},
                       headers=_admin_headers(seeded))
        assert r.status_code == 200
        assert config.task_model("sql") == good
        # 清理：清回默认，防影响同进程其它用例（兜底模型同步也一并还原）
        client.put("/api/admin/config/models", json={"overrides": {"sql": ""}},
                   headers=_admin_headers(seeded))
        assert config.task_model("sql") == config.default_model()
    finally:
        ai_client.set_fallback_model(None)


def test_put_empty_overrides_still_migrates_legacy(client, seeded):
    """PUT 空覆盖（写空不建文件）不得吞掉老 report_config.json 的一次性迁移（对抗审查）。"""
    good = config.available_models()[-1]
    config.REPORT_CONFIG_PATH.write_text(json.dumps({"model_gen": good}), encoding="utf-8")
    r = client.put("/api/admin/config/models", json={"overrides": {}},
                   headers=_admin_headers(seeded))
    assert r.status_code == 200
    assert model_config.read_model_config() == {"report_gen": good}
