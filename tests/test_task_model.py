"""P1-4：任务→模型单一入口——resolve_model_for_task 优先级 + config.task_model 映射 + 报告三模型缺省。"""
import json

from backend import config
from backend.ide_app.services.db_service import _conn, save_agent_config
from backend.services.llm import resolve_model_for_task


def _user_row(uid) -> dict:
    """从库中取完整用户行（含 identity/extra_permissions），等价 get_current_user 的返回。"""
    if isinstance(uid, dict):
        uid = uid["id"]
    return dict(_conn().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone())


def test_task_model_default_is_default_model(monkeypatch):
    monkeypatch.delenv("TASK_MODEL_SQL", raising=False)
    assert config.task_model("sql") == config.default_model()


def test_task_model_env_override(monkeypatch):
    monkeypatch.setenv("TASK_MODEL_SQL", "deepseek-v4-flash")
    assert config.task_model("sql") == "deepseek-v4-flash"


def test_task_model_agent_split_keep_legacy_constants():
    # agent/split 沿用既有 AGENT_MODEL/SPLIT_MODEL 常量（保持单点，见 config.py 注释）
    assert config.task_model("agent") == config.AGENT_MODEL
    assert config.task_model("split") == config.SPLIT_MODEL


def test_explicit_model_in_list_wins(seeded):
    admin = _user_row(seeded["admin"])
    # 优先级 1：显式传参在可用模型列表内 → 直接采用（生成任务也不拦）
    m = resolve_model_for_task("skill", admin, config.available_models()[0])
    assert m == config.available_models()[0]


def test_explicit_model_not_in_list_filtered(seeded):
    admin = _user_row(seeded["admin"])
    # 前端可能回传已被网关拒的旧模型名：不在列表内 → 过滤，回落任务默认
    m = resolve_model_for_task("skill", admin, "claude-this-model-does-not-exist")
    assert m == config.task_model("skill")


def test_generation_task_ignores_per_user_model(seeded):
    # 生成任务（skill 等）是系统级选型：即使个人配了模型也不覆盖
    alice = _user_row(seeded["alice"])
    save_agent_config(
        seeded["alice"]["id"],
        {"api_key": "sk-test", "api_base": "", "model": config.available_models()[-1]},
    )
    m = resolve_model_for_task("skill", _user_row(seeded["alice"]), None)
    assert m == config.task_model("skill")


def test_chat_task_allows_per_user_model(seeded):
    # 仅 chat/agent 对话类任务允许 per-user 覆盖（llm.py 模块 docstring 规则）
    chosen = config.available_models()[-1]
    save_agent_config(
        seeded["alice"]["id"],
        {"api_key": "sk-test", "api_base": "", "model": chosen},
    )
    m = resolve_model_for_task("chat", _user_row(seeded["alice"]), None)
    assert m == chosen


def test_report_config_read_follows_task_map(monkeypatch, tmp_path):
    # 无覆盖时：报告三模型 = 任务解析值（模型管理 > 环境变量 > 任务默认 > 系统默认）
    for k in ("TASK_MODEL_REPORT_GEN", "TASK_MODEL_REPORT_VER", "TASK_MODEL_REPORT_SUM"):
        monkeypatch.delenv(k, raising=False)
    from backend.services import report_config

    d = report_config.read_report_config()
    assert set(d.keys()) == {"model_gen", "model_ver", "model_sum"}
    assert d["model_gen"] == config.task_model("report_gen")
    assert d["model_ver"] == config.task_model("report_ver")
    assert d["model_sum"] == config.task_model("report_sum")
    # store 覆盖 → 传播到三模型读口（改 model_ver 槽位即改验证轮）
    good = config.available_models()[-1]
    p = tmp_path / "model_config.json"
    p.write_text(json.dumps({"report_ver": good}), encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    d2 = report_config.read_report_config()
    assert d2["model_ver"] == good
    assert d2["model_gen"] == config.task_model("report_gen")


def test_report_ver_default_is_fast_model(monkeypatch):
    # 2026-10-26：验证轮默认快速档 deepseek-v4-flash（用户要求保速度；
    # deepseek-v4-pro 验证轮多次 300s 读超时）
    monkeypatch.delenv("TASK_MODEL_REPORT_VER", raising=False)
    assert config.task_model("report_ver") == "deepseek-v4-flash"


def test_report_config_ignores_garbage_model_names(monkeypatch, tmp_path):
    # 回归：store 曾被写入占位模型 x/y/z——网关不认识会挂起 ~290s 逼近 300s
    # 读超时，跑专项报告直接断掉。读时校验可用列表，非法名必须回落任务解析默认。
    from backend.services import report_config

    p = tmp_path / "model_config.json"
    p.write_text('{"report_gen": "x", "report_ver": "y", "report_sum": "z"}', encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    d = report_config.read_report_config()
    assert d["model_gen"] == config.task_model("report_gen")
    assert d["model_ver"] == config.task_model("report_ver")
    assert d["model_sum"] == config.task_model("report_sum")


def test_report_config_keeps_valid_model_names(monkeypatch, tmp_path):
    # 合法模型名照常生效（校验只拦占位/已下线，不误伤正常配置）
    from backend.services import report_config

    good = config.available_models()[-1]
    p = tmp_path / "model_config.json"
    p.write_text(json.dumps({"report_gen": good, "report_ver": good, "report_sum": good}), encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    d = report_config.read_report_config()
    assert d["model_gen"] == good
    assert d["model_ver"] == good
    assert d["model_sum"] == good


def test_report_config_write_ignores_garbage_model_names(monkeypatch, tmp_path):
    # 回归：写侧第二道防线——write_report_config 也要把占位/已下线模型名拦下，否则 PUT
    # 会再次把 x/y/z 落盘（read 端兜底之外仍需写端拦截）。新口径：非法名不落盘、直接忽略；
    # 全非法时为空写，按 store 契约不创建文件（2026-10-26 加固批：空写不落盘）。
    from backend.services import report_config

    p = tmp_path / "model_config.json"
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    report_config.write_report_config({"model_gen": "x", "model_ver": "y", "model_sum": "z"})
    assert not p.exists()
    d = report_config.read_report_config()
    assert d["model_gen"] == config.task_model("report_gen")
    assert d["model_ver"] == config.task_model("report_ver")
    assert d["model_sum"] == config.task_model("report_sum")
    # 半合法：仅合法名落盘，非法名忽略
    good = config.available_models()[-1]
    report_config.write_report_config({"model_gen": "x", "model_ver": good, "model_sum": "z"})
    written = json.loads(p.read_text(encoding="utf-8"))
    assert written == {"report_ver": good}


def test_report_config_non_dict_json_does_not_crash(monkeypatch, tmp_path):
    # 回归：合法 JSON 但顶层非对象（被写成 "[]" / "x"）时，read 不应抛 AttributeError
    # 穿透（此前 data.get 在 try/except 之外），而应回落任务解析默认。
    from backend.services import report_config

    p = tmp_path / "model_config.json"
    p.write_text("[]", encoding="utf-8")
    monkeypatch.setattr(config, "MODEL_CONFIG_PATH", p)
    d = report_config.read_report_config()
    assert d["model_gen"] == config.task_model("report_gen")
    assert d["model_ver"] == config.task_model("report_ver")
    assert d["model_sum"] == config.task_model("report_sum")


def test_chat_request_model_field_optional():
    # 回归 bug：2026-10-26 前端改为「仅显式改选模型才回传 model」（state.modelExplicit），
    # 但后端 ChatRequest/SuggestReq/SuggestMergeReq 的 model 仍是必填 → 未改选时 POST /api/chat
    # 直接 422 {"loc":["body","model"],"msg":"Field required"}。这里断言 Pydantic 接受缺省字段。
    from backend.routers.chat import ChatRequest, SuggestReq, SuggestMergeReq

    assert ChatRequest(message="你好", mode="auto").model == ""
    assert SuggestReq(skill=None).model == ""
    assert SuggestMergeReq(kind="docs").model == ""


def test_resolve_model_empty_explicit_equals_none(seeded):
    # 空串显式 = 未显式：chat 任务回落 per-user → 任务默认，而非把空串当模型名去匹配
    # （匹配不到会再走同一回落路径，结果一致，但显式断言语义更直白）。
    admin = _user_row(seeded["admin"])
    assert resolve_model_for_task("chat", admin, "") == resolve_model_for_task("chat", admin, None)


def test_chat_front_gate_errors_for_no_llm_user(seeded):
    # 回归 bug 3：非管理员未配个人 Key 时，对话进入 AI 管线前先报 LLM 配置错误，
    # 不再先弹「未命中既有工件」确认卡、确认后才报无 LLM。此处直接驱动 _handle 生成器，
    # 断言事件序列为 [stage start, error]，即没走到检索/确认卡流程。
    from backend.routers.chat import _handle, ChatRequest

    alice = _user_row(seeded["alice"])
    req = ChatRequest(model=config.available_models()[0], message="查一下最近7天流水达成")
    events = list(_handle(req, {"key": "kof"}, alice))
    types = [json.loads(e[len("data: "):].strip())["type"] for e in events]
    assert types == ["stage", "error"]
    msg = json.loads(events[-1][len("data: "):].strip())["message"]
    assert "LLM" in msg or "API Key" in msg

