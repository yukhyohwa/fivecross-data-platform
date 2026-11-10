"""三模型交叉验证分析核心（生成 → 验证 → 汇总），供聊天专项与订阅报告流水线复用。

产出事件（dict，由调用方序列化为 SSE）：
  stage    -> {"type": "stage", "stage", "message"}
  markdown -> {"type": "markdown", "stage": "generate"|"verify"|"final", "markdown"}
  error    -> {"type": "error", "message"}

generator 返回 (gen, ver, fin) 三段 markdown；生成轮失败时返回 (None, None, None)。
三个模型取自 report_config（生成/验证/汇总），调用方可用 cfg 覆盖。
"""
import threading
import time

from .llm import complete_with_fallback
from analysis.ai_client import CONNECT_TIMEOUT, DEEP_READ_TIMEOUT, INTERACTIVE_MAX_TOKENS, reasoning_off
from analysis.prompts import (
    build_generate_messages,
    build_summarize_messages,
    build_verify_final_messages,
    build_verify_messages,
)

from . import report_config


def _complete_report(model: str, messages: list[dict], user: dict | None = None, deep_thinking: bool = False):
    """报告三模型（生成/验证/汇总）统一 LLM 入口。

    - deep_thinking=False（默认，快速档）：关闭推理 + 16384 输出预算。报告是长文生成任务，
      不需要 deepseek 推理模型的 step-by-step 推导；开着推理会把 max_tokens 预算花在
      reasoning_content 上导致正文截断（finish_reason=length），且单轮生成耗时远超 300s。
    - deep_thinking=True（深度思考档）：保留推理（提高严谨度）+ 32768 输出预算（思考 + 正文
      都占 max_tokens）。若正文仍被截断，chat_completion 会按既有语义自动关推理重试一次，兜底不塌。

    两档读超时都放宽到 DEEP_READ_TIMEOUT（默认 900s）：实测关推理单轮最长 ~240s 已贴近
    300s 默认预算，网关负载波动时生成/验证轮多次 300s 读超时（2026-10-21/10-26 用户反馈，
    验证轮 deepseek-v4-pro read timeout≈300s）。报告是长文生成任务且有「⏳ 仍在等待」
    心跳进度，放宽值得；网关真挂死时最坏等一个 DEEP_READ_TIMEOUT 后按既有语义降级
    （验证轮失败回退生成轮结论，不丢最终报告）。

    超时/兜底仍走 complete_with_fallback 既有语义。
    """
    if deep_thinking:
        return complete_with_fallback(
            model, messages, user=user, max_tokens=INTERACTIVE_MAX_TOKENS,
            timeout=(CONNECT_TIMEOUT, DEEP_READ_TIMEOUT),
        )
    return complete_with_fallback(
        model, messages, user=user, max_tokens=16384, **reasoning_off(model),
        timeout=(CONNECT_TIMEOUT, DEEP_READ_TIMEOUT),
    )


def _await_with_heartbeat(fn, label, every=15.0):
    """在后台线程执行阻塞的 LLM 调用，主线程每 `every` 秒吐一条 progress 事件。

    背景：网关偶发挂起时，同步的 chat_completion 会一直阻塞到读超时（原先 600s），
    期间用户看不到任何进度、只能手动停。这里用守护线程跑调用、主线程边等边报时，
    让「卡住」至少能显示“仍在等待”，超时/兜底重试由下层照旧处理。

    用法：`result = yield from _await_with_heartbeat(lambda: chat_completion(...), "验证轮复核并定稿")`
    - 成功：`yield from` 返回调用结果（含元组等任意返回值）。
    - 失败：线程异常在主线程重抛，由调用方原有 try/except 处理，行为与直连一致。
    """
    box = {}

    def _run():
        try:
            box["result"] = fn()
        except Exception as exc:  # 把线程内异常传回主线程重抛，保持调用方 try/except 语义
            box["error"] = exc

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    n = 0
    while True:
        t.join(every)
        if not t.is_alive():
            break
        n += 1
        yield {"type": "progress", "message": f"⏳ {label}（{int(n * every)}s）…"}
    if "error" in box:
        raise box["error"]
    return box["result"]


def run_three_model(data_block, skill_texts, doc_texts, extra_prompt="", cfg=None,
                    structure=None, skip_summarize=False, user=None, deep_thinking=False):
    """三模型交叉验证（生成 → 验证 → 汇总）；有报告结构记忆时可用两轮模式省掉汇总。

    - structure：上次最终报告的小节骨架（标题列表），生成轮据此沿用结构（数字仍以本次数据为准）。
    - skip_summarize：True 时验证轮直接产出修正后的最终报告，跳过汇总轮（省 1 次生成模型调用）。
    """
    cfg = cfg or report_config.read_report_config()
    model_gen = cfg["model_gen"]
    model_ver = cfg["model_ver"]
    model_sum = cfg["model_sum"]

    # 生成轮（模型 A）
    yield {"type": "stage", "stage": "generate", "message": f"生成轮分析（{model_gen}）"}
    t0 = time.time()
    gen = None
    try:
        gen, used = yield from _await_with_heartbeat(
            lambda: _complete_report(model_gen, build_generate_messages(data_block, skill_texts, doc_texts, extra_prompt, structure), user, deep_thinking),
            "生成轮分析",
        )
        if used != model_gen:
            yield {"type": "stage", "stage": "generate",
                   "message": f"↩️ {model_gen} 未产出正文，已改用 {used} 生成"}
    except Exception as e:
        yield {"type": "stage", "stage": "generate", "message": f"❌ 生成轮失败：{e}"}
    if gen:
        yield {"type": "markdown", "stage": "generate", "markdown": gen}
    else:
        yield {"type": "error", "message": "生成轮失败，无法继续分析"}
        return None, None, None
    yield {"type": "stage", "stage": "generate", "message": f"生成轮完成（{time.time() - t0:.1f}s）"}

    # 验证轮（模型 B），失败自动用生成轮模型重试
    t0 = time.time()
    ver = None
    skipped_verify = False

    if skip_summarize:
        # 两轮模式：验证轮即定稿轮，直接产出修正后最终报告
        yield {"type": "stage", "stage": "verify", "message": f"验证轮复核并定稿（{model_ver}）"}
        build_verify = build_verify_final_messages
        try:
            ver, used = yield from _await_with_heartbeat(
                lambda: _complete_report(model_ver, build_verify(data_block, gen, skill_texts, doc_texts), user, deep_thinking),
                "验证轮复核并定稿",
            )
            if used != model_ver:
                yield {"type": "stage", "stage": "verify",
                       "message": f"↩️ {model_ver} 未产出正文，已改用 {used} 核验"}
        except Exception as e:
            yield {"type": "stage", "stage": "verify", "message": f"❌ 验证轮（{model_ver}）失败：{e}"}
        if not ver and model_ver != model_gen:
            yield {"type": "stage", "stage": "verify",
                   "message": f"↩️ 自动改用生成轮模型 {model_gen} 重试验证…"}
            try:
                ver, used = yield from _await_with_heartbeat(
                    lambda: _complete_report(model_gen, build_verify(data_block, gen, skill_texts, doc_texts), user, deep_thinking),
                    "验证轮复核并定稿",
                )
            except Exception as e:
                yield {"type": "stage", "stage": "verify", "message": f"❌ 重试（{model_gen}）也失败：{e}"}
    else:
        yield {"type": "stage", "stage": "verify", "message": f"验证轮核验（{model_ver}）"}
        try:
            ver, used = yield from _await_with_heartbeat(
                lambda: _complete_report(model_ver, build_verify_messages(data_block, gen, skill_texts, doc_texts), user, deep_thinking),
                "验证轮核验",
            )
            if used != model_ver:
                yield {"type": "stage", "stage": "verify",
                       "message": f"↩️ {model_ver} 未产出正文，已改用 {used} 核验"}
        except Exception as e:
            yield {"type": "stage", "stage": "verify", "message": f"❌ 验证轮（{model_ver}）失败：{e}"}
        if not ver and model_ver != model_gen:
            yield {"type": "stage", "stage": "verify",
                   "message": f"↩️ 自动改用生成轮模型 {model_gen} 重试验证…"}
            try:
                ver, used = yield from _await_with_heartbeat(
                    lambda: _complete_report(model_gen, build_verify_messages(data_block, gen, skill_texts, doc_texts), user, deep_thinking),
                    "验证轮核验",
                )
            except Exception as e:
                yield {"type": "stage", "stage": "verify", "message": f"❌ 重试（{model_gen}）也失败：{e}"}

    # 两轮模式：验证轮已直接产出最终报告，跳过汇总轮
    if skip_summarize:
        fin = ver if ver else gen
        if not ver:
            yield {"type": "stage", "stage": "verify",
                   "message": "⚠️ 验证定稿失败，已回退用生成轮报告作为最终报告"}
        yield {"type": "markdown", "stage": "final", "markdown": fin}
        yield {"type": "stage", "stage": "verify", "message": f"验证轮完成（{time.time() - t0:.1f}s）"}
        return gen, ver, fin

    if not skipped_verify:
        if ver:
            yield {"type": "markdown", "stage": "verify", "markdown": ver}
        else:
            yield {"type": "stage", "stage": "verify",
                   "message": "⚠️ 验证轮失败，最终报告将直接基于生成轮结论产出"}
    yield {"type": "stage", "stage": "verify", "message": f"验证轮完成（{time.time() - t0:.1f}s）"}

    # 汇总轮（模型 C）
    yield {"type": "stage", "stage": "summarize", "message": f"产出最终报告（{model_sum}）"}
    t0 = time.time()
    fin = None
    try:
        verify_text = ver if ver else gen
        fin, used = yield from _await_with_heartbeat(
            lambda: _complete_report(model_sum, build_summarize_messages(data_block, gen, verify_text, doc_texts, skill_texts), user, deep_thinking),
            "产出最终报告",
        )
        if used != model_sum:
            yield {"type": "stage", "stage": "summarize",
                   "message": f"↩️ {model_sum} 未产出正文，已改用 {used} 汇总"}
    except Exception as e:
        yield {"type": "stage", "stage": "summarize", "message": f"❌ 最终报告生成失败：{e}"}
    if not fin:
        # 汇总轮彻底失败：回退用生成轮报告作为最终报告，保证用户拿到完整内容而不是报错
        fin = gen
        yield {"type": "stage", "stage": "summarize",
               "message": "⚠️ 汇总轮未能产出，已回退用生成轮报告作为最终报告"}
    yield {"type": "markdown", "stage": "final", "markdown": fin}
    yield {"type": "stage", "stage": "summarize", "message": f"最终报告完成（{time.time() - t0:.1f}s）"}

    return gen, ver, fin
