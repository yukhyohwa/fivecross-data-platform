"""精简版 AI 调用封装，独立于 joytools，不引入跨子项目依赖。

复用公司内部 LiteLLM 网关的 OpenAI 兼容协议：POST {BASE_URL}/chat/completions。
"""
import json
import os
import time
from contextvars import ContextVar
from pathlib import Path

import requests
from dotenv import load_dotenv

from . import usage_tracker

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# —— per-user LLM 路由（data_ai 后端注入；streamlit 等共享场景不设置则回落全局 .env）——
# 让 analysis 包内所有直接调用 chat_completion* 的路径（sql_gen / kb_gen 等）也能按当前
# 用户路由到其个人 API Key，而非静默回落全局默认 key（非管理员未配 key 由 resolver 抛错阻断）。
_USER_CTX: ContextVar = ContextVar("analysis_current_user", default=None)
_USER_LLM_RESOLVER = None  # callable(user: dict) -> {"api_key","api_base",...}；非管理员未配 key 时抛异常
# 外部整轮预算（data_ai 聊天整轮看门狗探测期间注入）：每次 LLM HTTP 尝试前检查，到点立即抛错，
# 避免超时后的「探测 next(gen)」被下一步完整 LLM 调用静默阻塞（误差放大一个调用轮）。默认 None 不介入。
_EXTERNAL_DEADLINE: ContextVar = ContextVar("analysis_external_deadline", default=None)


def set_external_deadline(deadline: float | None) -> None:
    """设置/清除外部整轮预算（monotonic 秒值；None 清除）。供 chat.py 看门狗探测期间使用。
    返回 reset 用的 token，用后调用 reset_external_deadline(token) 恢复。"""
    return _EXTERNAL_DEADLINE.set(deadline)


def reset_external_deadline(token) -> None:
    _EXTERNAL_DEADLINE.reset(token)


def external_deadline() -> float | None:
    """读当前外部整轮预算（monotonic 秒值；未设置返回 None）。供非 LLM 的长链路
    （如 chat.py 的 Joydata 顺序取数）在各步之间检查，到点主动中断。"""
    return _EXTERNAL_DEADLINE.get()


def set_user_llm_resolver(resolver) -> None:
    """注册 per-user LLM 解析器（data_ai 后端启动时调用一次）。resolver(user) 返回
    {"api_key","api_base",...}，未配置项为 None 表示回落全局。"""
    global _USER_LLM_RESOLVER
    _USER_LLM_RESOLVER = resolver


def set_current_user(user: dict | None):
    """设置当前请求用户上下文（data_ai 后端每请求进入时调用）。传 None 清除。返回 reset 用的 token。"""
    return _USER_CTX.set(user)


def reset_current_user(token) -> None:
    _USER_CTX.reset(token)


def current_user() -> dict | None:
    """返回当前请求用户上下文（无上下文返回 None）。供「个人」层级资产按用户隔离时取归属键。"""
    return _USER_CTX.get()


def _user_llm_kwargs() -> tuple:
    """从用户上下文解析 per-user 的 api_key/base_url；无上下文/无解析器返回 (None, None)（回落全局 .env）。"""
    user = _USER_CTX.get()
    if not user:
        return None, None
    if _USER_LLM_RESOLVER is None:
        return None, None
    llm = _USER_LLM_RESOLVER(user)
    return llm.get("api_key"), llm.get("api_base")

BASE_URL = (
    os.environ.get("LITELLM_BASE_URL")
    or os.environ.get("OPENAI_BASE_URL")
    or "https://api.openai.com/v1"
)

MODELS = [
    # Anthropic
    "claude-opus-4-6",     # 旗舰
    "claude-haiku-4-5",    # 快速
    # OpenAI
    "gpt-5-5",             # 旗舰
    "gpt-5-mini",          # 快速
    # Google
    "gemini-3.1-pro",      # 旗舰
    "gemini-3-6-flash",    # 快速
    # DeepSeek
    "deepseek-v4-pro",     # 旗舰
    "deepseek-v4-flash",   # 快速
    # 智谱
    "glm-5-2",             # 旗舰
    "glm-flash-latest",    # 快速
]

# claude 系列经 LiteLLM 网关现在默认开启扩展思考，结构化输出任务会把 max_tokens 全花在
# 推导过程上、正文 content 为空（finish_reason=length）。对这些失败关思考重试最稳。
_THINKING_OFF = {"thinking": {"type": "disabled"}}
# deepseek 推理模型：`thinking` 参数对 deepseek 无效（网关忽略），关推理要用 reasoning_effort。
_REASONING_OFF = {"reasoning_effort": "none"}
# 兜底模型：与默认对话模型同档的 deepseek-v4-pro。
# （历史：claude-opus-4-6 经 Vertex 网关曾被 Anthropic 按项目级拒绝；deepseek-v4-flash 太弱，
# 静默降级到 flash 会拉低「改 SQL/改专项」质量，故兜底也用 pro，保证降级后能力不塌。）
# 可经 data_ai「系统管理 → 模型管理」（全局兜底槽位）动态调整：后端启动/保存时调
# set_fallback_model 同步；analysis 包独立使用时回落 _FALLBACK_MODEL 常量。
_FALLBACK_MODEL = "deepseek-v4-pro"
_FALLBACK_MODEL_OVERRIDE: str | None = None


def set_fallback_model(name: str | None) -> None:
    """设置全局兜底模型（None/空串恢复默认常量）。data_ai 后端启动与模型管理保存时调用。"""
    global _FALLBACK_MODEL_OVERRIDE
    _FALLBACK_MODEL_OVERRIDE = (name or "").strip() or None


def fallback_model() -> str:
    """当前生效的兜底模型名。"""
    return _FALLBACK_MODEL_OVERRIDE or _FALLBACK_MODEL
# 重试时给正文留的空间：data_ai 报告流水线用 16384 能稳定产出正文（思考不挤占正文）。
_RETRY_MAX_TOKENS = 16384
# 交互式「改 SQL / 改专项」路径的输出预算：保留推理 + 给足「思考 + 正文」空间，避免推理占满预算、
# 正文被截断（finish_reason=length）。这些路径频率低、用户盯着看、能容忍几秒延迟，故不关推理；
# 后台批量结构化任务（知识库/快照方案 JSON）仍走 reasoning_off。
INTERACTIVE_MAX_TOKENS = 32768
# 网关偶发挂起时不能无限等：连接超时快速失败；读取超时默认 300s（可经环境变量覆盖），
# 兼顾长报告生成（单次生成实测最长约 240s）与挂起兜底。READ_TIMEOUT 是「单次逻辑调用」的
# 读超时总预算：内部按 _TIMEOUT_RETRIES 重跑时共享同一预算（_call_with_shared_budget），
# 挂起场景下单次逻辑调用至多等一个 READ_TIMEOUT，而不是被放大成 (N+1)×；用尽后抛给
# chat_completion_with_fallback 换兜底模型（此时通常已无剩余预算，直接失败）。
CONNECT_TIMEOUT = float(os.environ.get("LITELLM_CONNECT_TIMEOUT", "60"))
READ_TIMEOUT = float(os.environ.get("LITELLM_READ_TIMEOUT", "300"))
# 深度思考（报告生成开推理）的放宽读超时：开推理单轮生成可到数百秒（实测关推理 ~34s vs
# 开推理 ~106s，真实长报告更长），300s 会把深度思考模式截断。默认放宽到 900s，可经环境变量覆盖。
DEEP_READ_TIMEOUT = float(os.environ.get("LITELLM_DEEP_READ_TIMEOUT", "900"))
# 网关读超时/连接失败的重跑次数：一次逻辑调用对同一模型最多额外重跑 N 次。
# 网关偶发挂起是瞬态的，重跑往往能成（生成轮超时正是要重跑的场景）；预算共享后代价最多是一个 READ_TIMEOUT。
_TIMEOUT_RETRIES = max(0, int(os.environ.get("LITELLM_TIMEOUT_RETRIES", "2")))
# 重跑之间的退避（秒），随次数递增，避免对挂起的网关密集重试。
_TIMEOUT_RETRY_BACKOFF = float(os.environ.get("LITELLM_TIMEOUT_RETRY_BACKOFF", "3"))

# —— 任务固定 temperature（审计 P1-4 接线）——
# data_ai 后端 resolve_model_for_task 按任务注入（结构化 0 / 生成 0.3，见 backend/config.task_temperature）；
# 未注入则回落网关默认。chat_completion* 仅在调用方未显式传 temperature 时应用。
_TASK_TEMPERATURE: ContextVar = ContextVar("analysis_task_temperature", default=None)


def set_task_temperature(value: float | None):
    """设置当前请求的任务 temperature（None 清除）。返回 reset 用的 token。"""
    return _TASK_TEMPERATURE.set(value)


def _is_claude(model: str) -> bool:
    return "claude" in (model or "").lower()


def _is_deepseek(model: str) -> bool:
    return "deepseek" in (model or "").lower()


def reasoning_off(model: str) -> dict:
    """按模型返回「禁用推理」的参数：claude=thinking disabled、deepseek=reasoning_effort none，其它空。

    结构化输出任务（生成 SQL / 专项 / 知识库 JSON）不需要模型长篇推理，且推理会把 max_tokens
    花光、正文被截断/为空；调用方展开 `**reasoning_off(model)` 主动关闭即可。
    """
    if _is_claude(model):
        return dict(_THINKING_OFF)
    if _is_deepseek(model):
        return dict(_REASONING_OFF)
    return {}


def _api_key() -> str:
    key = (
        os.environ.get("OPENAI_API_KEY")
        or os.environ.get("LITELLM_API_KEY")
        or os.environ.get("AI_API_KEY")
    )
    if not key:
        raise RuntimeError("缺少 OPENAI_API_KEY / LITELLM_API_KEY / AI_API_KEY 环境变量，用于调用大模型接口。")
    return key


def _attempt_timeout(timeout, remaining: float):
    """按剩余预算构造本次 HTTP 尝试的 timeout（保留原连接超时）。"""
    if isinstance(timeout, (tuple, list)):
        return (timeout[0], remaining)
    return remaining


def _call_with_shared_budget(request_fn, timeout):
    """同一逻辑调用内的多次 HTTP 尝试共享一个读超时预算：每次尝试只花剩余时间，
    单次逻辑调用总时长被 READ_TIMEOUT 封顶（审计·聊天优化块 C）。

    此前每次读超时重试都重新给满 300s，单次调用最坏被放大到 ~900s，叠加串行多调用后
    「300s 自动停」观感消失、专项能跑 1000+ 秒。现在：挂起场景下单次逻辑调用至多等
    一个 READ_TIMEOUT；重试只在预算内发生（网关偶发挂起是瞬态的，重跑往往能成）。
    """
    read_budget = float(timeout[1] if isinstance(timeout, (tuple, list)) else timeout)
    deadline = time.monotonic() + read_budget
    last_exc = None
    for attempt in range(_TIMEOUT_RETRIES + 1):
        # 对抗审查修复（round-2）：外部整轮预算到点即抛，不发起 HTTP（见 _EXTERNAL_DEADLINE 注释）
        ext_dl = _EXTERNAL_DEADLINE.get()
        if ext_dl is not None and time.monotonic() > ext_dl:
            raise RuntimeError("已超过总时长预算，停止后续调用")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            return request_fn(_attempt_timeout(timeout, remaining))
        except requests.exceptions.RequestException as exc:
            last_exc = exc
            if attempt >= _TIMEOUT_RETRIES:
                break
            time.sleep(_TIMEOUT_RETRY_BACKOFF * (attempt + 1))
    if last_exc is None:
        raise RuntimeError("读超时预算已用尽")
    raise last_exc


def _post_chat(api_key: str, model: str, messages: list[dict], call_kwargs: dict, timeout, base_url=None) -> dict:
    """POST 一次 /chat/completions，返回 choices[0]（含 message / finish_reason）。

    只做 HTTP 状态、JSON 解析、choices 结构校验与用量记录；正文是否为空/截断由调用方判断。
    base_url 为 None 时用全局 BASE_URL，否则用传入值（per-user 网关地址覆盖）。
    """
    url = base_url or BASE_URL
    resp = requests.post(
        f"{url}/chat/completions",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        json={"model": model, "messages": messages, **call_kwargs},
        timeout=timeout,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
    try:
        data = resp.json()
        choice = data["choices"][0]
    except Exception as exc:
        raise RuntimeError(f"解析返回失败：{exc}\n原始内容：{resp.text[:200]}") from exc
    # 对抗审查（snapshot-plan 轮）：网关在上游异常兜底/非 chat 格式透传时可能把
    # choices[0] / message 返回成非空字符串，下游 msg.get("content") 会打成
    # 'str' object has no attribute 'get'（正是用户报的「规划失败：…」文本来源）。
    # 统一在源头收口结构校验，把晦涩 AttributeError 换成可读 RuntimeError，
    # 上层（chat_completion 重试 / with_fallback 兜底）按既有语义处理。
    if not isinstance(choice, dict):
        raise RuntimeError(f"网关返回异常（choices[0] 非对象）：{str(choice)[:200]}")
    msg = choice.get("message")
    if msg is not None and not isinstance(msg, dict):
        raise RuntimeError(f"网关返回异常（message 非对象）：{str(msg)[:200]}")
    # 记录 token 用量（无累加器时 usage_tracker 自动忽略）
    usage_tracker.record(model, data.get("usage"))
    return choice


def chat_completion(model: str, messages: list[dict], api_key=None, base_url=None, **kwargs) -> str:
    # per-user 路由：显式 api_key/base_url 优先；否则从请求用户上下文解析个人 key/base（无则回落全局）。
    if api_key is None or base_url is None:
        ctx_key, ctx_base = _user_llm_kwargs()
        if api_key is None:
            api_key = ctx_key
        if base_url is None:
            base_url = ctx_base
    api_key = api_key or _api_key()
    timeout = kwargs.pop("timeout", (CONNECT_TIMEOUT, READ_TIMEOUT))
    # P1-4：调用方未显式传 temperature 时，应用任务上下文注入的固定值（结构化 0 / 生成 0.3）
    if "temperature" not in kwargs:
        t = _TASK_TEMPERATURE.get()
        if t is not None:
            kwargs["temperature"] = t

    def _request(call_kwargs: dict, req_timeout) -> str:
        choice = _post_chat(api_key, model, messages, call_kwargs, req_timeout, base_url)
        msg = choice.get("message") or {}
        # 思考型模型（deepseek-v4-pro 等）会同时返回 reasoning_content（推导过程）和 content（正文）。
        # 正文只在 content；reasoning_content 是模型的内部思考，绝不能当作答案返回。
        content = msg.get("content")
        if content is None or not str(content).strip():
            # content 为空：通常是思考型模型把 max_tokens 全花在推导上、没生成正文。
            # 这里报错让上层按需重试/回退，而不是把推导过程当答案吐给用户。
            raise RuntimeError(
                f"模型 {model} 未返回正文（content 为空，可能是推导过程占满了 max_tokens）。"
                f"原始返回：{str(choice)[:300]}"
            )
        finish_reason = choice.get("finish_reason", "")
        if finish_reason == "length":
            # 输出被 max_tokens 截断（finish_reason=length）：正文不完整，同样不能当完整答案用，
            # 让上层按需重试/回退，避免把半截报告当最终结果。
            raise RuntimeError(
                f"模型 {model} 输出被截断（finish_reason=length，正文不完整，可能是推导过程占满了 max_tokens）。"
                f"原始返回：{str(choice)[:300]}"
            )
        return content

    # 单次逻辑调用（含超时重跑 + 关思考重试）的总读预算封顶一个 READ_TIMEOUT：
    # 此前每次重跑重新给满预算，挂起时单次调用最坏被放大到 ~900s；现在 deadline 贯穿始终。
    read_budget = float(timeout[1] if isinstance(timeout, (tuple, list)) else timeout)
    deadline = time.monotonic() + read_budget
    try:
        return _call_with_shared_budget(lambda t: _request(kwargs, t), timeout)
    except requests.exceptions.RequestException:
        # 读超时重跑已用尽（共享预算封顶一个 READ_TIMEOUT），抛给 chat_completion_with_fallback 换兜底模型。
        raise
    except Exception as exc:
        # 思考型模型（claude 扩展思考 / deepseek 推理）可能把 max_tokens 全花在推导上、
        # 正文为空或被截断。重试一次：claude 关思考 + 统一放大 max_tokens 给正文留空间。
        # 若调用方已显式传 thinking（自定义思考预算），则尊重其选择、不再关思考。
        retry_kwargs = dict(kwargs)
        ro = reasoning_off(model)
        if ro and not any(k in kwargs for k in ro):
            retry_kwargs.update(ro)
        mt = retry_kwargs.get("max_tokens")
        # max_tokens 未显式传时，网关按自身默认给一个偏小的预算，思考型模型（deepseek 推理）
        # 很容易把默认预算全花在推导上、正文被截断（finish_reason=length）。这里统一放大到
        # 经验值 16384，给正文留足空间；已显式传但偏小（< 16384）的同样放大。
        if mt is None or (isinstance(mt, int) and mt < _RETRY_MAX_TOKENS):
            retry_kwargs["max_tokens"] = _RETRY_MAX_TOKENS
        if retry_kwargs == kwargs:
            raise exc  # 重试参数无变化（非思考型且 max_tokens 已够大），避免无效重试
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise exc  # 预算已用尽，不再给关思考重试完整预算
        return _call_with_shared_budget(lambda t: _request(retry_kwargs, t), (CONNECT_TIMEOUT, remaining))


def chat_completion_message(model: str, messages: list[dict], tools=None, tool_choice=None, api_key=None, base_url=None, **kwargs) -> dict:
    """调用一次 /chat/completions，返回完整 message dict（含 content 与 tool_calls）。

    供 agentic function-calling 循环使用：工具调用轮 content 为空是正常的（模型只回 tool_calls），
    因此这里不校验 content 非空；仅当既无 content 也无 tool_calls 时抛错（模型未给出任何可执行输出）。

    连接/读超时按 _TIMEOUT_RETRIES 同参重跑、共享同一读预算（与 chat_completion 一致）；「正文与 tool_calls 均空」
    （思考型模型把 max_tokens 全花在推导上）同样关思考 + 放大 max_tokens 重试一次；不自动换兜底模型，
    是否回退由上层循环决定。
    """
    if api_key is None or base_url is None:
        ctx_key, ctx_base = _user_llm_kwargs()
        if api_key is None:
            api_key = ctx_key
        if base_url is None:
            base_url = ctx_base
    api_key = api_key or _api_key()
    timeout = kwargs.pop("timeout", (CONNECT_TIMEOUT, READ_TIMEOUT))
    # P1-4：与 chat_completion 同口径——未显式传 temperature 时应用任务上下文注入的固定值
    if "temperature" not in kwargs:
        t = _TASK_TEMPERATURE.get()
        if t is not None:
            kwargs["temperature"] = t
    if tools is not None:
        kwargs["tools"] = tools
    if tool_choice is not None:
        kwargs["tool_choice"] = tool_choice

    def _request(call_kwargs: dict, req_timeout) -> dict:
        choice = _post_chat(api_key, model, messages, call_kwargs, req_timeout, base_url)
        msg = choice.get("message") or {}
        content = msg.get("content")
        tool_calls = msg.get("tool_calls")
        if (content is None or not str(content).strip()) and not tool_calls:
            raise RuntimeError(
                f"模型 {model} 未返回正文或工具调用（content 与 tool_calls 均为空）。"
                f"原始返回：{str(choice)[:300]}"
            )
        # 对抗审查修复（round-2）：兜底路径（agent_deep 主模型失败后换兜底模型重试走这里）此前
        # 不校验 finish_reason——兜底模型用同一 prompt、同一输出预算，同样可能被 max_tokens 截断，
        # 半截答案会静默当作完整答案交付。与 chat_completion 同口径：纯答案轮截断即抛错。
        # 但工具轮（tool_calls 非空）截断保留自愈路径：半截 arguments 会被 _parse_args 降级为 {}，
        # 工具报错回填会话、下一轮模型修正后通常收敛；此处抛错会把可自愈场景升级为整场失败（复验 R1）。
        if choice.get("finish_reason") == "length" and not tool_calls:
            raise RuntimeError(
                f"模型 {model} 输出被截断（finish_reason=length），本轮结果不完整，已放弃。"
                f"原始返回：{str(choice)[:300]}"
            )
        return msg

    # 单次逻辑调用（含超时重跑 + 关思考重试）的总读预算封顶一个 READ_TIMEOUT（与 chat_completion 同口径）。
    read_budget = float(timeout[1] if isinstance(timeout, (tuple, list)) else timeout)
    deadline = time.monotonic() + read_budget
    try:
        return _call_with_shared_budget(lambda t: _request(kwargs, t), timeout)
    except requests.exceptions.RequestException:
        # 读超时重跑已用尽（共享预算封顶一个 READ_TIMEOUT），抛给上层循环决定换模型/换配置。
        raise
    except Exception as exc:
        # 思考型模型可能把 max_tokens 全花在推导上，正文与 tool_calls 均空。
        # 重试一次：claude 关思考 + 统一放大 max_tokens 给输出留空间（与 chat_completion 同口径）。
        # 若调用方已显式传 thinking，则尊重其选择、不再关思考。
        retry_kwargs = dict(kwargs)
        ro = reasoning_off(model)
        if ro and not any(k in kwargs for k in ro):
            retry_kwargs.update(ro)
        mt = retry_kwargs.get("max_tokens")
        if mt is None or (isinstance(mt, int) and mt < _RETRY_MAX_TOKENS):
            retry_kwargs["max_tokens"] = _RETRY_MAX_TOKENS
        if retry_kwargs == kwargs:
            raise exc  # 重试参数无变化（非思考型且 max_tokens 已够大），避免无效重试
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise exc  # 预算已用尽，不再给关思考重试完整预算
        return _call_with_shared_budget(lambda t: _request(retry_kwargs, t), (CONNECT_TIMEOUT, remaining))


def chat_completion_message_stream(model: str, messages: list[dict], tools=None, tool_choice=None, api_key=None, base_url=None, **kwargs):
    """流式调用一次 /chat/completions（stream=True），逐段产出事件（生成器），供深度分析 Agent 实时呈现。

    产出事件（dict）：
      {"type": "content", "delta": str}   正文增量（推理内容 reasoning_content 不吐，只吐正文 content）
      {"type": "done", "content": str, "tool_calls": list|None, "finish_reason": str}   流正常结束，仅一条

    tool_calls 在 SSE 流中按 index 分片返回，这里按 index 累积成完整调用（id/name/arguments 拼接）。
    连接/读超时共享同一 READ_TIMEOUT 预算（与 chat_completion 同口径）；仅在尚未产出任何增量前允许
    整体重跑（重跑会从头再来，产出过增量就绝不能重试，否则调用方会看到重复内容）。
    流结束后若 content 与 tool_calls 均空则抛错（模型未给出任何可执行输出）。
    """
    if api_key is None or base_url is None:
        ctx_key, ctx_base = _user_llm_kwargs()
        if api_key is None:
            api_key = ctx_key
        if base_url is None:
            base_url = ctx_base
    api_key = api_key or _api_key()
    timeout = kwargs.pop("timeout", (CONNECT_TIMEOUT, READ_TIMEOUT))
    # P1-4：与 chat_completion 同口径——未显式传 temperature 时应用任务上下文注入的固定值
    if "temperature" not in kwargs:
        t = _TASK_TEMPERATURE.get()
        if t is not None:
            kwargs["temperature"] = t
    if tools is not None:
        kwargs["tools"] = tools
    if tool_choice is not None:
        kwargs["tool_choice"] = tool_choice

    url = base_url or BASE_URL
    payload = {"model": model, "messages": messages, "stream": True, **kwargs}

    read_budget = float(timeout[1] if isinstance(timeout, (tuple, list)) else timeout)
    deadline = time.monotonic() + read_budget
    emitted = False  # 是否已向调用方产出过增量（产出后不再重试，避免重复输出）
    last_exc = None
    resp = None
    for attempt in range(_TIMEOUT_RETRIES + 1):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            resp = requests.post(
                f"{url}/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
                timeout=_attempt_timeout(timeout, remaining),
                stream=True,
            )
            if resp.status_code != 200:
                raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
            usage = None
            content_parts: list[str] = []
            tool_parts: dict[int, dict] = {}  # index -> {"id","name","arguments"}
            finish_reason = ""
            # 网关流式响应 Content-Type 是 text/event-stream 且不带 charset，requests 按
            # RFC 规则把 encoding 定为 ISO-8859-1 —— decode_unicode=True 会把 UTF-8 中文
            # 字节解成乱码（非流式 application/json 默认 utf-8，故只有流式路径中招）。
            # 显式按 UTF-8 解码原始字节，不信任响应的 charset 声明。
            for raw_line in resp.iter_lines(decode_unicode=False):
                if not raw_line:
                    continue
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[len("data:"):].strip()
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                except Exception:
                    continue  # 忽略无法解析的行（网关偶发的空 chunk/心跳）
                if chunk.get("error"):
                    raise RuntimeError(f"网关返回错误：{str(chunk['error'])[:200]}")
                if isinstance(chunk.get("usage"), dict):
                    usage = chunk["usage"]  # LiteLLM 流末尾块可能夹带 usage，取最后一次
                choices = chunk.get("choices") or []
                if not choices:
                    continue
                choice = choices[0]
                # 对抗审查（snapshot-plan 轮）：与 _post_chat 同口径——流式块里 choices[0] /
                # delta 也可能被网关兜底成字符串，直接 .get 会抛晦涩 AttributeError。
                if not isinstance(choice, dict):
                    raise RuntimeError(f"网关流式返回异常（choices[0] 非对象）：{str(choice)[:200]}")
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]
                delta = choice.get("delta") or {}
                if not isinstance(delta, dict):
                    raise RuntimeError(f"网关流式返回异常（delta 非对象）：{str(delta)[:200]}")
                content = delta.get("content")
                if isinstance(content, str) and content:
                    content_parts.append(content)
                    emitted = True
                    yield {"type": "content", "delta": content}
                for tc in delta.get("tool_calls") or []:
                    idx = int(tc.get("index", 0))
                    slot = tool_parts.setdefault(idx, {"id": None, "name": "", "arguments": ""})
                    if tc.get("id"):
                        slot["id"] = tc["id"]
                    fn = tc.get("function") or {}
                    if fn.get("name"):
                        slot["name"] += fn["name"]
                    if fn.get("arguments"):
                        slot["arguments"] += fn["arguments"]
            if usage:
                usage_tracker.record(model, usage)
            content = "".join(content_parts)
            tool_calls = None
            if tool_parts:
                tool_calls = [
                    {
                        "id": slot["id"],
                        "type": "function",
                        "function": {"name": slot["name"], "arguments": slot["arguments"]},
                    }
                    for _, slot in sorted(tool_parts.items())
                ]
            if not content and not tool_calls:
                raise RuntimeError(
                    f"模型 {model} 未返回正文或工具调用（content 与 tool_calls 均为空）。"
                )
            # 对抗审查修复：输出被长度截断（finish_reason=length）此前被当成功返回，半截答案
            # 会静默呈现为最终结论。这里显式抛错：已流出的增量由调用方（agent_deep）经
            # answer_cancel 清掉后走兜底模型重试，重试预算耗尽则转为可见报错。
            if finish_reason == "length":
                raise RuntimeError(
                    f"模型 {model} 输出被截断（finish_reason=length），本轮结果不完整，已放弃"
                )
            yield {"type": "done", "content": content, "tool_calls": tool_calls, "finish_reason": finish_reason}
            return
        except requests.exceptions.RequestException as exc:
            last_exc = exc
            if emitted or attempt >= _TIMEOUT_RETRIES:
                break  # 已产出增量（不能重试）或重试次数已尽
            time.sleep(_TIMEOUT_RETRY_BACKOFF * (attempt + 1))
            continue
        finally:
            if resp is not None:
                try:
                    resp.close()
                except Exception:
                    pass
    if last_exc is None:
        raise RuntimeError("读超时预算已用尽")
    raise last_exc


def chat_completion_with_fallback(model: str, messages: list[dict], api_key=None, base_url=None, **kwargs):
    """调用 chat_completion；失败时换兜底模型重试一次。

    （chat_completion 内部已对「正文为空/被截断」自动关思考重试，这里只兜底其它失败，
    如 HTTP 错误、解析失败、读超时等。）

    兜底模型与主模型共享同一 READ_TIMEOUT 预算：主模型若已耗尽读超时（网关挂起），
    不再给兜底完整预算，一次调用最多等一个 READ_TIMEOUT，而不是被放大成多倍。

    返回 (正文, 实际用的模型)。兜底模型也失败时抛异常。
    """
    # 兜底预算与主模型实际读超时一致：调用方可能传了自定义 timeout（(connect, read) 或标量），
    # 此时 deadline 应取该 read 而非全局 READ_TIMEOUT，否则主模型用自定义超时、兜底却按全局算，预算不一致。
    req_timeout = kwargs.get("timeout")
    if isinstance(req_timeout, (tuple, list)) and len(req_timeout) >= 2:
        budget = float(req_timeout[1])
    elif isinstance(req_timeout, (int, float)):
        budget = float(req_timeout)
    else:
        budget = READ_TIMEOUT
    deadline = time.monotonic() + budget
    try:
        return chat_completion(model, messages, api_key=api_key, base_url=base_url, **kwargs), model
    except Exception:
        fb = fallback_model()  # 单次求值：避免与模型管理保存的并发竞态导致判等/调用/记账用不同值
        if model == fb:
            raise
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise
        fb_kwargs = dict(kwargs)
        fb_kwargs["timeout"] = (CONNECT_TIMEOUT, remaining)
        return chat_completion(fb, messages, api_key=api_key, base_url=base_url, **fb_kwargs), fb


def structured_json(model: str, system: str, user_content: str, api_key=None, base_url=None, **kwargs) -> str:
    """结构化 JSON 抽取统一入口：带兜底模型 + 16384 输出预算 + 关闭推理（思考）。

    后台批量结构化任务（知识库/快照方案 JSON 等）统一走这里，避免各处裸调 chat_completion
    时「推理占满 max_tokens、正文为空/截断」且无兜底。messages 固定为 [system, user] 两条，
    其余参数经 kwargs 透传（默认 max_tokens=_RETRY_MAX_TOKENS）；失败自动换兜底模型重试一次。
    返回模型正文文本，JSON 解析由调用方负责。
    """
    content, _ = chat_completion_with_fallback(
        model,
        [
            {"role": "system", "content": system},
            {"role": "user", "content": user_content},
        ],
        api_key=api_key,
        base_url=base_url,
        max_tokens=kwargs.pop("max_tokens", _RETRY_MAX_TOKENS),
        **reasoning_off(model),
        **kwargs,
    )
    return content
