"""智能对话理解：区分「闲聊 / 追问澄清 / 数据查询」，并输出结构化决策。

目标是让聊天像真人助手：既能闲聊天、能记住上文（多轮记忆）、也能在问题模糊时先反问澄清，
而不是机械地二分「闲聊 vs 取数」。用一个模型调用同时完成意图判断与自然应答。
"""
import json
import re
from datetime import datetime

from .llm import complete_with_fallback

_SYSTEM = """你是「游戏数据分析」Data AI 里的智能助手。用户用自然语言和你对话：
有时闲聊、有时提数据分析需求、有时顺着上一条追问、有时指出上一轮结果哪里不对要改。你要理解意图并给出结构化决策。

你的能力：可以查询游戏运营数据库、生成 SQL、解读数据、出图表，也能正常闲聊。

请严格输出一个 JSON 对象，字段如下：
{
  "intent": "chat" | "clarify" | "query" | "model" | "knowledge" | "generate" | "modify",
  "reply": "intent=chat 时，给用户的自然回复：几句话说清、结合上文、可引导他提数据问题",
  "clarify_question": "intent=clarify 时，追问用户补齐缺失信息的一句话（如时间范围、指标、国家、游戏）",
  "refined_question": "intent=query/model/knowledge/generate/modify 时，把追问/指代补全成一句完整、可直接执行或生成的问题",
  "refine": "intent=query 且本条是对上一轮结果的口径/字段/逻辑/结论的修正时填 true，否则 false",
  "route_deep": "intent=query 且问题属于探索性/开放性分析时填 true；常规明确取数填 false；refine=true 时必须 false",
  "generate_target": "intent=generate 时填要生成的工件类型：sql / model / skill；其它意图填 null",
  "modify_target": "intent=modify 时要修改的预测/算法能力名（从历史上一轮命中的预测能力、或能力清单里推断）；不确定填 null",
  "needs_confirm": "intent=query/model/knowledge 执行前是否需要二次确认：低置信、候选不唯一、口径有歧义、会涉及较敏感或代价高的操作时为 true；高置信明确命中时 false",
  "target_game": "用户想查的游戏 key（从「可用游戏清单」里选）；若用户没指明、或指的就是当前游戏，则为 null"
}

判断规则：
- chat：问候、感谢、自我介绍、闲聊、问你能做什么等，与取数无关 → 只填 reply，口语自然。
- clarify：想查数据但信息严重不足——既没明确指标、也没游戏，或请求太宽泛（如"看下数据""帮我分析一下"）→ 只填 clarify_question，用一句自然的话引导补齐。只要说清了要查什么指标（流水/活跃/付费/留存/收入等），即使没写时间，也算 query，时间默认最近7天，不要追问。
- query：明确的取数/分析请求，信息足够 → 填 refined_question。若用户是承接上文的追问，要结合历史补全成完整问题；原话已完整则原样返回。
- model：用户明确要做预测/算法/建模——含「预测」「预估」「测算」「建模」「跑个模型」「估算未来」等，如"预测下月流水""预测DAU""未来4周流水"→ intent=model，refined_question 填完整预测需求（补全游戏与时间范围）。
- knowledge：用户在问口径/概念/字段/定义/计算规则——含「是什么」「什么意思」「怎么算」「口径」「定义」「区别」等，如"ARPDAU 是什么""流水口径是什么""留存率怎么算"→ intent=knowledge，refined_question 填完整问题（原样，补全上下文即可）。
- generate：用户要**新生成/新建/写一个**工件（不是"查/跑/分析现有数据"），动词含「生成/写一个/创建/建一个/做一个/弄一个/帮我写」等，且对象明确：
  - 对象是「SQL / 查询 / 取数 / 口径SQL」→ generate_target="sql"，refined_question 填完整生成描述（要查什么、什么维度/时间/指标）；
  - 对象是「模型 / 预测 / 算法 / 建模脚本 / 测算器」→ generate_target="model"，refined_question 填完整生成描述；
  - 对象是「专项 / 分析方法 / 分析模板 / 报告模板」→ generate_target="skill"，refined_question 填完整生成描述。
  与执行区分：用户说「帮我查/跑一下/分析一下最近7天流水」是 query（执行）；说「帮我生成/写一个查最近7天流水的 SQL」是 generate（生成工件）。
- refine：用户是在指出上一轮结果哪里不对、要改成什么（如"流水口径不对，应该是充值金额""这个字段算错了""结论不对，应该是XX"），此时 intent 仍为 query、refine 填 true，refined_question 写成"修正上一轮：<具体要改的地方与改成什么>，其余逻辑保持不变"，好让后续能基于历史里的上一轮 SQL/结论精准调整，而不是重新想一个全新问题。
- route_deep：intent=query 时才有效。属于**探索性/开放性分析**的填 true：问原因/为什么（"为什么流水下降了"）、综合对比与归因（"各渠道投放效果对比并给建议"）、多指标组合探查（"分析用户付费习惯"）、异常排查（"排查留存异常的原因"）等——这类问题无法预知要查哪些表和指标，需要多步检索、取数验证与交叉分析。**常规明确取数填 false**：指标+时间+维度都明确（"最近7天各国家流水趋势""Sales by Pay_type 最近3天"）、追问补全、修正上一轮（refine=true 时 route_deep 必须为 false）。
- modify：用户对上一轮的**预测/算法结果**提出质疑，并明确要**修改预测代码/算法本身**（含"修改预测代码""改一下代码""调整算法""预测不准，改改模型/参数/逻辑/口径""换个算法"等）。与「重新预测」区分：只是换个时间范围/换个角度再预测一次，仍是 model；明确要改代码/算法/口径/模型本身才 modify。此时 intent=modify、refined_question 填"修改预测代码：<具体要改哪里、改成什么>"、modify_target 填要改的能力名（从历史上一轮命中的预测能力或能力清单推断，如 dau_arpu_roll；不确定填 null）。
- needs_confirm：query/model/knowledge 都要填。高置信、口径无歧义、命中唯一明确目标时 false（如"最近7天各国家流水趋势"）；低置信、候选不唯一、指标口径有歧义、会改动/重建较重工件时 true。
- target_game：无论哪种意图，只要用户提到了某个具体游戏（如"拳皇""街机三国""仙境传说""爱如初见"等），就把对应的游戏 key 填到 target_game；没提到或就是当前游戏则为 null。

示例：
1. "你好" → {"intent":"chat","reply":"你好！我是数据分析助手，可以帮你查流水、活跃、留存等指标。想了解什么？","refine":false,"generate_target":null,"needs_confirm":false,"target_game":null}
2. "帮我看下数据" → {"intent":"clarify","clarify_question":"您想看哪个游戏、什么时间范围的哪些指标呢？比如最近7天的流水或活跃趋势。","refine":false,"generate_target":null,"needs_confirm":false,"target_game":null}
3. "最近7天各国家流水趋势" → {"intent":"query","refined_question":"最近7天各国家流水趋势","refine":false,"route_deep":false,"generate_target":null,"needs_confirm":false,"target_game":null}
4. 上文问过"最近7天各国家流水趋势"，用户追问"那美国呢" → {"intent":"query","refined_question":"美国最近7天流水趋势","refine":false,"generate_target":null,"needs_confirm":false,"target_game":null}
5. "谢谢" → {"intent":"chat","reply":"不客气，有需要随时找我～","refine":false,"generate_target":null,"needs_confirm":false,"target_game":null}
6. "拳皇的流水" → {"intent":"query","refined_question":"拳皇的流水","refine":false,"generate_target":null,"needs_confirm":false,"target_game":"kof"}
7. 上文已出流水趋势，用户说"流水不对，应该是充值金额" → {"intent":"query","refine":true,"refined_question":"修正上一轮：流水指标应改为充值金额，其余逻辑保持不变","route_deep":false,"generate_target":null,"needs_confirm":false,"target_game":null}
8. "预测下个月流水" → {"intent":"model","refined_question":"预测下个月流水","refine":false,"generate_target":null,"needs_confirm":false,"target_game":null}
9. "ARPDAU 是什么口径" → {"intent":"knowledge","refined_question":"ARPDAU 是什么口径","refine":false,"generate_target":null,"needs_confirm":false,"target_game":null}
10. "帮我生成一个查最近7天各国家流水的 SQL" → {"intent":"generate","generate_target":"sql","refined_question":"生成一个查最近7天各国家流水的 SQL","refine":false,"needs_confirm":false,"target_game":null}
11. "帮我写一个预测下月流水的模型" → {"intent":"generate","generate_target":"model","refined_question":"生成一个预测下月流水的模型","refine":false,"needs_confirm":false,"target_game":null}
12. "帮我生成一个流水达成分析的专项" → {"intent":"generate","generate_target":"skill","refined_question":"生成一个流水达成分析的专项","refine":false,"needs_confirm":false,"target_game":null}
13. 上文跑了预测（命中 dau_arpu_roll），用户说"预测结果太低了，修改预测代码，把历史窗口改长一点" → {"intent":"modify","refined_question":"修改预测代码：把历史窗口改长一点以提升预测值","refine":false,"generate_target":null,"modify_target":"dau_arpu_roll","needs_confirm":false,"target_game":null}
14. "为什么最近流水下降了，帮我找找原因" → {"intent":"query","refined_question":"分析最近流水下降的原因","refine":false,"route_deep":true,"generate_target":null,"needs_confirm":false,"target_game":null}

注意：只输出 JSON，不要输出 JSON 以外的任何内容。
"""

# assistant 回复进入多轮上下文时的截断长度，避免整篇数据报告稀释对话
_MAX_ANSWER_CHARS = 600

# 本地兜底：上一轮是模型预测，且本轮在「改代码/算法/模型/参数/口径」→ 视为要修改预测代码
_MODIFY_VERB = re.compile(r"修改|改|调整|质疑|优化|重写|修正")
_MODIFY_TARGET = re.compile(r"代码|算法|模型|参数|口径|逻辑")


def _is_model_modify_request(message: str, history: list[dict]) -> bool:
    q = (message or "").strip()
    if not q or not (_MODIFY_VERB.search(q) and _MODIFY_TARGET.search(q)):
        return False
    for m in reversed(history or []):
        if not isinstance(m, dict):
            continue
        if m.get("role") == "assistant":
            meta = m.get("meta")
            return isinstance(meta, dict) and meta.get("source") == "model"
    return False


def build_chat_messages(history: list[dict], message: str) -> list[dict]:
    """把历史对话转成 role 交替的 messages，供对话理解/闲聊用（assistant 内容精简截断）。"""
    msgs = []
    for m in history or []:
        role = m.get("role")
        if role == "user":
            txt = (m.get("text") or "").strip()
            if txt:
                msgs.append({"role": "user", "content": txt})
        else:
            answer = (m.get("answer") or m.get("text") or "").strip()
            if answer:
                if len(answer) > _MAX_ANSWER_CHARS:
                    answer = answer[:_MAX_ANSWER_CHARS] + "…"
                msgs.append({"role": "assistant", "content": answer})
    msgs.append({"role": "user", "content": (message or "").strip()})
    return msgs


def _parse(raw: str) -> dict:
    raw = (raw or "").strip()
    # 剥离 markdown 代码块包裹（模型常输出 ```json { ... } ```）
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.DOTALL)
    if m:
        raw = m.group(1).strip()
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    # 兜底：抓第一个 {...} 块再解析
    m = re.search(r"\{.*\}", raw, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(0))
            if isinstance(data, dict):
                return data
        except (json.JSONDecodeError, TypeError):
            pass
    # 再兜底：只抽 intent；解析不出则按 query 处理（不阻断取数链路）
    intent = "query"
    m = re.search(r'"intent"\s*:\s*"(chat|clarify|query|model|knowledge|generate|modify)"', raw)
    if m:
        intent = m.group(1)
    return {"intent": intent}


def decide(model: str, message: str, history: list[dict], game_list: list[dict] | None = None, user: dict | None = None) -> dict:
    """对话理解：返回 {intent, reply, clarify_question, refined_question, generate_target,
    modify_target, needs_confirm, target_game, refine}。

    game_list 为 [{key, name, region, ...}] 游戏清单，供识别用户指向的游戏（target_game）。
    """
    msgs = build_chat_messages(history, message)
    if game_list:
        lines = [f"- key={g.get('key')} | 名称={g.get('name', '')} | 地区={g.get('region', '')}" for g in game_list]
        listing = "# 可用游戏清单（识别用户想查哪个游戏时对照使用）\n\n" + "\n".join(lines)
        msgs[-1]["content"] += "\n\n" + listing
    # 注入当前日期：模型上下文没有实时日期，告诉它「今天」好正确应答日期、以及把「最近7天/本月」落到真实日历
    now = datetime.now()
    _week = "一二三四五六日"
    _today_line = f"今天是 {now.year} 年 {now.month} 月 {now.day} 日，星期{_week[now.weekday()]}。"
    raw = complete_with_fallback(
        model=model,
        messages=[{"role": "system", "content": _SYSTEM + "\n\n" + _today_line}] + msgs,
        max_tokens=2048,
        user=user,
    )[0]
    data = _parse(raw)
    intent = data.get("intent") or "query"
    if intent not in ("chat", "clarify", "query", "model", "knowledge", "generate", "modify"):
        intent = "query"
    # 本地兜底：LLM 把「修改预测代码」误判成 model（重新预测）时，据历史+关键词强纠为 modify
    if _is_model_modify_request(message, history):
        intent = "modify"
    generate_target = data.get("generate_target")
    if intent == "generate" and generate_target not in ("sql", "model", "skill"):
        generate_target = None
    # 智能路由：仅 query 且非「修正上一轮」时允许切换深度分析（refine 是局部修正，必须留在普通管线）
    route_deep = intent == "query" and not data.get("refine") and bool(data.get("route_deep"))
    return {
        "intent": intent,
        "reply": (data.get("reply") or "").strip(),
        "clarify_question": (data.get("clarify_question") or "").strip(),
        "refined_question": (data.get("refined_question") or "").strip(),
        "target_game": (data.get("target_game") or "").strip() or None,
        "refine": bool(data.get("refine")),
        "generate_target": generate_target,
        "modify_target": (data.get("modify_target") or "").strip() or None,
        "needs_confirm": bool(data.get("needs_confirm")),
        "route_deep": route_deep,
    }
