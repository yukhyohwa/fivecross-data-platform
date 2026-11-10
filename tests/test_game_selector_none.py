"""「不选游戏」模式（X-Game: __any__ 哨兵）回归测试（2026-10-24 游戏选择器改造）。

覆盖：
1. deps.get_game：哨兵在聊天路由返回 None；非聊天路由回落允许集首项；零权限 403 新文案；空值守卫。
2. chat._sentinel_bind：全部绑定分支（target_games 优先级/点名/家族展开预选/会话延续/专项绑定/自动绑/ask）。
3. agent_deep.sentinel_bind_games：家族主键展开 + games_req/session_games/恰一款自动绑/ask。
4. agent_tools.query_database：多库拼接（插地区列、单库失败跳过、len==1 不插伪地区列）+ export 清单。
5. 端点级：聊天哨兵 ask 短流（game_select 事件）；深度哨兵 ask 短流（game_select+question+final）；
   哨兵+零权限 → 403 新文案；export-csv 越权 db → 403 / 缺 db → 400；suggest-merge 哨兵缺游戏 → 400。
"""
import types

import pandas as pd
import pytest
from fastapi import Request
from fastapi.exceptions import HTTPException

from backend.ide_app.services import db_service
from backend.routers.chat import ChatRequest, _sentinel_bind
from backend.services import games as games_svc


def _game(key):
    return games_svc.resolve(key)


def _limited_user():
    """games 仅 rooc_am 的受限用户 dict（id 非空 → 非 anonymous）。"""
    db_service.upsert_identity(
        key="limited_rooc", name="限ROOC",
        permission_points=["apps", "analysis", "ai"], games=["rooc_am"], is_builtin=0,
    )
    return {"id": "u-limited", "identity": "limited_rooc"}


def _zero_user():
    """零游戏权限用户 dict。"""
    db_service.upsert_identity(
        key="zero_perm", name="零权限",
        permission_points=["apps"], games=[], is_builtin=0,
    )
    return {"id": "u-zero", "identity": "zero_perm"}


_ANON = {"username": "anonymous", "authenticated": False, "id": None}  # effective_games → ["*"]


def _make_request(path, headers=None):
    """构造带 route.path 的 Request（get_game 用 scope["route"].path 判聊天哨兵路由）。"""
    scope = {
        "type": "http", "method": "POST", "path": path, "query_string": b"",
        "headers": [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()],
        "route": types.SimpleNamespace(path=path),
    }
    return Request(scope)


# ---- 1. deps.get_game ----

@pytest.fixture()
def _get_game(monkeypatch):
    from backend import deps
    def run(path, user, x_game=None):
        monkeypatch.setattr(deps, "get_current_user", lambda request: user)
        req = _make_request(path, {"X-Game": x_game} if x_game is not None else {})
        return deps.get_game(req)
    return run


def test_sentinel_chat_route_returns_none(app_env, _get_game):
    assert _get_game("/api/chat", _ANON, "__any__") is None


def test_sentinel_deep_route_returns_none(app_env, _get_game):
    assert _get_game("/api/agent/chat/stream", _ANON, "__any__") is None


def test_sentinel_non_chat_route_falls_back(app_env, _get_game):
    g = _get_game("/api/chat-history", _ANON, "__any__")  # 非聊天路由：回落允许集首项
    assert g is not None and g["key"] == games_svc.default_key()


def test_zero_permission_sentinel_403(app_env, _get_game):
    with pytest.raises(HTTPException) as ei:
        _get_game("/api/chat", _zero_user(), "__any__")
    assert ei.value.status_code == 403
    assert "您没有任何游戏的数据权限" in str(ei.value.detail)


def test_zero_permission_normal_key_403(app_env, _get_game):
    with pytest.raises(HTTPException) as ei:
        _get_game("/api/chat", _zero_user(), "rooc_am")
    assert ei.value.status_code == 403
    assert "您没有任何游戏的数据权限" in str(ei.value.detail)


def test_no_game_header_falls_back_no_crash(app_env, _get_game):
    g = _get_game("/api/chat", _ANON, None)
    assert g is not None and g["key"] == games_svc.default_key()


# ---- 2. chat._sentinel_bind ----

def _bind(question, user=_ANON, target_games=None, session_games=None, preset_skill=None, ai_target=None):
    req = ChatRequest(model="m", message=question, target_games=target_games, session_games=session_games)
    return _sentinel_bind(question, req, None, user, preset_skill=preset_skill, ai_target=ai_target)


def test_bind_named_region_runs_direct(app_env):
    kind, qg, g, gk, note, direct = _bind("我想要 ro_hmt 过去7天的流水")
    assert kind == "run" and [x["key"] for x in qg] == ["ro_hmt"] and gk == "ro_hmt"
    assert direct is True and "已按其查询" in note


def test_bind_named_family_expands_preselected(app_env):
    kind, opts, preselected, reason = _bind("查 rooc 的流水")
    assert kind == "ask"
    # 预选 = 家族成员∩允许集（匿名全允许）——从 family_members 动态推导，不硬编码成员清单
    fam_keys = [m["key"] for m in games_svc.family_members(_game("rooc"), None)]
    assert len(fam_keys) > 1  # 本用例前提：家族多成员才走预选 ask
    assert set(preselected) == set(fam_keys)
    assert "个地区服" in reason and "请选择要查询的游戏" in reason


def test_bind_named_denied_asks(app_env):
    kind, opts, preselected, reason = _bind("查 ro_hmt 的流水", user=_limited_user())
    assert kind == "ask" and preselected == []
    assert "暂无其数据权限" in reason
    assert all(o["key"] == "rooc_am" for o in opts)  # 选项只有有权限的游戏


def test_bind_named_family_member_only_runs_member(app_env):
    """评审 L1：点名家族主键（rooc）但仅有成员服（rooc_am）权限 → 直跑该成员服，
    不再给误导性「暂无其数据权限」卡。"""
    kind, qg, g, gk, note, direct = _bind("查 rooc 的流水", user=_limited_user())
    assert kind == "run" and [x["key"] for x in qg] == ["rooc_am"]
    # 对抗审查二轮：实际执行的是成员服（≠ 点名主键），文案必须用成员服标签而非「按其查询」
    assert direct is True and "已按" in note and games_svc.region_label(g) in note


def test_bind_named_family_no_member_denied(app_env):
    """评审 L1 反向：点名家族主键且家族成员全部无权 → 仍给无权限卡。"""
    kind, opts, preselected, reason = _bind("查 rooc 的流水", user=_zero_user())
    assert kind == "ask" and preselected == []
    assert "暂无其数据权限" in reason


def test_bind_no_name_multi_asks_all(app_env):
    kind, opts, preselected, reason = _bind("最近7天各国家流水趋势")
    assert kind == "ask" and preselected == []
    assert len(opts) == len(games_svc.get_games(None))
    assert all("label" in o and "key" in o for o in opts)


def test_bind_target_games_priority_drops_unknown(app_env):
    kind, qg, g, gk, note, direct = _bind("最近7天流水", target_games=["ro_hmt", "nope", "rooc_am"])
    assert kind == "run" and [x["key"] for x in qg] == ["ro_hmt", "rooc_am"] and gk == "ro_hmt"


def test_bind_target_games_permission_filtered(app_env):
    kind, qg, g, gk, note, direct = _bind("最近7天流水", user=_limited_user(),
                                          target_games=["ro_hmt", "rooc_am"])
    assert kind == "run" and [x["key"] for x in qg] == ["rooc_am"]


def test_bind_target_games_all_invalid_reask(app_env):
    kind, opts, preselected, reason = _bind("最近7天流水", target_games=["nope"])
    assert kind == "ask" and "所选游戏均无权限或不存在" in reason


def test_bind_target_games_beats_named(app_env):
    kind, qg, g, gk, note, direct = _bind("查 rooc_am 的流水", target_games=["ro_hmt"])
    assert kind == "run" and [x["key"] for x in qg] == ["ro_hmt"]


def test_bind_session_games_fallback(app_env):
    kind, qg, g, gk, note, direct = _bind("按国家拆分一下", session_games=["rooc_am", "kof"])
    assert kind == "run" and [x["key"] for x in qg] == ["rooc_am", "kof"]
    assert "已沿用上轮" in note


def test_bind_named_beats_session(app_env):
    kind, qg, g, gk, note, direct = _bind("查 ro_hmt 的流水", session_games=["rooc_am"])
    assert kind == "run" and [x["key"] for x in qg] == ["ro_hmt"] and direct is True


def test_bind_single_allowed_auto(app_env):
    kind, qg, g, gk, note, direct = _bind("最近7天流水", user=_limited_user())
    assert kind == "run" and [x["key"] for x in qg] == ["rooc_am"]
    assert "你仅有" in note


def test_bind_preset_skill_bound_game(app_env, monkeypatch):
    import backend.routers.chat as chat
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: {"game": "rooc_am"})
    kind, qg, g, gk, note, direct = _bind("跑一遍流水达成", preset_skill="流水达成")
    assert kind == "run" and [x["key"] for x in qg] == ["rooc_am"]
    assert "绑定游戏" in note


# ---- 3. agent_deep.sentinel_bind_games ----

def _dbind(game, games_req=None, session_games=None, user=_ANON):
    from backend.services import agent_deep
    return agent_deep.sentinel_bind_games(game, games_req, session_games, None, user)


def test_deep_bind_family_primary_ask_preselected(app_env):
    kind, opts, preselected, reason = _dbind(_game("rooc"))
    assert kind == "ask"
    # 预选 = 家族成员∩允许集（匿名全允许）——动态推导，不硬编码成员清单
    fam_keys = [m["key"] for m in games_svc.family_members(_game("rooc"), None)]
    assert len(fam_keys) > 1
    assert set(preselected) == set(fam_keys)
    assert "地区服" in reason


def test_deep_bind_family_single_member_runs(app_env):
    kind, qg, g, note = _dbind(_game("act"))  # act 家族仅 1 款
    assert kind == "run" and [x["key"] for x in qg] == ["act"]
    # 对抗审查二轮：成员服标签收口（与 chat._sentinel_bind 同口径）
    assert "已按" in note and games_svc.region_label(g) in note


def test_deep_bind_none_games_req(app_env):
    kind, qg, g, note = _dbind(None, games_req=["ro_hmt", "rooc_am"])
    assert kind == "run" and [x["key"] for x in qg] == ["ro_hmt", "rooc_am"] and g["key"] == "ro_hmt"


def test_deep_bind_none_session(app_env):
    kind, qg, g, note = _dbind(None, session_games=["kof"])
    assert kind == "run" and [x["key"] for x in qg] == ["kof"]


def test_deep_bind_none_single_allowed_auto(app_env):
    kind, qg, g, note = _dbind(None, user=_limited_user())
    assert kind == "run" and [x["key"] for x in qg] == ["rooc_am"] and "你仅有" in note


def test_deep_bind_none_ask_all(app_env):
    kind, opts, preselected, reason = _dbind(None)
    assert kind == "ask" and preselected == []
    assert len(opts) == len(games_svc.get_games(None))


def test_deep_bind_games_req_beats_family(app_env):
    """评审 H4：多选卡回传（games_req）与点名家族主键同时存在 → 显式选择优先，
    不被历史点名展开顶掉。"""
    kind, qg, g, note = _dbind(_game("rooc"), games_req=["kof", "ro_hmt"])
    assert kind == "run" and [x["key"] for x in qg] == ["kof", "ro_hmt"] and g["key"] == "kof"


# ---- 3b. resolve_cross_game family_grace（评审 M1）----

def _kof_sea_user():
    """games 仅 kof_sea（拳皇东南亚服）的受限用户 dict。"""
    db_service.upsert_identity(
        key="kofsea_only", name="仅KOF东南亚",
        permission_points=["apps", "analysis", "ai"], games=["kof_sea"], is_builtin=0,
    )
    return {"id": "u-kofsea", "identity": "kofsea_only"}


def _resolve(messages, user=_ANON, game=None, family_grace=False):
    from backend.services import agent_deep
    return agent_deep.resolve_cross_game(game, messages, user, family_grace=family_grace)


def test_resolve_family_grace_member_allowed(app_env):
    """评审 M1：哨兵模式下点名家族主键「拳皇」而仅有 kof_sea 权限 → 放行返回主键 target
    （由 sentinel_bind_games 展开成员），不再拒绝。"""
    target, switched, denied = _resolve(
        [{"role": "user", "content": "查拳皇的流水"}], user=_kof_sea_user(), family_grace=True)
    assert target is not None and target["key"] == "kof"
    assert switched is None and denied is None


def test_resolve_family_grace_off_still_denied(app_env):
    """评审 M1 反向：family_grace=False（follow 模式）保持精确 key 鉴权 → 拒绝。"""
    target, switched, denied = _resolve(
        [{"role": "user", "content": "查拳皇的流水"}], user=_kof_sea_user(), family_grace=False)
    assert denied and "暂无" in denied


def test_resolve_family_grace_no_member_denied(app_env):
    """评审 M1 边界：家族主键点名且家族成员全部无权 → grace 不生效，照常拒绝。"""
    target, switched, denied = _resolve(
        [{"role": "user", "content": "查拳皇的流水"}], user=_limited_user(), family_grace=True)
    assert denied and "暂无" in denied


def test_resolve_family_grace_region_still_denied(app_env):
    """评审 M1 边界：点名具体地区服（非家族主键）→ grace 不生效（精确鉴权）。"""
    target, switched, denied = _resolve(
        [{"role": "user", "content": "查 ro_hmt 的流水"}], user=_limited_user(), family_grace=True)
    assert denied and "暂无" in denied


def test_resolve_family_grace_not_remembered_as_denied(app_env):
    """对抗审查三轮（F8 重写）：grace 放行不记拒绝记忆。旧版单条消息历史恒 scanned==1、
    _was_denied 从不被咨询（agent_deep.py「if scanned > 1 and _was_denied」），把
    grace 分支误加 _remember_denied 的回归也测不出（空转）。这里用两条消息历史让点名
    落在 scanned==2：第一轮若误记拒绝记忆，第二轮扫描会跳过该点名 → 返回
    (None, None, None)，断言即失败。uid 用独立值，避免与
    test_resolve_family_grace_off_still_denied 写入的 _denied_texts 全局记忆串扰。"""
    from backend.services import agent_deep
    db_service.upsert_identity(
        key="kofsea_grace_only", name="仅KOF东南亚·grace测试",
        permission_points=["apps", "analysis", "ai"], games=["kof_sea"], is_builtin=0,
    )
    user = {"id": "u-grace-norem", "identity": "kofsea_grace_only"}
    msgs = [
        {"role": "user", "content": "查拳皇的流水"},
        {"role": "user", "content": "上个月呢"},
    ]
    t1, s1, d1 = _resolve(msgs, user=user, family_grace=True)
    assert t1 is not None and t1["key"] == "kof" and d1 is None
    t2, s2, d2 = _resolve(msgs, user=user, family_grace=True)
    assert t2 is not None and t2["key"] == "kof" and d2 is None
    # 直接钉死不变量：grace 放行路径不得产生拒绝记忆（记了 600s 内后续追问会断绑家族上下文）
    assert agent_deep._was_denied("u-grace-norem", "查拳皇的流水") is False


# ---- 4. agent_tools.query_database 多库拼接 ----

def _qctx(games):
    from backend.services import agent_tools
    ctx = {"engine": None, "game": games[0]}
    if games:
        ctx["games"] = games
    return ctx


def _qrun(games, results, monkeypatch):
    """results: {key: pd.DataFrame 或 Exception}。"""
    from backend.services import agent_tools
    def fake_run(engine, sql, max_rows=200, max_scanned=0):
        # sql 已 apply_db：取 sql 里第一个 pf_xxx. 前缀反查 key
        import re as _re
        m = _re.search(r"pf_([a-z0-9_]+)\.", sql)
        assert m, f"apply_sql 未替换库前缀：{sql}"
        key = m.group(1)
        r = results.get(key)
        if isinstance(r, Exception):
            raise r
        return r
    monkeypatch.setattr(agent_tools, "run_raw_sql", fake_run)
    return agent_tools.query_database(_qctx(games), "SELECT * FROM pf_rooc_am.t LIMIT 5")


def test_query_database_multi_concat_region(app_env, monkeypatch):
    g1, g2 = _game("rooc_am"), _game("kof")
    out = _qrun([g1, g2], {"rooc_am": pd.DataFrame({"流水": [1, 2]}), "kof": pd.DataFrame({"流水": [3]})}, monkeypatch)
    cols = out["result"]["columns"]
    rows = out["result"]["rows"]
    assert cols[0] == "地区"
    # 均衡预览（评审 M3）：按「地区」分组轮流取样，前两行两库各占一行（不再是首库先占满）
    assert [r[0] for r in rows] == [games_svc.region_label(g1), games_svc.region_label(g2), games_svc.region_label(g1)]
    # export 清单：逐库 SQL（已 apply）+ db + label，与成功库顺序一致
    exps = out["export"]
    assert [e["db"] for e in exps] == [g1["db"], g2["db"]]
    assert all("pf_" + g["key"] + "." in e["sql"] for e, g in zip(exps, [g1, g2]))


def test_query_database_region_rename(app_env, monkeypatch):
    g1 = _game("rooc_am")
    out = _qrun([g1, _game("kof")],
                {"rooc_am": pd.DataFrame({"地区": ["am"], "流水": [1]}), "kof": pd.DataFrame({"地区": ["sea"], "流水": [2]})},
                monkeypatch)
    cols = out["result"]["columns"]
    assert "地区(原)" in cols and cols[0] == "地区"


def test_query_database_single_game_failure_skipped(app_env, monkeypatch):
    g1, g2 = _game("rooc_am"), _game("kof")
    out = _qrun([g1, g2], {"rooc_am": pd.DataFrame({"流水": [1]}), "kof": RuntimeError("boom")}, monkeypatch)
    assert len(out["result"]["rows"]) == 1
    assert len(out["export"]) == 1 and out["export"][0]["db"] == g1["db"]


def test_query_database_all_fail_reraises(app_env, monkeypatch):
    with pytest.raises(RuntimeError):
        _qrun([_game("rooc_am"), _game("kof")], {"rooc_am": RuntimeError("b1"), "kof": RuntimeError("b2")}, monkeypatch)


def test_query_database_len1_no_region_no_export(app_env, monkeypatch):
    g1 = _game("rooc_am")
    out = _qrun([g1], {"rooc_am": pd.DataFrame({"流水": [1]})}, monkeypatch)
    assert "地区" not in out["result"]["columns"]
    assert "export" not in out  # 单游戏响应保持原状（回归安全）


def test_query_database_partial_fail_reports_failed(app_env, monkeypatch):
    """评审 M2：部分库失败时 failed_games 标注失败库，games 只含成功库。"""
    g1, g2 = _game("rooc_am"), _game("kof")
    out = _qrun([g1, g2], {"rooc_am": pd.DataFrame({"流水": [1]}), "kof": RuntimeError("boom")}, monkeypatch)
    assert out["result"]["failed_games"] == ["kof"]
    assert [g["key"] for g in out["result"]["games"]] == ["rooc_am"]


def test_query_database_all_fail_retry_success(app_env, monkeypatch):
    """评审 L2：全部库失败但主库重跑成功 → 用重跑结果按单库口径返回（不抛 concat 空列表异常）。"""
    from backend.services import agent_tools
    calls = []
    def flaky(engine, sql, max_rows=200, max_scanned=0):
        calls.append(sql)
        if len(calls) <= 2:  # 首轮两库都失败；主库重跑（第 3 次）成功
            raise RuntimeError("boom")
        return pd.DataFrame({"流水": [42]})
    monkeypatch.setattr(agent_tools, "run_raw_sql", flaky)
    out = agent_tools.query_database(_qctx([_game("rooc_am"), _game("kof")]), "SELECT * FROM pf_rooc_am.t")
    assert out["result"]["rows"][0][0] == 42
    assert out["result"]["failed_games"] == ["kof"]
    assert [g["key"] for g in out["result"]["games"]] == ["rooc_am"]
    assert "export" not in out  # 重跑成功按单库口径：不再有逐库导出清单
    assert "地区" not in out["result"]["columns"]


def test_query_database_envelope_balanced_sample(app_env, monkeypatch):
    """评审 M3（信封模式）：样本行按「地区」均衡取样——预算内两库行都可见。"""
    from backend.services import agent_tools
    from backend.services.session_store import ResultStore
    g1, g2 = _game("rooc_am"), _game("kof")
    store = ResultStore(capacity=4)
    def fake_run(engine, sql, max_rows=200, max_scanned=0):
        import re as _re
        m = _re.search(r"pf_([a-z0-9_]+)\.", sql)
        key = m.group(1)
        return pd.DataFrame({"流水": [1, 2, 3, 4, 5]}) if key == "rooc_am" else pd.DataFrame({"流水": [9]})
    monkeypatch.setattr(agent_tools, "run_raw_sql", fake_run)
    ctx = _qctx([g1, g2])
    ctx["result_store"] = store
    out = agent_tools.query_database(ctx, "SELECT * FROM pf_rooc_am.t")
    labels = [r[0] for r in out["result"]["rows"]]
    # 样本前两行两库各占一行（均衡取样），而非首库先占满
    assert labels[0] == games_svc.region_label(g1) and labels[1] == games_svc.region_label(g2)
    assert [g["key"] for g in out["result"]["games"]] == ["rooc_am", "kof"]
    assert "failed_games" not in out["result"]  # 全成功时不带 failed_games


def test_query_database_envelope_floor_covers_all_games(app_env, monkeypatch):
    """对抗审查二轮：多库信封样本的浓缩下限随成功库数抬升（floor=成功库数，封顶 8）——
    4 库各 5 行长值、预算不足时样本仍保留 4 行（每库至少 1 行）；此前默认 floor=3
    会把第 4 库整体挤出样本，模型看不到该库数据特征。"""
    from backend.services import agent_tools
    from backend.services.session_store import ResultStore
    games4 = [_game(k) for k in ("rooc_am", "kof", "kof_sea", "ro_hmt")]
    def fake_run(engine, sql, max_rows=200, max_scanned=0):
        return pd.DataFrame({"流水": ["x" * 240] * 5})
    monkeypatch.setattr(agent_tools, "run_raw_sql", fake_run)
    # 预算压到最小值（1200）：4 行装得下、5 行装不下——旧 floor=3 会停到 3 行，新 floor=4 保 4 行。
    # 上限用 2600 而非 100：三轮 F7 信封头部有固定开销（result_id/columns/readback ≈250 字符），
    # 100 装不下任何一行会让缩行循环跌破 floor；2600 > 信封 ≈1290 → 不触发 F7 截断，语义不变。
    monkeypatch.setattr(agent_tools, "settings", types.SimpleNamespace(AGENT_TOOL_RESULT_MAX_CHARS=2600))
    store = ResultStore(capacity=4)
    ctx = _qctx(games4)
    ctx["result_store"] = store
    out = agent_tools.query_database(ctx, "SELECT * FROM pf_rooc_am.t")
    labels = [r[0] for r in out["result"]["rows"]]
    assert len(labels) >= 4
    assert len(set(labels)) == 4  # 4 个成功库的样本行一个不少


# ---- 5. 端点级 ----

def _login_token(client, username, password):
    return client.post("/api/auth/login", json={"username": username, "password": password}).json()["access_token"]


def _sse_events(text):
    return [line[6:] for line in text.splitlines() if line.startswith("data: ")]


def test_chat_sentinel_ask_card_stream(client, app_env, monkeypatch):
    """哨兵 + 无点名（auto 模式）→ 发 game_select 多选卡 + 待选择 stage，不发 SQL/answer。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    monkeypatch.setattr(chat, "ensure_llm_ready", lambda user: {})
    monkeypatch.setattr(chat.conversation, "decide", lambda *a, **k: {"intent": "query", "refined_question": "最近7天各国家流水趋势"})

    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat", json={
        "model": "fake-model", "message": "最近7天各国家流水趋势", "mode": "auto",
        "preset_skill": None, "chart_type": "auto", "docs": [], "context_report": None,
        "history": [], "confirm": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    import json
    events = [json.loads(e) for e in _sse_events(r.text)]
    types = [e["type"] for e in events]
    assert "game_select" in types
    gs = next(e for e in events if e["type"] == "game_select")
    assert len(gs["games"]) == len(games_svc.get_games(None))  # admin 全游戏 → 全部选项
    assert gs["preselected"] == []
    assert any(e["type"] == "stage" and "待选择分析游戏" in e.get("message", "") for e in events)
    assert "sql" not in types and "answer" not in types
    assert "done" in types  # 流正常收口


def test_chat_no_model_field_not_422(client, app_env, monkeypatch):
    """回归 bug：2026-10-26 前端改为「仅显式改选模型才回传 model」（state.modelExplicit），
    但后端 ChatRequest.model 仍是必填 → POST /api/chat 不带 model 直接 422
    {"loc":["body","model"],"msg":"Field required"}。修复后应穿过校验，按主对话槽位解析。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    monkeypatch.setattr(chat, "ensure_llm_ready", lambda user: {})
    monkeypatch.setattr(chat.conversation, "decide", lambda *a, **k: {"intent": "query", "refined_question": "最近7天各国家流水趋势"})

    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat", json={
        "message": "最近7天各国家流水趋势", "mode": "auto",
        "preset_skill": None, "chart_type": "auto", "docs": [], "context_report": None,
        "history": [], "confirm": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code != 422
    assert r.status_code == 200


def test_chat_forecast_history_injected_game_asks_confirm(client, app_env, monkeypatch):
    """回归 2026-10-28：右上角选中 rooc_am、当前消息未点名、但历史提过拳皇 → decide 把「拳皇」
    补全进精化问题。预测（model 意图）不得静默切到拳皇，应先弹 game_confirm 卡（source=model），
    确认前不得进入预测流程（无 meta source=model）。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    monkeypatch.setattr(chat, "ensure_llm_ready", lambda user: {})
    monkeypatch.setattr(chat.conversation, "decide", lambda *a, **k: {
        "intent": "model",
        "refined_question": "预测拳皇未来10天的流水金额",  # 历史补全带出的游戏
        "target_game": "kof",
    })

    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat", json={
        "model": "fake-model", "message": "帮我预测一下未来10天的流水金额", "mode": "auto",
        "preset_skill": None, "chart_type": "auto", "docs": [], "context_report": None,
        "history": [], "confirm": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 200
    import json
    events = [json.loads(e) for e in _sse_events(r.text)]
    types = [e["type"] for e in events]
    assert "game_confirm" in types
    gc = next(e for e in events if e["type"] == "game_confirm")
    assert gc["source"] == "model"
    assert gc["target_game"] == "kof"
    assert gc["current"]["key"] == "rooc_am"
    # 确认前不得进入预测流程（无 meta source=model）
    assert not any(e["type"] == "meta" and e.get("source") == "model" for e in events)
    assert "done" in types  # 流正常收口


def test_chat_forecast_game_confirm_ok_routes_to_model(client, app_env, monkeypatch):
    """用户确认「按解析项目」(game_confirm=ok, game_confirm_source=model) → 路由回预测流程
    （匹配预测能力 stage），而非 query 的专项检索；match_model 未命中时收口为「没有找到」answer。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    monkeypatch.setattr(chat, "ensure_llm_ready", lambda user: {})
    monkeypatch.setattr(chat.model_run, "match_model", lambda *a, **k: None)

    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat", json={
        "model": "fake-model", "message": "预测拳皇未来10天的流水金额", "mode": "auto",
        "preset_skill": None, "chart_type": "auto", "docs": [], "context_report": None,
        "history": [], "confirm": None,
        "game_confirm": "ok", "game_confirm_source": "model", "target_game": "kof",
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 200
    import json
    events = [json.loads(e) for e in _sse_events(r.text)]
    types = [e["type"] for e in events]
    messages = [e.get("message", "") for e in events if e["type"] == "stage"]
    assert any("匹配预测能力" in m for m in messages)
    assert not any("检索匹配专项" in m for m in messages)
    assert any(e["type"] == "answer" and "没有找到" in e.get("markdown", "") for e in events)
    assert "done" in types


def test_chat_sentinel_zero_permission_403(client, app_env):
    from backend.ide_app.core.auth import hash_password
    _zero_user()
    db_service.create_user("zed", hash_password("zed12345"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='zero_perm' WHERE username='zed'")
    c.commit()
    token = _login_token(client, "zed", "zed12345")
    r = client.post("/api/chat", json={
        "model": "m", "message": "最近7天流水", "mode": "auto", "preset_skill": None,
        "chart_type": "auto", "docs": [], "context_report": None, "history": [], "confirm": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 403
    assert "您没有任何游戏的数据权限" in r.text


def test_deep_sentinel_ask_short_stream(client, app_env):
    """深度分析哨兵 + 无点名 → game_select + question（无 options）+ final 短流（绑定先于 LLM 闸门，免 mock）。"""
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/agent/chat/stream", json={
        "message": "最近7天各国家流水趋势", "history": [],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    import json
    events = [json.loads(e) for e in _sse_events(r.text)]
    types = [e["type"] for e in events]
    assert types[:3] == ["game_select", "question", "final"]
    q = events[1]
    assert q["options"] == []
    f = events[2]
    assert f["success"] is True and f["status"] == "success" and f["status_text"] == "待选择"
    assert f["rounds"] == 0 and f["sqls"] == []
    # 对抗审查二轮：final reply 带编号选项行（与 ask_user 同协议），
    # 前端把「我选择第 N 项游戏」入库后，历史里的编号选项供模型对照还原所选
    assert "1." in f["reply"] and "2." in f["reply"]


def test_deep_sentinel_zero_permission_403(client, app_env):
    from backend.ide_app.core.auth import hash_password
    _zero_user()
    db_service.create_user("zed2", hash_password("zed12345"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='zero_perm' WHERE username='zed2'")
    c.commit()
    token = _login_token(client, "zed2", "zed12345")
    r = client.post("/api/agent/chat/stream", json={
        "message": "最近7天流水", "history": [],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 403
    assert "您没有任何游戏的数据权限" in r.text


def test_export_csv_sqls_unauthorized_db_403(client, app_env):
    """export-csv 的 db 字段客户端可控 → 越权库 403（防跨游戏外泄）；权限闸门在取数之前。"""
    from backend.ide_app.core.auth import hash_password
    _limited_user()
    db_service.create_user("carol", hash_password("carol12345"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='limited_rooc' WHERE username='carol'")
    c.commit()
    token = _login_token(client, "carol", "carol12345")
    r = client.post("/api/chat/export-csv", json={
        "sql": "", "name": "x", "sqls": [
            {"sql": "SELECT 1", "db": "pf_ro_hmt", "label": "hmt"},
            {"sql": "SELECT 1", "db": "pf_rooc_am", "label": "am"},
        ],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 403
    assert "无此游戏权限" in r.text


def test_export_csv_sentinel_no_db_400(client, app_env):
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/export-csv", json={"sql": "SELECT 1", "name": "x"},
                    headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 400
    assert "未指定游戏库" in r.text


def test_export_csv_valid_sqls_concats(app_env, client, monkeypatch):
    """多游戏导出：逐库执行拼「地区」列（run_raw_sql mock，不触真实库）。"""
    import backend.routers.chat as chat
    def fake_run(engine, sql, max_rows=200000):
        db = "pf_ro_hmt" if "pf_ro_hmt." in sql else "pf_rooc_am"
        return pd.DataFrame({"流水": [1] if db == "pf_ro_hmt" else [2]})
    monkeypatch.setattr(chat, "run_raw_sql", fake_run)
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/export-csv", json={
        "sql": "", "name": "multi", "sqls": [
            {"sql": "SELECT 1 FROM pf_ro_hmt.t", "db": "pf_ro_hmt", "label": "hmt"},
            {"sql": "SELECT 1 FROM pf_rooc_am.t", "db": "pf_rooc_am", "label": "am"},
        ],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    body = r.content.decode("utf-8-sig")
    assert "地区" in body and "hmt" in body and "am" in body  # 插地区列 + 两行


def test_suggest_merge_sentinel_no_games_400(client, app_env):
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/suggest-merge", json={
        "model": "m", "kind": "sql", "target": "某SQL",
        "question": "流水", "sql": "SELECT 1", "answer": "", "games": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 400
    assert "未指定游戏" in r.text


def test_suggest_sentinel_no_games_400(client, app_env):
    """评审 H2：哨兵模式无法恢复游戏 → /chat/suggest 直接 400（不再用全量资产列表兜底）。"""
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/suggest", json={
        "model": "m", "skill": None, "question": "流水", "sql": "SELECT 1",
        "answer": "", "kinds": ["sql"], "games": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 400
    assert "未指定游戏" in r.text


def test_suggest_merge_forged_games_ignored_target_unscoped_400(client, app_env, monkeypatch):
    """评审 H2/A3 + 对抗审查二轮：哨兵模式下回传无权限/伪造 games key 被过滤（games.resolve
    对未知 key 静默回落默认游戏，不能直接 resolve）；dave 恰 1 款权限游戏 → 自动绑定后按
    kind 复核 target——「某SQL」不在该游戏范围 → 400「不存在或无权访问」（此前是全允许集
    搜索未命中后报「未指定游戏」，单游戏权限用户现在功能对称地走自动绑）。
    mock resolve_model_for_task 绕开非管理员的 LLM Key 闸门（该闸门与游戏恢复无关）。"""
    import backend.routers.chat as chat
    from backend.ide_app.core.auth import hash_password
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    _limited_user()
    db_service.create_user("dave", hash_password("dave12345"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='limited_rooc' WHERE username='dave'")
    c.commit()
    token = _login_token(client, "dave", "dave12345")
    r = client.post("/api/chat/suggest-merge", json={
        "model": "fake-model", "kind": "sql", "target": "某SQL",
        "question": "流水", "sql": "SELECT 1", "answer": "",
        "games": ["kof"],  # 伪造：dave 仅有 rooc_am 权限
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 400
    assert "不存在或无权访问" in r.text


def test_suggest_merge_unscoped_target_400(client, app_env):
    """评审 A3：目标资产不在该游戏范围 → 400（防跨游戏/他人资产合并）。"""
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/suggest-merge", json={
        "model": "m", "kind": "sql", "target": "绝不存在的SQL名xyz",
        "question": "流水", "sql": "SELECT 1", "answer": "", "games": ["rooc_am"],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 400
    assert "不存在或无权访问" in r.text


def test_suggest_merge_normal_mode_unscoped_target_400(client, app_env):
    """评审 A3（follow 模式同样生效）：直接选中游戏但 target 不在该游戏范围 → 400。"""
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/suggest-merge", json={
        "model": "m", "kind": "docs", "target": "绝不存在的文档名xyz",
        "question": "流水", "sql": "SELECT 1", "answer": "", "games": None,
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 400
    assert "不存在或无权访问" in r.text


# ---- 5b. _recover_sentinel_game（对抗审查二轮修复 #4/#5）----

def _recover(user, games_req=None, kind=None, target=None, skill=None):
    from backend.routers.chat import _recover_sentinel_game
    return _recover_sentinel_game(user, games_req, kind=kind, target=target, skill=skill)


def test_recover_single_allowed_auto_bind(app_env):
    """恰 1 款有权限游戏 → 自动绑定（与聊天/深度自动绑对齐，提炼/合并功能对称）。"""
    key, db = _recover(_limited_user())
    assert key == "rooc_am" and db == _game("rooc_am")["db"]


def test_recover_games_req_priority(app_env, monkeypatch):
    """前端回传 games 内的目标资产定位优先（此前先全允许集搜索，多游戏会话会把
    allowed[0] 误当目标归属）；目标同时在回传游戏与更靠前的允许集游戏里，仍锚定回传游戏。"""
    import backend.routers.chat as chat
    others = [g["key"] for g in games_svc.get_games(None) if g["key"] != "kof"]
    monkeypatch.setattr(chat.sql_store, "list_sql_files",
                        lambda key: ["t"] if key in (others[0], "kof") else [])
    key, db = _recover(_ANON, games_req=["kof"], kind="sql", target="t")
    assert key == "kof" and db == _game("kof")["db"]


def test_recover_forged_games_ignored(app_env):
    """伪造/无权限回传 key 被过滤（games.resolve 对未知 key 静默回落默认游戏，不能直接 resolve）：
    过滤后恰 1 款权限游戏 → 自动绑该游戏，绝不落到伪造 key 上。"""
    key, db = _recover(_limited_user(), games_req=["kof"])
    assert key == "rooc_am" and db == _game("rooc_am")["db"]


# ---- 6. 对抗审查二轮新增端点回归 ----

def test_export_csv_non_string_sql_skipped(app_env, client, monkeypatch):
    """sqls 条目里 sql/db 非字符串（伪造嵌套结构）逐条跳过——此前在 .strip() 上抛
    AttributeError 变 500；合法条目照常导出，坏条目不拖垮整份多游戏导出。"""
    import backend.routers.chat as chat
    def fake_run(engine, sql, max_rows=200000):
        return pd.DataFrame({"流水": [1]})
    monkeypatch.setattr(chat, "run_raw_sql", fake_run)
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/export-csv", json={
        "sql": "", "name": "x", "sqls": [
            {"sql": {"nested": 1}, "db": "pf_ro_hmt", "label": "bad"},
            {"sql": "SELECT 1 FROM pf_ro_hmt.t", "db": "pf_ro_hmt", "label": "hmt"},
        ],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    body = r.content.decode("utf-8-sig")
    assert "hmt" in body and "bad" not in body


def test_gap_fix_cross_user_skill_403(app_env, client, monkeypatch):
    """对抗审查二轮：gap-fix 按专项名直改专项内容 → 个人级专项跨用户 403
    （此前仅要求攻击者持任一游戏权限即可读写他人个人级专项）。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    monkeypatch.setattr(chat.ks, "skill_exists", lambda name: True)
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: {
        "level": "个人", "game": "rooc_am", "owner": "victim-owner", "sqls": [], "docs": []})
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/gap-fix", json={
        "model": "fake-model", "skill": "victim-skill",
        "gap": {"issue": "x", "remedy_type": "sql"},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 403
    assert "无权" in r.text


def test_gap_whitelist_cross_user_403(app_env, client, monkeypatch):
    """对抗审查二轮：gap-whitelist 读写按专项名 → 他人个人级专项 403。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat.ks, "skill_exists", lambda name: True)
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: {
        "level": "个人", "game": "rooc_am", "owner": "victim-owner", "sqls": [], "docs": []})
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/gap-whitelist", json={
        "skill": "victim-skill", "gap": {"issue": "x"},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 403
    assert "无权" in r.text


def test_gap_whitelist_family_member_allowed(app_env, client, monkeypatch):
    """对抗审查二轮：项目级专项绑定家族主键（kof）、用户仅有成员服（kof_sea）权限 →
    白名单操作放行（与 visible_to 同族语义一致，不误伤家族内正常协作）。"""
    import backend.routers.chat as chat
    from backend.ide_app.core.auth import hash_password
    monkeypatch.setattr(chat.ks, "skill_exists", lambda name: True)
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: {
        "level": "项目级", "game": "kof", "owner": "anyone", "sqls": [], "docs": []})
    monkeypatch.setattr(chat.gap_fix, "whitelist_gap", lambda skill, gap: {"ok": True})
    _kof_sea_user()
    db_service.create_user("sea", hash_password("sea12345"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='kofsea_only' WHERE username='sea'")
    c.commit()
    token = _login_token(client, "sea", "sea12345")
    r = client.post("/api/chat/gap-whitelist", json={
        "skill": "kof-skill", "gap": {"issue": "x"},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "kof_sea"})
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_gap_whitelist_unknown_skill_404(app_env, client, monkeypatch):
    """对抗审查二轮补强：不存在的专项名此前当「通用级空元数据」放行 → gap_fix 按名写
    run.json 注册文件（versioning 留痕）产生垃圾落盘；现在 404，不落盘。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat.gap_fix, "whitelist_gap", lambda skill, gap: _fail())
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/gap-whitelist", json={
        "skill": "不存在专项名404", "gap": {"issue": "x"},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 404
    assert "不存在" in r.text


def _fail():
    raise AssertionError("不应到达 gap_fix.whitelist_gap")


def test_gap_whitelist_invalid_name_404(app_env, client, monkeypatch):
    """对抗审查二轮补强：非法专项名（含路径分隔/..）此前在 _validate_name 处抛
    ValueError → 未捕获 500；现在统一 404。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat.gap_fix, "whitelist_gap", lambda skill, gap: _fail())
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/gap-whitelist", json={
        "skill": "../etc", "gap": {"issue": "x"},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 404
    assert "不存在" in r.text


# ---- 7. 对抗审查三轮修复批新增回归 ----

def _drain(gen):
    """消费 generator 收集 yield 事件与 return 值。"""
    evs, ret = [], None
    while True:
        try:
            evs.append(next(gen))
        except StopIteration as stop:
            ret = stop.value
            break
    return evs, ret


def test_export_csv_too_many_sqls_400(app_env, client):
    """对抗审查三轮 [1][3]：sqls 条目数客户端可控且无界（此前 1000 条重查询 + 无界 concat
    可打爆共享 MySQL 与后端内存）→ 超过 20 条一律 400，任何 SQL 都不执行。"""
    token = _login_token(client, "admin", "admin123")
    entries = [{"sql": f"SELECT 1 FROM pf_ro_hmt.t{i}", "db": "pf_ro_hmt", "label": f"hmt{i}"}
               for i in range(21)]
    r = client.post("/api/chat/export-csv", json={"sql": "", "name": "x", "sqls": entries},
                    headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 400
    assert "导出条目过多" in r.text


def test_export_csv_label_formula_escaped(app_env, client, monkeypatch):
    """对抗审查三轮 [15]：以 = 开头的地区标签（客户端可控）此前原样进 CSV，Excel 打开
    会当公式执行（CSV 注入）→ _csv_safe_cell 前缀 ' 转义为文本。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "run_raw_sql",
                        lambda engine, sql, max_rows=200000: pd.DataFrame({"流水": [1]}))
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/export-csv", json={
        "sql": "", "name": "x", "sqls": [
            {"sql": "SELECT 1 FROM pf_ro_hmt.t", "db": "pf_ro_hmt",
             "label": '=HYPERLINK("http://evil","点我")'},
        ],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    body = r.content.decode("utf-8-sig")
    assert "'=HYPERLINK" in body
    assert "\n=HYPERLINK" not in body  # 单元格不以公式开头，Excel 不执行


def test_gap_answer_apply_cross_target_skill_blocked(app_env, client, monkeypatch):
    """对抗审查三轮 F0：draft.name 指向他人个人级专项（与 body.skill 不同名）→
    _apply_skill_answer 对目标专项单独做可见性校验，ok=False 且不落盘——此前闸门只查
    body.skill 可见性，攻击者可借自己有权限的关联专项覆写任意专项正文。"""
    import backend.routers.chat as chat
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    metas = {
        "visible-skill": {"level": "通用", "game": "", "owner": "", "sqls": [], "docs": []},
        "victim-skill": {"level": "个人", "game": "rooc_am", "owner": "victim-owner",
                         "sqls": [], "docs": []},
    }
    monkeypatch.setattr(chat.ks, "skill_exists", lambda name: True)
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: metas.get(name, metas["visible-skill"]))
    monkeypatch.setattr(chat.ks, "read_skill", lambda name: "非空正文")
    monkeypatch.setattr(chat.ks, "write_skill", lambda *a, **k: _fail())
    monkeypatch.setattr(chat.ks, "write_skill_meta", lambda *a, **k: _fail())
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/chat/gap-answer/apply", json={
        "model": "fake-model", "skill": "visible-skill",
        "gap": {"remedy_type": "skill"},
        "draft": {"kind": "skill", "action": "modify", "name": "victim-skill",
                  "content": "被篡改的正文", "meta": {"sqls": [], "docs": []}},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert "无权覆盖" in body["message"]


def test_apply_kb_answer_preserves_existing_meta(app_env, monkeypatch):
    """对抗审查三轮 F0：覆写既有知识库文档时保留其原有 level/game/owner（此前无条件重写
    meta，同族成员可把项目级文档升为「通用」扩大可见面，或销毁他人个人级隔离）。"""
    from analysis import ai_client
    from analysis.games import current_owner_key
    from backend.services import gap_fix
    ctx_token = ai_client.set_current_user({"id": "u-me"})
    try:
        writes, meta_writes = [], []
        monkeypatch.setattr(gap_fix.ks, "read_doc", lambda name: "旧内容")
        monkeypatch.setattr(gap_fix.ks, "read_doc_meta", lambda name: {
            "level": "个人", "game": "rooc_am", "owner": current_owner_key()})
        monkeypatch.setattr(gap_fix.ks, "write_doc", lambda name, content: writes.append((name, content)))
        monkeypatch.setattr(gap_fix.ks, "write_doc_meta", lambda *a: meta_writes.append(a))
        out = gap_fix._apply_kb_answer(None, {"kind": "kb", "name": "keep-doc", "content": "新内容"},
                                       "rooc_am")
    finally:
        ai_client.reset_current_user(ctx_token)
    assert out["ok"] is True
    assert writes == [("keep-doc", "新内容")]
    assert meta_writes == []  # 覆写不改 meta：level/game/owner 全部保留


def test_apply_kb_answer_cross_owner_blocked(app_env, monkeypatch):
    """对抗审查三轮 F0 反向：既有文档属他人个人级 → ok=False 不落盘（当前用户上下文
    为 u-me，文档 owner=victim-owner）。"""
    from analysis import ai_client
    from backend.services import gap_fix
    ctx_token = ai_client.set_current_user({"id": "u-me"})
    try:
        writes = []
        monkeypatch.setattr(gap_fix.ks, "read_doc", lambda name: "旧内容")
        monkeypatch.setattr(gap_fix.ks, "read_doc_meta", lambda name: {
            "level": "个人", "game": "rooc_am", "owner": "victim-owner"})
        monkeypatch.setattr(gap_fix.ks, "write_doc", lambda name, content: writes.append(name))
        out = gap_fix._apply_kb_answer(None, {"kind": "kb", "name": "keep-doc", "content": "新内容"},
                                       "rooc_am")
    finally:
        ai_client.reset_current_user(ctx_token)
    assert out["ok"] is False and "无权覆盖" in out["message"]
    assert writes == []


def test_gap_fix_sentinel_family_bound_200(app_env, client, monkeypatch):
    """对抗审查三轮 F2：哨兵模式（X-Game: __any__）下成员服用户修复绑定家族主键的专项
    → _gap_game 家族放行（此前精确 key 鉴权把家族成员拦成 400，与 _require_skill_visible
    的家族语义不一致）。"""
    import backend.routers.chat as chat
    from backend.ide_app.core.auth import hash_password
    monkeypatch.setattr(chat, "resolve_model_for_task", lambda *a, **k: "fake-model")
    monkeypatch.setattr(chat.ks, "skill_exists", lambda name: True)
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: {
        "level": "项目级", "game": "kof", "owner": "anyone", "sqls": [], "docs": []})
    monkeypatch.setattr(chat.gap_fix, "resolve_gap",
                        lambda model, skill, gap, game_key, db, engine: {"ok": True})
    _kof_sea_user()
    db_service.create_user("sea2", hash_password("sea12345"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='kofsea_only' WHERE username='sea2'")
    c.commit()
    token = _login_token(client, "sea2", "sea12345")
    r = client.post("/api/chat/gap-fix", json={
        "model": "fake-model", "skill": "kof-skill",
        "gap": {"issue": "日期窗口太窄", "remedy_type": "sql"},
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_sentinel_skill_candidates_filters(app_env, monkeypatch):
    """对抗审查三轮 [18]：哨兵模式显式点名候选专项名按可见性预过滤——通用全见、个人仅
    归属用户、项目级需绑定游戏且用户有权（家族成员放行）、无元数据 fail closed 不参与。
    此前 list_skills(None) 不过滤，他人个人级专项名会劫持首轮提问流。"""
    import backend.routers.chat as chat
    from analysis.games import owner_key
    user = _kof_sea_user()
    names = ["通用技能", "我的个人技能", "他人个人技能", "绑kof项目技能", "绑hmt项目技能", "无元数据技能"]
    metas = {
        "通用技能": {"level": "通用", "game": "", "owner": ""},
        "我的个人技能": {"level": "个人", "game": "rooc_am", "owner": owner_key(user)},
        "他人个人技能": {"level": "个人", "game": "rooc_am", "owner": "victim-owner"},
        "绑kof项目技能": {"level": "项目级", "game": "kof", "owner": "team"},
        "绑hmt项目技能": {"level": "项目级", "game": "ro_hmt", "owner": "team"},
        "无元数据技能": {},
    }
    monkeypatch.setattr(chat.ks, "list_skills", lambda game_key: names)
    monkeypatch.setattr(chat.ks, "read_skill_meta", lambda name: metas[name])
    out = chat._sentinel_skill_candidates(user)
    # 他人个人级 / 无权家族的项目级 / 无元数据 都被滤掉；kof 家族含 kof_sea（用户有权）放行
    assert out == ["通用技能", "我的个人技能", "绑kof项目技能"]


def test_sentinel_ensure_emits_bound_games(app_env):
    """对抗审查三轮 [5]：哨兵直接绑定（无多选卡）路径同样发 bound_games 事件——前端据此
    同步 sessionGames，提炼/合并/追问才拿得到会话游戏（此前只有多选卡路径会写会话游戏）。"""
    import json as _json
    import backend.routers.chat as chat
    req = ChatRequest(model="m", message="查 ro_hmt 的流水")
    evs, ret = _drain(chat._sentinel_ensure(req, None, _ANON, "查 ro_hmt 的流水"))
    first = _json.loads(evs[0][6:])
    assert first == {"type": "bound_games", "games": ["ro_hmt"], "primary": "ro_hmt"}
    query_games, game, game_key, direct = ret
    assert [g["key"] for g in query_games] == ["ro_hmt"] and game_key == "ro_hmt" and direct is True


def test_deep_stream_emits_bound_games_first(client, app_env, monkeypatch):
    """对抗审查三轮 [6][8]：深度分析哨兵点名具体地区服 → 首个 SSE 事件即 bound_games，
    前端 deepSessionGames 同步（提炼/合并/追问依赖）。"""
    import json as _json
    import backend.routers.agent as agent
    monkeypatch.setattr(agent._llm_svc, "ensure_llm_ready", lambda user: {})
    monkeypatch.setattr(agent.agent_deep, "run_agent_stream", lambda ctx, messages, model_override=None: iter([
        {"type": "answer", "content": "ok"},
        {"type": "final", "success": True, "reply": "ok", "rounds": 1, "tools_used": [],
         "sqls": [], "error": None, "status": "success", "status_text": "成功"},
    ]))
    token = _login_token(client, "admin", "admin123")
    r = client.post("/api/agent/chat/stream", json={
        "message": "查 ro_hmt 的流水", "history": [],
    }, headers={"Authorization": f"Bearer {token}", "X-Game": "__any__"})
    assert r.status_code == 200
    events = [_json.loads(e) for e in _sse_events(r.text)]
    assert events[0] == {"type": "bound_games", "games": ["ro_hmt"], "primary": "ro_hmt"}


def test_query_database_envelope_clips_wide_cells(app_env, monkeypatch):
    """对抗审查三轮 F7：样本行数被 floor 顶住时宽行长单元格仍可把信封撑过
    AGENT_TOOL_RESULT_MAX_CHARS（此前 tool_result_to_str 截出半截 JSON）→ 逐级减半单元格
    上限直至整份信封落入预算；store 内始终是未裁剪全量值，读回不丢数据。"""
    from backend.services import agent_tools
    from backend.services.session_store import ResultStore
    import json as _json
    def fake_run(engine, sql, max_rows=200, max_scanned=0):
        return pd.DataFrame({"流水": ["x" * 500] * 30})
    monkeypatch.setattr(agent_tools, "run_raw_sql", fake_run)
    monkeypatch.setattr(agent_tools, "settings",
                        types.SimpleNamespace(AGENT_TOOL_RESULT_MAX_CHARS=1500))
    store = ResultStore(capacity=4)
    ctx = _qctx([_game("rooc_am")])
    ctx["result_store"] = store
    out = agent_tools.query_database(ctx, "SELECT * FROM pf_rooc_am.t")
    inner = out["result"]
    rows = inner["rows"]
    assert inner["truncated"] is True and len(rows) == 3  # floor=3 顶住行数，靠单元格压缩
    assert all(len(c) <= 161 and c.endswith("…") for row in rows for c in row)
    assert "长单元格已截断" in inner["readback"]
    # store 里是全量值：30 行 × 500 字符原文
    full = store.get(inner["result_id"])["rows"]
    assert len(full) == 30 and len(full[0][0]) == 500
    # tool_result_to_str 输出是完整 JSON（信封已落入预算），不再有硬截断后缀
    text = agent_tools.tool_result_to_str(out)
    assert "已截断至" not in text
    parsed = _json.loads(text.split("\n", 1)[1])
    assert parsed["result"]["result_id"] == inner["result_id"]
