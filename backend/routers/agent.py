"""深度分析 Agent 的 SSE 端点（P3）。由前端「深度分析」开关触发，独立于一次性生成快路径。

另含个人 LLM 配置（key/model/api_base 跟账号）的读写 + 连通性测试端点：
前端 LLM 配置页走 /api/agent/config、/api/agent/test-llm（一等公民接口，复用 ide_backend 的
user_agent_config 表，与 /ide 子应用共享同一份 ide_data.db）。
"""
import ipaddress
import json
import os
import re
import socket
import uuid
from urllib.parse import urlsplit

import requests
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from analysis import ai_client
from analysis.games import owner_key
from .. import config
from ..deps import get_current_user, get_engine, get_game
from ..services import agent_deep, rate_limit
from ..services.export_artifacts import EXPORT_ROOT, MIME_BY_FORMAT, sanitize_owner
from ..services.ide_bridge import anonymous_uid, db_service
from ..services import llm as _llm_svc
from ..services.llm import LLMNotConfigured, inject_temperature

router = APIRouter(prefix="/api/agent", tags=["agent"])


def _sse(payload: dict) -> str:
    return "data: " + json.dumps(payload, ensure_ascii=False) + "\n\n"


def _game_option_line(g: dict) -> str:
    """多选卡编号行的单条选项文案。label（region_label）已含（key）时不再重复拼接——
    与前端 app.js gameOptionLines 同规则，保证 stripAskOptionLines 能精确对齐剔除。"""
    label = str(g.get("label") or g.get("name") or "").strip()
    key = str(g.get("key") or "").strip()
    if not key or not label or label == key:
        return label or key
    return label if label.endswith(f"（{key}）") else f"{label}（{key}）"


class AgentChatRequest(BaseModel):
    message: str
    history: list[dict] = []
    model: str | None = None  # 可选模型覆盖（SQL 编辑器「AI·SQL编辑」侧栏切换 LLM 用）
    games: list[str] | None = None  # 游戏多选卡回传（「不选游戏」提问后用户所选，一次性）
    session_games: list[str] | None = None  # 会话延续（上一轮已绑定游戏的 key，后端按权限过滤）


@router.post("/chat/stream")
def chat_stream(
    body: AgentChatRequest,
    request: Request,
    user: dict = Depends(get_current_user),
    game: dict = Depends(get_game),
):
    """深度分析 SSE：多轮 agentic 循环（查表 → 取数 → 看结果 → 自纠 → 结论）。"""
    # 审计 P1-21（按用户每分钟限流）+ P1-20（并发闸）：深度分析最贵（最多 12 轮工具调用），
    # 同用户同时只允许 1 个流，超限直接 429。
    rate_limit.check_rate(user, request, rate_limit.AGENT_LIMIT_PER_MINUTE)
    slot_key = rate_limit.acquire_slot(user, request, rate_limit.AGENT_MAX_CONCURRENT)
    # 取消支持：每个深度分析流注册一个 run_id，前端停止按钮可跨请求取消，让循环在下个检查点收口。
    run_id = uuid.uuid4().hex[:12]
    # 对抗审查：并发槽与取消注册一旦占用，后续任何构造异常都必须立即释放——否则
    # AGENT_MAX_CONCURRENT=1 会让该用户深度分析被永久锁死、cancel 对死 run 永远返回 True（直到重启）。
    try:
        cancel_event = agent_deep.register_run(run_id, str(user.get("id") or ""))
        messages = [
            {"role": h["role"], "content": h["content"]}
            for h in (body.history or [])
            if isinstance(h, dict) and h.get("role") in ("user", "assistant") and h.get("content")
        ]
        messages.append({"role": "user", "content": body.message})
        # 审计·聊天优化块 B：历史只保留最近 AGENT_HISTORY_ROUNDS 轮（用户+助手各算一条消息），
        # 与预检索命中的知识库/专项/已存 SQL/分析模型资产一起喂给 Agent——上下文够用又不被远古会话拖累。
        history_rounds = int(getattr(config, "AGENT_HISTORY_ROUNDS", 10) or 10)
        messages = messages[-(history_rounds * 2):]
        # 跨游戏识别（先鉴权）：问题点名其它游戏 → 有权直接把 agent 绑到目标游戏库查询
        # （收口附「建议切换」提示）；无权则明确拒绝，不再让 agent 在当前库里空转后弹
        # 「只查当前/切换/AI再找找/取消」四选一提问（2026-10-23 用户反馈）。
        sentinel_mode = game is None  # 聊天页「不选游戏」哨兵（X-Game: __any__）
        # 评审 H1：哨兵模式下多选卡回传（body.games 非空）是用户显式选择，优先级最高——
        # 跳过跨游戏点名扫描，避免历史消息里的游戏名/被拒点名与显式选择打架。
        # family_grace（评审 M1）：点名家族主键（如「拳皇」）而仅有成员服权限时放行，
        # 由 sentinel_bind_games 展开成员∩允许集（预选/直跑有权限的成员服）。
        if sentinel_mode and body.games:
            game, switched, denied = game, None, None
        else:
            # follow 模式（右上角已选游戏）只扫当前消息：历史里的旧游戏名不得把新问题带偏
            # （2026-10-26 用户反馈：右上角 rooc_am，深度分析却被历史 kof 点名绑到 pf_kof）。
            # 哨兵模式（不选游戏）保留历史回扫，延续「先问 ro_hmt、追问不带游戏名」的提问绑定。
            game, switched, denied = agent_deep.resolve_cross_game(
                game, messages, user,
                family_grace=sentinel_mode,
                scan_history=sentinel_mode,
            )
        if denied:
            def gen_denied():
                yield _sse({"type": "error", "message": denied})
                yield _sse({"type": "final", "success": False, "reply": denied, "rounds": 0,
                            "tools_used": [], "sqls": [], "error": denied,
                            "status": "failed", "status_text": "失败"})

            # 拒绝路径不进 agent 循环：立即释放并发槽与取消注册，返回短流在前端消息体内展示拒绝原因
            rate_limit.release_slot(slot_key)
            agent_deep.unregister_run(run_id)
            return StreamingResponse(
                gen_denied(),
                media_type="text/event-stream",
                headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
            )
        # 哨兵绑定（chat 页「不选游戏」）：与普通聊天同款优先级绑定执行游戏——多选卡回传
        # body.games / 会话延续 body.session_games / 恰 1 款权限游戏自动绑 / 否则多选卡提问。
        # 哨兵模式下 game 非 None 只可能来自 resolve_cross_game 的点名：有权直点名（switched）
        # 或 family_grace 放行的家族主键（switched=None），两种情况都展开家族成员（>1 → ask
        # 卡预选；==1 → 直跑该成员）。地区服点名直接 run，不展开。
        # 非哨兵（follow 模式）点名家族主键保持既有直查行为不变。
        games_list = [game] if game else []
        game_note = None
        bound_games_keys = None  # 哨兵绑定成功的游戏 key 列表（首个 SSE 事件回传，前端同步会话游戏）
        if game is None or (sentinel_mode and agent_deep.is_family_primary(game)):
            bound = agent_deep.sentinel_bind_games(
                game, body.games, body.session_games, get_engine(), user
            )
            if bound[0] == "ask":
                _kind, games_opts, preselected, reason = bound
                question_text = reason or "请选择要查询的游戏（可多选）"
                # 提问路径不进 agent 循环、不触 LLM 闸门：立即释放并发槽与取消注册。
                rate_limit.release_slot(slot_key)
                agent_deep.unregister_run(run_id)

                def gen_select():
                    # game_select 多选卡 + question（无 options——不复用 ask_user 的
                    # 可点选项卡协议）+ final（success=true 表示正常收口提问，前端按
                    # msg._gameSelect 特判状态标「待选择游戏…」、不挂提炼按钮）。
                    # 对抗审查二轮：final reply 拼上编号选项行（与 ask_user 同协议）——
                    # 前端把「我选择第 N 项游戏」作为下一条 user 消息入库，历史里带
                    # 编号选项模型才能对照编号还原所选游戏
                    option_lines = [
                        f"{i}. {_game_option_line(g)}"
                        for i, g in enumerate(games_opts, 1)
                    ]
                    reply = question_text + ("\n" + "\n".join(option_lines) if option_lines else "")
                    yield _sse({"type": "game_select", "question": question_text,
                                "games": games_opts, "preselected": preselected or [], "reason": reason})
                    yield _sse({"type": "question", "question": question_text, "options": []})
                    yield _sse({"type": "final", "success": True, "reply": reply, "rounds": 0,
                                "tools_used": [], "sqls": [], "error": None,
                                "status": "success", "status_text": "待选择"})

                return StreamingResponse(
                    gen_select(),
                    media_type="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
                )
            _kind, query_games, game, note = bound
            games_list = query_games
            bound_games_keys = [g["key"] for g in query_games]
            if note:
                game_note = note
        elif sentinel_mode and game is not None:
            # 哨兵模式点名具体地区服（resolve_cross_game 直接切换、不展开家族）：同样回传
            # 绑定游戏，前端 deepSessionGames 同步（对抗审查三轮 [6]，提炼/合并/追问依赖）
            bound_games_keys = [game["key"]]
        # LLM 前置闸门（2026-10-23）：进入 agent 循环前确认 LLM 可用——配置缺失/Key 失效/
        # 网关不可达时立即给错误短流，而不是在首次模型调用处报原始连接错误。放在跨游戏
        # 鉴权拒绝之后：无权游戏的拒绝信息比 LLM 配置提示更贴近用户问题。
        _llm_svc.ensure_llm_ready(user)
        ctx = {"engine": get_engine(), "game": game, "user_id": anonymous_uid(user), "user": user,
               "run_id": run_id, "cancel_event": cancel_event, "game_switched": switched,
               "games": games_list, "game_note": game_note}
    except LLMNotConfigured as exc:
        # LLM 不可用：释放并发槽与取消注册后返回短流；先落局部变量再闭包——
        # except 块结束后 exc 会被解释器删除，嵌套生成器闭包引用会 NameError。
        msg = str(exc)
        rate_limit.release_slot(slot_key)
        agent_deep.unregister_run(run_id)

        def gen_llm_err():
            yield _sse({"type": "error", "message": msg})
            yield _sse({"type": "final", "success": False, "reply": msg, "rounds": 0,
                        "tools_used": [], "sqls": [], "error": msg,
                        "status": "failed", "status_text": "失败"})

        return StreamingResponse(
            gen_llm_err(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )
    except Exception:
        # 构造期异常：立即双保险释放并发槽与取消注册（此时 gen() 尚未创建，不会与流结束时重复释放）。
        rate_limit.release_slot(slot_key)
        agent_deep.unregister_run(run_id)
        raise

    def gen():
        try:
            if bound_games_keys:
                # 对抗审查三轮 [6][8]：哨兵直接绑定（无多选卡）回传实际绑定游戏，
                # 前端据此写 deepSessionGames——点名/恰1款自动绑/家族展开后的
                # 提炼、合并、追问才拿得到会话游戏
                yield _sse({"type": "bound_games", "games": bound_games_keys,
                            "primary": bound_games_keys[0] if bound_games_keys else None})
            # 每步线程上下文隔离：注入的温度只在当步生效，包装后步内（含 run_agent_stream 首步
            # resolve_model_for_task）的 LLM 调用都能读到 agent 任务温度
            for ev in inject_temperature(agent_deep.run_agent_stream(ctx, messages, model_override=body.model), "agent"):
                yield _sse(ev)
        finally:
            rate_limit.release_slot(slot_key)
            agent_deep.unregister_run(run_id)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


class AgentCancelBody(BaseModel):
    run_id: str = ""


@router.post("/cancel")
def cancel_agent(body: AgentCancelBody, user: dict = Depends(get_current_user)):
    # 前端停止按钮调用，让正在跑的深度分析在下个检查点收口。
    # 只允许发起人取消自己的流：不存在/已结束与越权返回同一 404 文案，防 True/False 存活探测。
    result = agent_deep.request_cancel(body.run_id, str(user.get("id") or ""))
    if result is None:
        raise HTTPException(status_code=404, detail="运行不存在或已结束")
    if result:
        return {"ok": True, "canceled": True}
    return {"ok": True, "canceled": False}


_ARTIFACT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


@router.get("/artifacts/{artifact_id}/download")
def download_artifact(artifact_id: str, user: dict = Depends(get_current_user)):
    """下载 export_query 交付的产物文件。只在本用户归属目录里找，跨用户不可见。"""
    # 严格白名单校验：artifact_id 只用于拼文件名，不校验就是一个路径穿越口子
    if not _ARTIFACT_ID_RE.fullmatch(artifact_id):
        raise HTTPException(status_code=400, detail="非法的产物 ID")
    owner = sanitize_owner(owner_key(user) or "anonymous")
    owner_dir = EXPORT_ROOT / owner
    path = None
    for ext in ("xlsx", "csv", "sql", "txt"):
        candidate = owner_dir / f"{artifact_id}.{ext}"
        if candidate.is_file():
            path = candidate
            break
    if path is None:
        raise HTTPException(status_code=404, detail="产物不存在或已过期")
    # 下载时回原始 file_name（带中文），meta 读不到时回落 artifact_id
    file_name = f"{artifact_id}{path.suffix}"
    try:
        meta = json.loads((owner_dir / f"{artifact_id}.meta.json").read_text(encoding="utf-8"))
        file_name = meta.get("file_name") or file_name
    except Exception:
        pass
    return FileResponse(path, filename=file_name, media_type=MIME_BY_FORMAT[path.suffix.lstrip(".")])


@router.get("/starters")
def list_starters(user: dict = Depends(get_current_user)):
    """深度分析候选开场白：按用户游戏范围过滤，供聊天页「候选卡」渲染。"""
    # 游戏范围取自 RBAC 生效游戏（identities.games + users.extra_games 合并），与 deps.get_game 同源；
    # 不能读 user["games"]——get_current_user 返回 users 表原始行，没有 games 列，恒为空会让过滤完全失效。
    from backend.ide_app.services.permissions import effective_games
    games = effective_games(user)
    return {"starters": agent_deep.starters_for_user(games), "cap": 6}


class AgentConfigBody(BaseModel):
    api_key: str = ""
    model: str = "deepseek-chat"
    api_base: str = "https://api.deepseek.com/v1"


class TestLLMBody(BaseModel):
    api_key: str = ""
    model: str = "deepseek-chat"
    api_base: str = ""


# 审计·SSRF 防护：api_base 由用户提交、服务器直接发起 GET，必须先校验目标再连接，
# 否则可用来探测内网端口（错误分支会回显响应片段）或打云元数据端点（169.254.169.254）。
# 只允许标准 API 路径前缀（如空、/、/v1），拒绝带查询参数/片段/用户信息或怪字符的地址。
_API_BASE_PATH_RE = re.compile(r"^(?:/[A-Za-z0-9._~-]+)*$")


def _validate_api_base(base: str) -> str:
    """校验用户提交的 api_base。返回错误文案；空串表示通过。"""
    try:
        parts = urlsplit(base)
        if parts.scheme not in ("http", "https"):
            return "API 地址只支持 http/https 协议"
        if not parts.hostname:
            return "API 地址缺少主机名"
        if parts.username or parts.password:
            return "API 地址不允许携带账号密码"
        if parts.query or parts.fragment:
            return "API 地址不允许携带查询参数"
        if not _API_BASE_PATH_RE.match(parts.path.rstrip("/")):
            return "API 地址路径不是标准 API 前缀（如 /v1）"
        port = parts.port  # 端口非法（非数字/越界）会抛 ValueError
    except ValueError:
        return "API 地址格式不合法"
    # 主机必须能解析，且解析出的每个 IP 都必须是全局可路由公网地址——
    # 拦回环/私网/链路本地/组播/保留网段（含 169.254.0.0/16 云元数据），按解析结果校验
    # 也能拦住 127.1、0x7f000001 这类会被解析器还原成内网地址的写法。
    try:
        infos = socket.getaddrinfo(parts.hostname, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        return "API 地址主机名无法解析"
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            return "API 地址主机名无法解析"
        if (
            not ip.is_global
            or ip.is_loopback
            or ip.is_private
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        ):
            return "API 地址不允许指向内网或本机地址"
    return ""


# 审计·SSRF 防护（全链路闸门，不止 /test-llm 一处）：此前 _validate_api_base 只在 /test-llm
# 生效——PUT /config 把 api_base 原样入库、resolve_llm 原样透传、ai_client 的两处 requests.post
# 未禁重定向。任意登录用户可先存一个公网恶址（/chat/completions 302 跳内网）或直连内网地址的
# api_base，再借普通聊天/深度分析让服务器以内网身份发请求并回显响应片段（探测内网端口/打云元
# 数据端点）。本文件不改 services/llm.py 与 analysis 包，在导入期就地收口三条路：
#   1) PUT /config 入库前校验（见 update_config）；
#   2) 包装 services.llm.resolve_llm：用户自配（非哨兵、非空）的 api_base 校验不过直接抛
#      LLMNotConfigured（llm.py 内部全部经模块全局引用 resolve_llm，chat/deep 等
#      所有调用路径都会过这道闸）；同时把包装器重新注册进 analysis.ai_client，堵住 analysis
#      包内直调 chat_completion* 的路径（_user_llm_kwargs 走注册的 resolver）；
#   3) 把 ai_client.requests 换成只透传、但 post 强制 allow_redirects=False 的代理，堵住
#      公网地址 302 跳内网（重定向型 SSRF；LLM 网关接口不存在合法重定向）。
# 残留面：校验与直连之间仍有一次 DNS 重解析（重绑定 TOCTOU 窗口，毫秒级），彻底钉死 IP 需改
# analysis/ai_client.py 的连接层（超出本文件范围）；全局 .env 的 BASE_URL 是服务端可信配置，
# 不受此闸门限制（resolve_llm 未配置时返回 None 回落全局，与现状一致）。
_ORIG_RESOLVE_LLM = _llm_svc.resolve_llm


def _resolve_llm_guarded(user):
    """包装 resolve_llm：对 per-user api_base 做与 test-llm 同口径的地址校验后再透传。"""
    llm = _ORIG_RESOLVE_LLM(user)
    base = (llm.get("api_base") or "").strip()
    if base:
        err = _validate_api_base(base)
        if err:
            raise LLMNotConfigured(
                f"个人 LLM API 地址未通过安全校验：{err}。请在「LLM 配置」中修改后重试。"
            )
    return llm


_llm_svc.resolve_llm = _resolve_llm_guarded
ai_client.set_user_llm_resolver(_resolve_llm_guarded)


class _NoRedirectRequests:
    """requests 透传代理：post 强制 allow_redirects=False，其余属性原样委托真实 requests。"""

    def __getattr__(self, name):
        return getattr(requests, name)

    def post(self, url, *args, **kwargs):
        kwargs.setdefault("allow_redirects", False)
        return requests.post(url, *args, **kwargs)


ai_client.requests = _NoRedirectRequests()


@router.get("/config")
def get_config(user: dict = Depends(get_current_user)):
    """个人 LLM 配置（key/model/api_base 跟账号），供前端 LLM 配置页读写。"""
    return db_service.get_agent_config(user.get("id") or "anonymous")


@router.put("/config")
def update_config(cfg: AgentConfigBody, user: dict = Depends(get_current_user)):
    # 审计·SSRF 防护：api_base 入库前先过地址校验（此前原样入库，任意登录用户都能存
    # 内网地址/恶址，再借聊天路径让服务器打内网），校验不过直接 400、不落库。
    base = (cfg.api_base or "").strip()
    if base:
        check_err = _validate_api_base(base)
        if check_err:
            raise HTTPException(status_code=400, detail=check_err)
    cfg.api_base = base  # 空串=未配置（回落全局 .env），语义与 llm.py 的哨兵归一一致
    db_service.save_agent_config(user.get("id") or "anonymous", cfg.model_dump())
    return {"message": "配置已保存"}


@router.post("/test-llm")
def test_llm(body: TestLLMBody, user: dict = Depends(get_current_user)):
    """连通性测试：admin 的 key 留空时回落全局 .env；其他身份必须手填个人 Key（否则无法使用 AI）。"""
    from backend.ide_app.services.permissions import has_perm
    key = (body.api_key or "").strip()
    user_base = (body.api_base or "").strip()
    if not key and has_perm(user, "system"):
        # admin 回落全局 .env
        key = (
            os.environ.get("OPENAI_API_KEY")
            or os.environ.get("LITELLM_API_KEY")
            or os.environ.get("AI_API_KEY")
            or ""
        )
    if not key:
        return {"success": False, "message": "当前账号身份需手填个人 LLM API Key 才能使用 AI 功能（仅管理员可回落系统默认配置）。"}
    base = user_base or ai_client.BASE_URL
    # 审计·SSRF 防护：只校验「用户提交」的地址；回落服务端默认网关（.env 的 BASE_URL 是
    # 可信配置，与 resolve_llm 未配置时回落全局的口径一致）不做内网拦截。
    if user_base:
        check_err = _validate_api_base(base)
        if check_err:
            return {"success": False, "message": check_err}
    try:
        resp = requests.get(
            f"{base.rstrip('/')}/models",
            headers={"Authorization": f"Bearer {key}"},
            timeout=15,
            allow_redirects=False,  # 禁跟随重定向，防公网地址 302 跳到内网目标（重定向型 SSRF）
        )
        code = resp.status_code
        if code in (401, 403):
            return {"success": False, "message": "API Key 无效，但端点可访问"}
        if code == 200 or 300 <= code < 400 or code in (404, 405):
            # 与 llm.py 连通性探测同口径（对抗审查 2026-10-23 二轮）：部分网关对
            # /models 做重定向或不实现该端点但 chat 可用，视为可用避免假阴性
            # （此前此处报失败、聊天侧却放行，口径漂移）。
            # 连接成功：清掉该 (base, key) 的探测缓存结论，让聊天/深度分析的
            # ensure_llm_ready 立即按新状态重新探测（对抗审查 2026-10-23：
            # 此前修好 Key 后要等负缓存过期才放行，最多等满 2 分钟）。
            _llm_svc.clear_probe_cache(base, key)
            if code == 200:
                return {"success": True, "message": "连接成功"}
            return {"success": True,
                    "message": f"连接成功（/models 返回 {code}：网关未实现该端点，但服务可达）"}
        return {"success": False, "message": f"服务器返回 {code}: {resp.text[:200]}"}
    except requests.RequestException:
        return {"success": False, "message": "无法连接到 API 地址，请检查网络"}
    except Exception as e:  # noqa: BLE001
        return {"success": False, "message": f"连接测试异常: {str(e)}"}
