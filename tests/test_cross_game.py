"""跨游戏查询修复（2026-10-23 用户反馈）回归测试。

覆盖两条路径：
1. 普通聊天 _resolve_game：点名具体游戏优先于 AI 归一化（ro_hmt 不再展开成 ro 家族
   7 个地区服），有权直接按其查询（direct=True 不弹确认卡）；AI 兜底命中维持确认卡。
2. 深度分析 resolve_cross_game + run_agent_stream：先鉴权，有权把 agent 绑到目标游戏库
   并附「建议切换」提示；无权直接拒绝（不再弹「只查当前/切换/AI再找找/取消」四选一）。
"""
from backend.ide_app.services import db_service
from backend.routers.chat import _resolve_game
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


# ---- 普通聊天：_resolve_game ----


def test_named_cross_family_game_direct_only_target(app_env):
    """选中 rooc_am 点名 ro_hmt → 只查 ro_hmt，不展开 ro 家族，direct=True。"""
    qg, g, gk, gm, direct = _resolve_game(
        "我想要 ro_hmt 过去7天的流水", _game("rooc_am"), "rooc_am", None, user=None)
    assert [x["key"] for x in qg] == ["ro_hmt"]
    assert gk == "ro_hmt"
    assert "ro_hmt" in gm and "已按其查询" in gm
    assert direct is True


def test_named_game_beats_ai_target_normalization(app_env):
    """AI 把 ro_hmt 归一化成家族 rooc/ro 时，规则点名仍优先。"""
    qg, g, gk, gm, direct = _resolve_game(
        "我想要 ro_hmt 过去7天的流水", _game("rooc_am"), "rooc_am", None, ai_target="rooc")
    assert [x["key"] for x in qg] == ["ro_hmt"]
    assert gk == "ro_hmt"
    assert direct is True


def test_named_same_family_region_direct(app_env):
    """选中 rooc 点名 rooc_am → 只查 rooc_am（同族点名同样不展开）。"""
    qg, g, gk, gm, direct = _resolve_game(
        "rooc_am 的流水", _game("rooc"), "rooc", None, user=None)
    assert [x["key"] for x in qg] == ["rooc_am"]
    assert direct is True


def test_denied_target_falls_back_to_current(app_env):
    """点名无权游戏 → 留在当前游戏并提示，direct=False（不切库）。"""
    qg, g, gk, gm, direct = _resolve_game(
        "我想要 ro_hmt 过去7天的流水", _game("rooc_am"), "rooc_am", None,
        user=_limited_user())
    assert [x["key"] for x in qg] == ["rooc_am"]
    assert gk == "rooc_am"
    assert "暂无其数据权限" in gm
    assert direct is False


def test_family_key_selected_expands_family(app_env):
    """选中家族主键 rooc 且点名 rooc → 维持家族展开（跨地区要都查出来）。"""
    qg, g, gk, gm, direct = _resolve_game(
        "rooc 的流水", _game("rooc"), "rooc", None, user=None)
    keys = [x["key"] for x in qg]
    assert "rooc" in keys and "rooc_am" in keys
    assert direct is False


def test_selected_region_named_itself_no_change(app_env):
    """选中 rooc_am 点名 rooc_am → 原样，无提示。"""
    qg, g, gk, gm, direct = _resolve_game(
        "rooc_am 的流水", _game("rooc_am"), "rooc_am", None, user=None)
    assert [x["key"] for x in qg] == ["rooc_am"]
    assert gm is None and direct is False


def test_no_mention_no_ai_target_keeps_current(app_env):
    """规则未命中且无 AI 兜底目标 → 原样，无提示，维持确认卡语义。"""
    qg, g, gk, gm, direct = _resolve_game(
        "最近7天流水怎么样", _game("rooc_am"), "rooc_am", None, user=None)
    assert [x["key"] for x in qg] == ["rooc_am"]
    assert gk == "rooc_am"
    assert gm is None and direct is False


def test_named_uppercase_game_code(app_env):
    """大写游戏代码（RO_HMT）同样命中点名（匹配不区分大小写）。"""
    qg, g, gk, gm, direct = _resolve_game(
        "查 RO_HMT 的流水", _game("rooc_am"), "rooc_am", None, user=None)
    assert [x["key"] for x in qg] == ["ro_hmt"]
    assert direct is True


# ---- 游戏关键词词边界（对抗审查 2026-10-23：act/ro 误命中）----

def test_ascii_keyword_word_boundary_no_false_match(app_env):
    """「active/contact/promotion」不得命中 act/ro（纯 ASCII 关键词按词边界匹配）。"""
    assert games_svc.match_game_in_text("查询 active 用户数") is None
    assert games_svc.match_game_in_text("contact 渠道的表现") is None
    assert games_svc.match_game_in_text("promotion 活动效果") is None


def test_ascii_keyword_word_boundary_still_matches(app_env):
    """独立出现的 act / ro_hmt 仍正常命中。"""
    hit = games_svc.match_game_in_text("查 act 的流水")
    assert hit and hit["key"] == "act"
    hit = games_svc.match_game_in_text("查 ro_hmt 的流水")
    assert hit and hit["key"] == "ro_hmt"


def test_family_members_primary_first(app_env):
    """family_members 规范成员（无地区后缀）排最前，跨地区要都查出来。"""
    members = games_svc.family_members(_game("rooc_am"))
    assert members[0]["key"] == "rooc"
    keys = {m["key"] for m in members}
    assert "rooc_am" in keys and "rooc" in keys


# ---- 深度分析：拒绝记忆（对抗审查 2026-10-23 二轮：拒绝死循环）----


def test_deep_denied_history_message_not_retriggered(app_env):
    """被拒点名留在历史里后，不相关追问不得再被历史里的拒绝消息硬拦。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    user = _limited_user()
    text = "我想要 ro_hmt 过去7天的流水"
    # 第一次：触发拒绝并写入拒绝记忆
    _, _, denied1 = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": text}], user=user)
    assert denied1 is not None
    # 第二次：不相关追问（当前消息无点名）——历史里的被拒消息被跳过，留在当前游戏
    messages = [
        {"role": "user", "content": text},
        {"role": "assistant", "content": "你暂无 ro_hmt 的数据权限……"},
        {"role": "user", "content": "那分析一下流水趋势"},
    ]
    g, switched, denied = agent_deep.resolve_cross_game(game, messages, user=user)
    assert g["key"] == "rooc_am" and denied is None


def test_deep_denied_remark_deterministic(app_env):
    """当前消息重新点名被拒游戏 → 仍确定性拒绝（拒绝记忆只跳过历史，不放过当前点名）。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    user = _limited_user()
    text = "我想要 ro_hmt 过去7天的流水"
    g1, _, denied1 = agent_deep.resolve_cross_game(game, [{"role": "user", "content": text}], user=user)
    assert denied1 is not None
    # 同文本作为当前消息再次点名：仍拒绝（不会因记忆被跳过）
    g2, _, denied2 = agent_deep.resolve_cross_game(game, [{"role": "user", "content": text}], user=user)
    assert denied2 is not None and g2["key"] == "rooc_am"


def test_deep_uppercase_mention_switches(app_env):
    """深度分析大写点名同样生效。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    g, switched, denied = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "查 RO_HMT 的流水"}], user=None)
    assert g["key"] == "ro_hmt" and denied is None


def test_ai_target_fallback_keeps_confirm_card(app_env):
    """规则未命中、AI target_game 兜底（如「东南亚」→ ro_sea）→ 切库但 direct=False 维持确认卡。"""
    qg, g, gk, gm, direct = _resolve_game(
        "东南亚的流水", _game("rooc_am"), "rooc_am", None, ai_target="ro_sea", user=None)
    assert [x["key"] for x in qg] == ["ro_sea"]
    assert gk == "ro_sea"
    assert direct is False


def test_history_injected_game_is_not_direct(app_env):
    """回归 2026-10-28：游戏名只出现在 decide 结合历史补全后的精化问题里、当前消息原话没点名
    （用户反馈：右上角 rooc_am 被前面 10 轮对话里的「拳皇」静默切走）→ 仍按目标切库，
    但 direct=False（走确认卡），提示不带「建议在顶部切换」（不算点名）。"""
    qg, g, gk, gm, direct = _resolve_game(
        "预测拳皇未来10天的流水金额",  # decide 补全后的精化问题
        _game("rooc_am"), "rooc_am", None, user=None,
        raw_question="帮我预测一下未来10天的流水金额",  # 用户原话：无游戏名
    )
    assert [x["key"] for x in qg] == ["kof"]
    assert gk == "kof"
    assert direct is False
    assert "已按其查询" in gm
    assert "建议在顶部切换" not in gm


def test_raw_named_still_direct_with_raw_question(app_env):
    """当前消息原话点名的语义不受 raw_question 机制影响：原话含游戏名 → direct=True。"""
    qg, g, gk, gm, direct = _resolve_game(
        "查拳皇最近7天的流水", _game("rooc_am"), "rooc_am", None, user=None,
        raw_question="查拳皇最近7天的流水",
    )
    assert [x["key"] for x in qg] == ["kof"]
    assert gk == "kof"
    assert direct is True


# ---- 深度分析：resolve_cross_game ----


def test_deep_no_mention_keeps_current(app_env):
    from backend.services import agent_deep
    game = _game("rooc_am")
    g, switched, denied = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "最近7天各国家流水趋势"}], user=None)
    assert g["key"] == "rooc_am" and switched is None and denied is None


def test_deep_mentions_current_keeps_current(app_env):
    from backend.services import agent_deep
    game = _game("rooc_am")
    g, switched, denied = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "rooc_am 的流水"}], user=None)
    assert g["key"] == "rooc_am" and switched is None and denied is None


def test_deep_cross_game_allowed_switches(app_env):
    from backend.services import agent_deep
    game = _game("rooc_am")
    g, switched, denied = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "我想要 ro_hmt 过去7天的流水"}], user=None)
    assert g["key"] == "ro_hmt"
    assert switched == {"from_key": "rooc_am", "to_key": "ro_hmt"} or (
        switched and switched["from_key"] == "rooc_am" and switched["to_key"] == "ro_hmt")
    assert denied is None


def test_deep_cross_game_denied(app_env):
    from backend.services import agent_deep
    game = _game("rooc_am")
    g, switched, denied = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "我想要 ro_hmt 过去7天的流水"}], user=_limited_user())
    assert g["key"] == "rooc_am" and switched is None
    assert "数据权限" in denied and "ro_hmt" in denied


def test_deep_followup_keeps_switched_game(app_env):
    """哨兵模式（不选游戏）：追问（不带游戏名）延续上一条点名——回扫用户消息命中 ro_hmt。"""
    from backend.services import agent_deep
    messages = [
        {"role": "user", "content": "我想要 ro_hmt 过去7天的流水"},
        {"role": "assistant", "content": "ro_hmt 过去7天流水 123 万……"},
        {"role": "user", "content": "按国家拆分一下"},
    ]
    g, switched, denied = agent_deep.resolve_cross_game(
        None, messages, user=None, family_grace=True, scan_history=True)
    assert g["key"] == "ro_hmt" and denied is None


def test_deep_follow_mode_history_mention_does_not_switch(app_env):
    """follow 模式（右上角已选游戏）：历史里的旧游戏名不得切库——只扫当前消息
    （2026-10-26 用户反馈：右上角 rooc_am，深度分析却被历史 kof 点名绑到 pf_kof）。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    messages = [
        {"role": "user", "content": "我想要 ro_hmt 过去7天的流水"},
        {"role": "assistant", "content": "ro_hmt 过去7天流水 123 万……"},
        {"role": "user", "content": "用深度分析跑一遍专项「流水达成分析」"},
    ]
    g, switched, denied = agent_deep.resolve_cross_game(
        game, messages, user=None, scan_history=False)
    assert g["key"] == "rooc_am" and switched is None and denied is None


def test_deep_follow_mode_current_mention_still_switches(app_env):
    """follow 模式：当前消息点名仍切库（与普通聊天同语义，2026-10-23 特性保留）；只关历史回扫。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    g, switched, denied = agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "我想要 ro_hmt 过去7天的流水"}],
        user=None, scan_history=False)
    assert g["key"] == "ro_hmt" and denied is None


def test_deep_follow_mode_history_mention_denied_not_retriggered(app_env):
    """follow 模式：历史里的被拒点名同样不重扫（scan_history=False 下被拒文本整体跳过）。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    user = _limited_user()
    # 先触发一次拒绝记忆
    agent_deep.resolve_cross_game(
        game, [{"role": "user", "content": "我想要 ro_hmt 过去7天的流水"}], user=user,
        scan_history=False)
    messages = [
        {"role": "user", "content": "我想要 ro_hmt 过去7天的流水"},
        {"role": "assistant", "content": "你暂无 ro_hmt 的数据权限……"},
        {"role": "user", "content": "分析一下流水趋势"},
    ]
    g, switched, denied = agent_deep.resolve_cross_game(
        game, messages, user=user, scan_history=False)
    assert g["key"] == "rooc_am" and denied is None


def test_deep_assistant_mention_does_not_switch(app_env):
    """assistant 回答里的游戏名不算点名；用户消息无点名 → 不切换。"""
    from backend.services import agent_deep
    game = _game("rooc_am")
    messages = [
        {"role": "user", "content": "分析一下流水"},
        {"role": "assistant", "content": "可以按 ro_hmt 的口径……"},
        {"role": "user", "content": "继续"},
    ]
    g, switched, denied = agent_deep.resolve_cross_game(game, messages, user=None)
    assert g["key"] == "rooc_am" and switched is None


# ---- 深度分析：run_agent_stream 切换提示 ----

def test_deep_stream_switch_hint_in_answer_and_final(app_env, monkeypatch):
    from backend.services import agent_deep

    monkeypatch.setattr(agent_deep, "resolve_model_for_task", lambda *a, **k: "fake-model")

    def fake_stream(model, convo, **kw):
        yield {"type": "content", "delta": "ro_hmt 过去7天流水 123 万。"}
        yield {"type": "done", "content": "ro_hmt 过去7天流水 123 万。", "tool_calls": None}

    monkeypatch.setattr(agent_deep, "complete_message_stream", fake_stream)
    switched = {"from_key": "rooc_am", "from_name": "ROOC", "to_key": "ro_hmt",
                "to_name": "RO仙境傳說：愛如初見"}
    ctx = {"engine": None, "game": _game("rooc_am"), "user": {}, "game_switched": switched}
    events = list(agent_deep.run_agent_stream(
        ctx, [{"role": "user", "content": "我想要 ro_hmt 过去7天的流水"}]))
    types = [e["type"] for e in events]
    assert "plan_text" in types
    assert any(e["type"] == "plan_text" and "ro_hmt" in e["text"] and "已切换" in e["text"] for e in events)
    # 流式路径：提示以 answer delta 追加到实时渲染的答案尾部
    assert any(e["type"] == "answer" and "delta" in e and "建议在顶部切换" in e["delta"] for e in events)
    final = next(e for e in events if e["type"] == "final")
    assert final["success"] is True
    assert "建议在顶部切换" in final["reply"]


# ---- 深度分析：无权拒绝（端点级）----

def test_deep_stream_endpoint_denies_unauthorized_game(client, app_env):
    from backend.ide_app.core.auth import hash_password

    db_service.upsert_identity(
        key="limited_rooc", name="限ROOC",
        permission_points=["apps", "analysis", "ai"], games=["rooc_am"], is_builtin=0,
    )
    db_service.create_user("carol", hash_password("carol123"))
    c = db_service._conn()
    c.execute("UPDATE users SET identity='limited_rooc' WHERE username='carol'")
    c.commit()
    token = client.post("/api/auth/login",
                        json={"username": "carol", "password": "carol123"}).json()["access_token"]
    r = client.post(
        "/api/agent/chat/stream",
        json={"message": "我想要 ro_hmt 过去7天的流水", "history": []},
        headers={"Authorization": f"Bearer {token}", "X-Game": "rooc_am"},
    )
    assert r.status_code == 200
    assert '"type": "error"' in r.text
    assert "数据权限" in r.text and "ro_hmt" in r.text
    assert '"type": "final"' in r.text
