"""个人 LLM 配置打通：把 per-user 的 key/model/api_base 透传到 ai_client。

规则（已与用户对齐）：
- api_key / api_base：有 user 且配了就用，否则回落全局 .env（ai_client 内部读环境变量）。
- model：仅主对话 / 深度分析任务（chat/agent，见 resolve_model_for_task）允许被 per-user 覆盖；
  其余生成任务（sql/kb/skill/model/report_gen/ver/sum/gap/split）按任务→模型映射
  config.task_model 统一选型，不经 resolve_model（这些路径只用 complete* 透传 key/base）。

user_agent_config 表（ide_data.db）建表默认 / 无行时 get_agent_config 返回的
「model=deepseek-chat、api_base=deepseek 直连」是 legacy 哨兵值，不是网关模型，
视为「未配置」回落全局，避免把直连 deepseek 的地址 + 网关模型混用。
"""
import hashlib
import itertools
import logging
import os
import threading
import time
from collections import OrderedDict

import requests as _requests

from analysis.ai_client import (
    BASE_URL,
    CONNECT_TIMEOUT,
    chat_completion,
    chat_completion_with_fallback,
    chat_completion_message,
    chat_completion_message_stream,
)

from .ide_bridge import db_service

_LEGACY_MODEL_SENTINEL = "deepseek-chat"
_LEGACY_BASE_SENTINEL = "https://api.deepseek.com/v1"


class LLMNotConfigured(Exception):
    """非管理员账号未配置个人 LLM API Key，禁止回落全局 .env，直接阻断 AI 功能。"""


def _is_admin(user: dict | None) -> bool:
    """是否允许回落系统默认 LLM：admin（有 system 权限点）或匿名回落。"""
    from backend.ide_app.services.permissions import has_perm
    return has_perm(user, "system")


def resolve_llm(user: dict | None) -> dict:
    """返回 {"api_key", "api_base", "model"}，未配置项为 None（表示回落全局）。

    权限规则（新增）：admin（含匿名回落）未配 Key 时回落系统默认；其他身份必须手填
    个人 API Key，否则抛 LLMNotConfigured，阻断所有 AI 功能。
    """
    uid = (user or {}).get("id")
    if not uid:
        # 匿名回落：视为系统默认（dev 模式不破坏现状）
        return {"api_key": None, "api_base": None, "model": None}
    try:
        cfg = db_service.get_agent_config(uid)
    except Exception:
        cfg = {}

    key = (cfg.get("api_key") or "").strip() or None
    if not key and not _is_admin(user):
        raise LLMNotConfigured(
            "当前账号身份未配置个人 LLM API Key，无法使用 AI 功能。"
            "请在右上角用户菜单 →「LLM 配置」中填写 API Key 后重试（仅管理员可回落系统默认 LLM）。"
        )

    base = (cfg.get("api_base") or "").strip()
    if not base or base == _LEGACY_BASE_SENTINEL:
        base = None
    model = (cfg.get("model") or "").strip()
    if not model or model == _LEGACY_MODEL_SENTINEL:
        model = None
    return {"api_key": key, "api_base": base, "model": model}


# ---- LLM 可用性前置检查（2026-10-23 用户反馈：先检 LLM 再弹确认卡）------------------
# resolve_llm 通过只说明「配了 Key」（admin/匿名未配时回落全局 .env），不代表 LLM 真能连通：
# 服务端无全局 Key、Key 失效或网关不可达时，聊天窗口仍会先弹「自由生成SQL」确认卡、
# 点确认后才报连接错误。这里在进入 AI 管线前做一次连通性探测（与 /api/agent/test-llm
# 同口径：GET {base}/models，短超时、禁重定向），结果按 (base, key) 缓存，避免每条消息
# 都打一次网关；探测失败直接抛 LLMNotConfigured，让错误在确认卡之前呈现。
#
# 对抗审查 2026-10-23 收口（探测闸门四连）：
# - 超时 8s→3s：每 TTL 窗口首条消息最多卡 8 秒（网关慢/抖动时假阴性硬阻断可用用户）；
#   可用 LITELLM_PROBE_TIMEOUT 环境变量调整，上限封顶连接超时（二轮）；
# - 3xx/404/405 视为可用（记日志）：部分网关对 /models 重定向到 /v1/models 或不实现该
#   端点但 chat 可用，此前一律判失败 → 假阴性硬阻断；
# - 失败负缓存 30s（成功 120s）：Key 修好后不用等满 2 分钟才放行；
# - 缓存 OrderedDict 上限 256 + 每键单飞锁：per-user (base, key) 组合无界增长 &
#   并发首问重复探测（探测走请求线程池，超时越长占用越久）。
# 二轮收口：条目带身份号（id），结论只写回探测发起时的条目——中途被 clear_probe_cache
# 或容量淘汰后重建的新条目不会被旧结论覆盖；过期条目重探前重新标记 in-flight（ok=None），
# 期间不可被容量淘汰。

_CONN_PROBE_TIMEOUT = 3.0
_CONN_OK_TTL = 120.0
_CONN_FAIL_TTL = 30.0
_CONN_CACHE_MAX = 256


def _resolve_probe_timeout() -> float:
    """探测超时：LITELLM_PROBE_TIMEOUT 环境变量可调（默认 3.0s），上限封顶在连接超时
    （探测整体不该比真实调用等得更久），非法值回落默认。"""
    raw = os.environ.get("LITELLM_PROBE_TIMEOUT", "").strip()
    try:
        t = float(raw) if raw else _CONN_PROBE_TIMEOUT
    except ValueError:
        t = _CONN_PROBE_TIMEOUT
    if t <= 0:
        t = _CONN_PROBE_TIMEOUT
    return min(t, CONNECT_TIMEOUT)
_PROBE_UNREACHABLE_MSG = ("无法连接到 LLM 服务，AI 功能暂时不可用"
                          "（请检查服务端网络/网关配置，稍后重试）。")
_PROBE_BAD_KEY_MSG = ("LLM API Key 无效（服务端可达但拒绝该 Key）。"
                      "请在「LLM 配置」中检查并更新 API Key。")

# (base, sha256(key)) -> {"ts": float, "ok": bool | None, "msg": str, "lock": threading.Lock,
#                        "id": int}
# ok=None 表示探测进行中：并发线程共享同一次探测（单飞），等锁后复用结论。
# id 是条目的唯一身份号（对抗审查 2026-10-23 二轮）：探测结论只写回探测发起时的那个条目，
# 条目中途被淘汰（clear_probe_cache/容量）后重建的新条目不被旧结论覆盖。
_conn_cache: "OrderedDict[tuple[str, str], dict]" = OrderedDict()
_conn_guard = threading.Lock()  # 保护 _conn_cache 结构（插入/淘汰/写结论），与单飞锁不同层
_conn_seq = itertools.count()  # 条目身份号来源
_log = logging.getLogger(__name__)


def _now() -> float:
    """当前时间戳（独立函数便于测试 monkeypatch 推进时钟）。"""
    return time.time()


def _cache_key(base: str, key: str) -> tuple[str, str]:
    """缓存键：base 归一化（去尾斜杠）+ key 全量 sha256（此前截断 12 位有碰撞风险）。"""
    return (base.rstrip("/"), hashlib.sha256(key.encode("utf-8")).hexdigest())


def _read_cache(cache_key) -> dict | None:
    """TTL 内命中返回结论条目并 LRU 触顶；过期返回 None（由持锁的探测方覆盖结论，
    不在此删除——避免与「探测进行中被覆盖」竞态）；探测中（ok=None）返回 None。"""
    now = _now()
    with _conn_guard:
        ent = _conn_cache.get(cache_key)
        if ent is None or ent["ok"] is None:
            return None
        ttl = _CONN_OK_TTL if ent["ok"] else _CONN_FAIL_TTL
        if now - ent["ts"] >= ttl:
            return None
        _conn_cache.move_to_end(cache_key)
        return ent


def _entry(cache_key) -> dict:
    """取/建缓存条目（含单飞锁），超容量时淘汰最旧的一条已出结论条目。"""
    with _conn_guard:
        ent = _conn_cache.get(cache_key)
        if ent is not None:
            _conn_cache.move_to_end(cache_key)
            return ent
        if len(_conn_cache) >= _CONN_CACHE_MAX:
            for k, e in list(_conn_cache.items()):
                if e["ok"] is not None:  # 不淘汰探测中的（其线程持单飞锁探测，结论将写回原条目）
                    del _conn_cache[k]
                    break
        ent = {"ts": 0.0, "ok": None, "msg": "", "lock": threading.Lock(), "id": next(_conn_seq)}
        _conn_cache[cache_key] = ent
        return ent


def _mark_inflight(cache_key, ent_id: int) -> None:
    """重新探测过期条目前把它标记回「探测中」（ok=None）：期间不可被容量淘汰
    （_entry 淘汰规则跳过 ok=None 条目），_read_cache 也不会把它当结论返回。"""
    with _conn_guard:
        ent = _conn_cache.get(cache_key)
        if ent is not None and ent.get("id") == ent_id:
            ent["ok"] = None


def _finish(cache_key, ent_id: int, ok: bool, msg: str) -> None:
    """探测结论写回缓存。ent_id 是探测发起时条目的身份号（对抗审查 2026-10-23 二轮）：
    探测期间条目若已被淘汰（clear_probe_cache/容量淘汰）并重建了新条目，本结论作废不写入
    ——否则旧探测（旧 Key）的结论会覆盖新条目，等待者可能拿到过期结论。"""
    with _conn_guard:
        ent = _conn_cache.get(cache_key)
        if ent is None or ent.get("id") != ent_id:
            return
        ent["ts"] = _now()
        ent["ok"] = ok
        ent["msg"] = msg or ""
        _conn_cache.move_to_end(cache_key)


def clear_probe_cache(base: str, key: str) -> None:
    """外部入口（/api/agent/test-llm 成功后）：清掉该 (base, key) 的缓存结论，
    下次 ensure_llm_ready 重新探测。归一化口径与 ensure_llm_ready 完全一致。"""
    with _conn_guard:
        _conn_cache.pop(_cache_key(base, key), None)


def _global_env_key() -> str:
    """服务端全局 LLM Key（.env），与 agent.py /test-llm 的回落顺序一致。"""
    return (
        os.environ.get("OPENAI_API_KEY")
        or os.environ.get("LITELLM_API_KEY")
        or os.environ.get("AI_API_KEY")
        or ""
    ).strip()


def _probe_llm(base: str, key: str) -> tuple[bool, str]:
    """连通性探测：返回 (是否可用, 失败提示文案；成功时文案为空)。"""
    try:
        resp = _requests.get(
            f"{base.rstrip('/')}/models",
            headers={"Authorization": f"Bearer {key}"},
            timeout=_resolve_probe_timeout(),
            allow_redirects=False,  # 禁跟随重定向（重定向型 SSRF，与全链路闸门口径一致）
        )
    except _requests.RequestException:
        return False, _PROBE_UNREACHABLE_MSG
    except Exception:  # noqa: BLE001 — 固定文案，不向用户泄漏异常细节
        return False, _PROBE_UNREACHABLE_MSG
    code = resp.status_code
    if code == 200:
        return True, ""
    if code in (401, 403):
        return False, _PROBE_BAD_KEY_MSG
    if 300 <= code < 400 or code in (404, 405):
        # 部分网关对 /models 做重定向或未实现该端点但 chat 可用：视为可用避免假阴性
        # 硬阻断（对抗审查 2026-10-23），但记日志供排查（如 302 指向 SSO 登录页）。
        _log.warning("llm probe: %s/models -> %s（视为可用）", base.rstrip("/"), code)
        return True, ""
    return False, (f"LLM 服务返回异常状态 {code}，AI 功能暂时不可用，请稍后重试。"
                   "（若持续出现请检查网关配置）")


def ensure_llm_ready(user: dict | None) -> dict:
    """LLM 前置闸门：确认「配了 Key 且服务可连通」才放行，否则抛 LLMNotConfigured。

    在 resolve_llm 通过后调用（resolve_llm 负责「非管理员必须配个人 Key」的权限规则）。
    连通性探测带缓存 + 单飞：同 (base, key) 的结论 TTL 内直接复用，并发首问共享一次探测。
    """
    llm = resolve_llm(user)
    key = llm.get("api_key") or _global_env_key()
    if not key:
        raise LLMNotConfigured(
            "系统未配置 LLM API Key（服务端 .env），且当前账号未配置个人 Key，无法使用 AI 功能。"
            "请在右上角用户菜单 →「LLM 配置」中填写 API Key，或联系管理员配置服务端密钥。"
        )
    base = (llm.get("api_base") or "").strip().rstrip("/") or BASE_URL.rstrip("/")
    cache_key = _cache_key(base, key)

    ent = _read_cache(cache_key)
    if ent is not None:
        if ent["ok"]:
            return llm
        raise LLMNotConfigured(ent["msg"])

    # 未命中/已过期/探测进行中 → 取单飞锁；等锁期间别的线程可能已完成探测，重读一次复用。
    entry = _entry(cache_key)
    with entry["lock"]:
        ent = _read_cache(cache_key)
        if ent is None:
            # 过期条目重新标记「探测中」：期间不可被容量淘汰，_read_cache 也不把它当结论。
            _mark_inflight(cache_key, entry["id"])
            ok, msg = _probe_llm(base, key)
            _finish(cache_key, entry["id"], ok, msg)
            ent = _read_cache(cache_key) or {"ok": ok, "msg": msg}
        if ent["ok"]:
            return llm
        raise LLMNotConfigured(ent["msg"])


def resolve_model(user: dict | None, default_model: str) -> str:
    """仅当用户显式配了模型时才覆盖 default_model；否则保持 default（系统选型）。"""
    model = resolve_llm(user).get("model")
    return model or default_model


def resolve_model_for_task(task: str, user: dict | None, explicit: str | None = None) -> str:
    """任务→模型单一入口（审计 P1-4）：生成端点统一走这里，替代各处 available_models()[0]/body.model 直取。

    优先级：
    1. 显式传参（body.model / 前端下拉），须在可用模型列表内（过滤无效/被拒模型）；
    2. per-user 个人配置（仅 chat/agent 对话类任务允许覆盖，见模块 docstring）；
    3. 任务默认（config.task_model(task)：模型管理 store > TASK_MODEL_<TASK> 环境变量 > 任务默认 > default_model，
       见 services/model_config.py 的 _resolve）。
    """
    from .. import config
    m = None
    if explicit:
        e = (explicit or "").strip()
        if e in config.available_models():
            m = e
    if m is None:
        if task in ("chat", "agent"):
            m = resolve_model(user, config.task_model(task))
        else:
            m = config.task_model(task)
    # P1-4 接线：按任务把固定 temperature（结构化 0 / 生成 0.3）注入 analysis 请求上下文，
    # ai_client.chat_completion* 在调用方未显式传 temperature 时应用；显式传值优先。
    # 每个生成入口都在发起 LLM 调用前经过本函数，注入值即本次任务的值（请求上下文内不跨请求泄漏）。
    _ai_client.set_task_temperature(config.task_temperature(task))
    return m


def inject_temperature(gen, task: str):
    """P1-4 流式补丁（对抗审查 HIGH）：SSE 同步生成器的每个步都跑在线程池，步间
    contextvars 从路由任务上下文重新复制（anyio run_sync 每步 copy_context，机制见
    routers/chat.py _usage_scope 注释），resolve_model_for_task 在首步注入的 ContextVar
    随该步销毁，后续步的 LLM 调用读不到温度。把生成器包一层：每步推进前先注入本任务
    固定温度，步内全部 LLM 调用都能读到；显式传 temperature 的调用仍优先。
    注意不能用 for 循环——for 先推进生成器再执行循环体，注入会晚于该步的 LLM 调用。
    """
    from .. import config
    temp = config.task_temperature(task)
    it = iter(gen)
    while True:
        _ai_client.set_task_temperature(temp)  # 先注入，再推进这一步
        try:
            chunk = next(it)
        except StopIteration:
            return
        yield chunk


def complete(model: str, messages: list[dict], user: dict | None = None, **kwargs) -> str:
    llm = resolve_llm(user)
    return chat_completion(model, messages, api_key=llm["api_key"], base_url=llm["api_base"], **kwargs)


def complete_with_fallback(model: str, messages: list[dict], user: dict | None = None, **kwargs):
    llm = resolve_llm(user)
    return chat_completion_with_fallback(model, messages, api_key=llm["api_key"], base_url=llm["api_base"], **kwargs)


def complete_message(model: str, messages: list[dict], user: dict | None = None, **kwargs) -> dict:
    llm = resolve_llm(user)
    return chat_completion_message(model, messages, api_key=llm["api_key"], base_url=llm["api_base"], **kwargs)


def complete_message_stream(model: str, messages: list[dict], user: dict | None = None, **kwargs):
    """流式完整 message 调用的 per-user 包装（深度分析 Agent 实时呈现用）：逐段 yield 事件
    （{"type":"content","delta"}…{"type":"done","content","tool_calls","finish_reason"}）。"""
    llm = resolve_llm(user)
    yield from chat_completion_message_stream(
        model, messages, api_key=llm["api_key"], base_url=llm["api_base"], **kwargs
    )


# 把 per-user 解析器注册回 analysis.ai_client：让 analysis 包内所有「直接」调用
# chat_completion* 的路径（analysis.sql_gen / analysis.kb_gen 等，不经本模块的 complete*）
# 也能按当前请求用户路由 key，而不是静默回落全局 .env（修复非管理员 token 走系统默认 key 的遗漏）。
from analysis import ai_client as _ai_client  # noqa: E402

_ai_client.set_user_llm_resolver(resolve_llm)
