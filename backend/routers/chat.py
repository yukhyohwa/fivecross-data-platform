"""对话取数：POST /api/chat，SSE 流式返回各阶段事件。

事件流（每行 `data: {json}`）：
  stage         -> {type, stage, message}
  meta          -> {type, source: skill|ai, skill, flagged, fold?: {expand:[], collapse:[]}}
  subscriptions -> {type, skill, subscriptions: [{id, name}]}
  sql           -> {type, sql}
  data          -> {type, name, table: {columns, rows, total_rows}}
  answer        -> {type, markdown}
  kpi           -> {type, kpis: [{label, value_str, delta_pct, delta_dir, hint}]}
  charts        -> {type, charts: [{name, chart_type, x, x_data, series}]}
  game_confirm  -> {type, question, games: [{key, name, label}], target_game, current, reason}
  error         -> {type, message}
  done          -> {type}
"""
import asyncio
import json
import logging
import os
import re
import time
from datetime import date, datetime, timedelta
from pathlib import Path

import pandas as pd
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse, Response
from pydantic import BaseModel

from .. import config
from ..deps import get_current_user, get_engine, get_game
from ..services import analyze, chart, conversation, forecast, games, gap_fix, generate_flow, kb_qa, model_run, rate_limit, refine, report_config, retrieval, schema_context, skill_agent, skill_match, sql_cache, sql_gen, sql_match, subscriptions, usage
from ..services.llm import LLMNotConfigured, ensure_llm_ready, inject_temperature, resolve_llm, resolve_model_for_task
from ..services.ide_bridge import anonymous_uid
from ..services.report_analyze import run_three_model
from ..services.table import df_to_table
from analysis import knowledge_store as ks
from analysis.ai_client import set_external_deadline, reset_external_deadline, external_deadline
from analysis.report_rules import ste_rules_block
from analysis import code_store
from analysis import gap_analysis
from analysis import glossary
from analysis import model_gen
from analysis import sql_store
from analysis import usage_tracker
from analysis.db import run_raw_sql
from analysis.prompts import build_data_block, build_history_section
from analysis.sql_rewriter import rewrite_sql, verify_sql, fix_sql, detect_hardcoded_dates, detect_placeholders, guard_rewrite, validate_sql
from analysis.time_range import parse_time_range, apply_date_range
from analysis.sql_explain import explain_sql
from analysis.games import family_key, owner_key, visible_to

router = APIRouter(prefix="/api", tags=["chat"])

logger = logging.getLogger(__name__)


class ChatRequest(BaseModel):
    model: str = ""  # 用户显式改选才回传；空串=按「主对话」任务槽位解析（2026-10-26 模型管理 13 槽位）
    message: str
    mode: str = "auto"  # auto（自由提问） | preset（预设专项）
    preset_skill: str | None = None
    chart_type: str = "auto"
    docs: list[str] = []
    context_report: str | None = None  # 上一版官方报告（后续追问时作为上下文发散）
    history: list[dict] = []  # 多轮对话历史 [{role, text, sql?, answer?}]
    confirm: str | None = None  # 二次确认决策：null=先检索；""=只查SQL；"<专项名>"=确认按该专项
    target_game: str | None = None  # 第一遍识别出的目标游戏 key，二次确认回传以保持数据源一致
    game_confirm: str | None = None  # 游戏二次确认：null=未确认；"ok"=按解析项目执行；""=按当前选中游戏执行
    game_confirm_source: str | None = None  # 游戏二次确认回传来源意图（query/model/knowledge），确认后路由回对应流程
    forecast_confirm: str | None = None  # 预测二次确认回传：JSON {"method","start","end","target_game"}
    candidate: str | None = None  # 候选卡回传：JSON {"type","name"}；""=「都猜错 → AI 现写 SQL」
    full_report: bool = False  # 确认按专项执行时：True=强制完整三模型（忽略上次报告结构记忆）；False=自动（有结构则复用）
    deep_thinking: bool = False  # 深度思考：True=报告三模型开推理（提高严谨度，耗时久、放宽超时）；False=关推理（快速档）
    ai_report_confirm: str | None = None  # AI自动生成报告二次确认：null=未确认；"ok"=确认生成报告；""=只查SQL
    rewrite_confirm: str | None = None  # 就近改写二次确认：null=未确认；""=不改写、AI现写；"<SQL名>"=以该SQL为底稿改写后执行
    generate_confirm: str | None = None  # 生成专项草稿二次确认：null=未确认；"ok"=确认生成（耗时较长，先人为确认）
    target_games: list[str] | None = None  # 游戏多选卡回传（哨兵「不选游戏」模式一次性绑定，优先级最高）
    session_games: list[str] | None = None  # 哨兵「不选游戏」模式会话延续的游戏选择（追问/refine 时前端携带）


class SuggestMergeReq(BaseModel):
    model: str = ""
    kind: str = "docs"  # sql | docs | skills | models
    target: str = ""    # 合并目标（现有 SQL/文档/专项/模型名）
    question: str = ""
    sql: str = ""
    answer: str = ""
    games: list[str] | None = None  # 哨兵「不选游戏」模式：前端回传会话选择的游戏（供恢复 key/db）


class SuggestReq(BaseModel):
    model: str = ""
    skill: str | None = None  # 本轮命中的专项名（有则优化既有专项，无则新建）
    question: str = ""
    sql: str = ""
    answer: str = ""
    kinds: list[str] | None = None  # 只提炼指定类别（sql/doc/skill），空 = 全部
    games: list[str] | None = None  # 哨兵「不选游戏」模式：前端回传会话选择的游戏（供恢复 game_key）


class ChatGapReq(BaseModel):
    model: str = ""
    skill: str | None = None  # 本轮命中的专项名（用于补全 gap 分析元信息）
    report_md: str = ""


class ChatGapFixReq(BaseModel):
    model: str = ""
    skill: str | None = None
    gap: dict


class ChatGapFixApplyReq(BaseModel):
    model: str = ""
    skill: str | None = None
    draft: dict


class ChatGapWhitelistReq(BaseModel):
    skill: str | None = None
    gap: dict


class ChatGapAnswerReq(BaseModel):
    model: str = ""
    skill: str | None = None
    gap: dict
    answer: str = ""


class ChatGapAnswerApplyReq(BaseModel):
    model: str = ""
    skill: str | None = None
    draft: dict
    gap: dict = {}


def _sse(payload: dict) -> str:
    return "data: " + json.dumps(payload, ensure_ascii=False) + "\n\n"


def _event(type_: str, **kw) -> str:
    return _sse({"type": type_, **kw})


def _skill_meta(skill: str) -> str:
    """专项 meta 事件，附带该专项 skill.md 里的「报告展示配置」（默认折叠/展开），供前端精准折叠。"""
    cfg = None
    try:
        cfg = report_config.parse_fold_config(ks.read_skill(skill))
    except Exception:
        cfg = None
    payload = {"source": "skill", "skill": skill, "flagged": False}
    if cfg:
        payload["fold"] = cfg
    return _event("meta", **payload)


def _doc_pairs(names: list[str], game=None, skill=None) -> list[tuple[str, str]]:
    """返回 [(文档名, 内容)]。skill 非空时优先用专项包内冻结的知识库核心内容，未冻结回退独立库。"""
    pairs = []
    for d in (names or []):
        if skill:
            text = ks.read_skill_knowledge(skill, d)
        else:
            text = ks.read_doc(d) if d in ks.list_docs(game) else ""
        if text.strip():
            pairs.append((d, text))
    return pairs


def _read_step_sql(skill: str | None, key: str) -> str:
    """读步骤 SQL：专项包内冻结优先，未快照回退独立 sql/ 库。"""
    if skill:
        return ks.read_skill_sql(skill, key)
    return sql_store.read_sql(key)


def _visible_sql_names(user, game_key) -> list[str]:
    """既有 SQL 清单，按「使用权限点 + 机密档位」过滤（无 sql_use 或档位不足的 SQL 不进上下文/不可运行）。"""
    from backend.ide_app.services.permissions import can_use_asset
    return [n for n in sql_store.list_sql_files(game_key)
            if can_use_asset(user, "sql", sql_store.read_sql_meta(n).get("confidentiality"))]


def _visible_online_skills(user, game_key) -> list[str]:
    """已上线专项清单，按「使用权限点 + 机密档位」过滤（无 skill_use 或档位不足的专项不进上下文/不可执行）。"""
    from backend.ide_app.services.permissions import can_use_asset
    return [s for s in ks.list_online_skills(game_key)
            if can_use_asset(user, "skill", ks.read_skill_meta(s).get("confidentiality"))]


def _visible_docs(user, game_key) -> list[str]:
    """知识库文档清单，按「使用权限点 + 机密档位」过滤（无 kb_use 或档位不足的文档不进上下文）。"""
    from backend.ide_app.services.permissions import can_use_asset
    return [d for d in ks.list_docs(game_key)
            if can_use_asset(user, "kb", ks.read_doc_meta(d).get("confidentiality"))]


# 「是否需要对绑定 SQL 做改写」的信号词：只有问题里出现明确的时间/维度/筛选意图才改写。
# 纯跑专项（如「流水达成分析」）不带额外诉求，直接用绑定 SQL 原文执行——既快，又避免
# 改写引入列名/口径错误（本次实测改写曾把 `date` 改成 `data`、把日期口径改乱）。
_REWRITE_TIME = re.compile(
    r"上周|本周|这周|下周|上个月|这个月|本月|下月|上月|昨天|今天|明天|今年|去年|"
    r"去年同期|季度|Q[1-4]|最近|近[0-9一二三四五六七八九十两]|过去|近期|同比|环比|"
    r"年初|年底|月末|周末|周中|当月|同期"
)
_REWRITE_SCOPE = re.compile(
    r"只|仅|排除|其中|对比|哪个|哪些|最高|最低|排行|前[0-9一二三四五六七八九十两]|Top|TOP|"
    r"美国|巴西|加拿大|墨西哥|智利|哥伦比亚|阿根廷|日本|韩国|东南亚|北美|南美|欧洲|中东|拉美"
)
# 对比型时间意图：需把「本期 vs 同期/去年同期」两个窗口放在同一查询里对比，
# 单一日期区间（apply_date_range）表达不了，必须交给模型改写。
_REWRITE_COMPARE = re.compile(r"同比|环比|同期")


def _rewrite_intent(question: str, skill: str | None) -> str:
    """判定专项绑定 SQL 的改写意图，三分类：

    - "none" 纯跑专项 → 直接用原文（零模型，最快）；
    - "date" 时间意图且能确定性解析成单一区间 → 走 apply_date_range 确定性注入（零模型）；
    - "model" 维度/筛选/对比/排行，或解析不出区间的对比/未来时间（同比/环比/去年同期/下周等）→ 模型改写。
    """
    q = (question or "").strip()
    if not q:
        return "none"
    if skill and skill in q:
        q = q.replace(skill, "")
    if not q.strip():
        return "none"
    if _REWRITE_SCOPE.search(q):
        return "model"          # 维度/筛选/对比/排行/国家 → 必须模型改写
    if not _REWRITE_TIME.search(q):
        return "none"           # 纯跑专项 → 原文
    if _REWRITE_COMPARE.search(q):
        return "model"          # 同比/环比/同期/去年同期 → 需对比两个时间窗口，模型改写
    start, end = parse_time_range(question)
    return "date" if (start or end) else "model"


def _needs_rewrite(question: str, skill: str | None) -> bool:
    """仅当问题带明确 时间/维度/筛选 意图时才需要改写绑定 SQL；纯跑专项返回 False。
    （保留给 preset 快路径闲聊检测；专项 SQL 改写分流见 _rewrite_intent。）"""
    return _rewrite_intent(question, skill) != "none"


# 纯闲聊/问候的本地轻量判定（免 LLM），仅用于预设专项的提速快速路径兜底。
_GREETING_RE = re.compile(
    r"^(你好|您好|hi|hello|hey|嗨+|哈喽|在吗|在不在|"
    r"谢谢|感谢|多谢|3q|thanks|thank you|thx|"
    r"早上好|下午好|晚上好|早安|晚安|早|"
    r"你是谁|你是谁呀|你能做什么|你能干啥|能做什么|能干嘛|有什么功能|你会什么|"
    r"再见|拜拜|bye|byebye|"
    r"好的|ok|OK|收到|了解|懂了|明白|嗯|辛苦啦|辛苦了|太棒了|厉害|"
    r"哈哈|呵呵|嘿嘿)"
    r"[!！。.~～,，\s]*$",
    re.IGNORECASE,
)


def _is_greeting(question: str) -> bool:
    """纯问候/闲聊则返回 True（免 LLM）。空串返回 False，交给取数流程处理。"""
    q = (question or "").strip()
    if not q:
        return False
    return bool(_GREETING_RE.search(q))


# 纯「今天几号/星期几/日期」问句的确定性应答（免 LLM）：模型上下文没有实时日期，
# 直接按服务器本地时间返回，避免模型回复「无法读取实时日期」。
_DATE_ASK_RE = re.compile(
    r"^(今天|今日|现在|当前)?(是|的)?(几号|几月几号|几月几日|多少号|什么日期|什么日子|日期|星期几|周几|礼拜几)"
    r"[?？。.!！~～\s呀啊呢吗么了]*$",
    re.IGNORECASE,
)


def _is_date_ask(question: str) -> bool:
    q = (question or "").strip()
    return bool(q and _DATE_ASK_RE.search(q))


def _today_reply() -> str:
    now = datetime.now()
    week = "一二三四五六日"
    return f"今天是 {now.year} 年 {now.month} 月 {now.day} 日，星期{week[now.weekday()]}。"


# 点名已存在专项的确定性匹配（免 LLM）：用户明说了专项名就优先执行，而不是靠意图分类/检索去猜。
# 覆盖「做个流水达成专项分析」被误判成 generate、以及「执行一下X专项」被检索阶段时间/指标对齐守卫漏判的两种场景。
_SKILL_STOP_WORDS = ("专题", "专项", "分析", "报告", "模板", "方法", "研究", "方案", "模型", "脚本")
_SKILL_CREATE_RE = re.compile(r"生成|新建|创建|撰写|编写|设计|搭建")
_SKILL_KNOWLEDGE_RE = re.compile(r"是什么|什么意思|怎么算|怎么定义|怎么解释|介绍一下|有哪些")
_SKILL_SIGNAL_RE = re.compile(r"专项|专题")
# 「重跑上次专项」的动词信号：用户说重跑/再跑/再来一次…但没点名具体专项名时，走重跑上次专项而非猜一个
_RERUN_RE = re.compile(r"重跑|再跑|再来一次|再来一遍|重新跑|重新执行|再执行|重新分析|再分析|重来")


def _skill_core(name: str) -> str:
    """把专项名剥掉「专项/分析/报告/模板」等通用词，得到核心词（如「流水达成分析专项」→「流水达成」）。"""
    core = (name or "").strip()
    changed = True
    while changed:
        changed = False
        for w in _SKILL_STOP_WORDS:
            if len(core) > len(w) and core.endswith(w):
                core = core[: -len(w)]
                changed = True
            elif len(core) > len(w) and core.startswith(w):
                core = core[len(w):]
                changed = True
    return core.strip()


def _explicit_skill_name(message: str, game_key: str, candidates: list[str] | None = None) -> str | None:
    """用户是否点名了某个已存在专项（且不是「生成/新建」新专项、也不是问口径）。

    命中返回专项名（调用方据此跳过意图分类与检索守卫、直接执行）；否则返回 None。
    确定性、免 LLM：先精确子串匹配，再核心词匹配（覆盖「流水达成专项分析」这类词序颠倒）。
    candidates 为已按用户可见性预过滤的候选名（哨兵模式传入 _sentinel_skill_candidates(user)），
    缺省按 game_key 走 list_online_skills 的可见性+上线过滤。
    """
    msg = (message or "").strip()
    if not msg:
        return None
    # 「生成/新建」等是建新工件，不是执行已有专项；「是什么/怎么算」等是问口径 → 都不当作点名执行
    if _SKILL_CREATE_RE.search(msg):
        return None
    if _SKILL_KNOWLEDGE_RE.search(msg):
        return None
    skills = (candidates if candidates is not None else ks.list_online_skills(game_key)) or []
    if not skills:
        return None
    # 1) 精确子串（最可靠）
    exact = [s for s in skills if s and s in msg]
    if len(exact) == 1:
        return exact[0]
    if exact:
        return max(exact, key=len)
    # 2) 核心词匹配：兜底词序颠倒（如「流水达成专项分析」）；要求消息含「专项/专题」信号、
    #    核心词 ≥3 字且唯一命中，避免把普通「最近7天流水达成」这种纯指标问句误当点名执行。
    if not _SKILL_SIGNAL_RE.search(msg):
        return None
    hits = []
    for s in skills:
        core = _skill_core(s)
        if core and len(core) >= 3 and core in msg:
            hits.append(s)
    if len(hits) == 1:
        return hits[0]
    return None


def _rerun_skill_request(message: str, game_key: str) -> bool:
    """用户想「重跑上次专项」：含重跑/再跑等动词 + 专项/专题信号，但没点名具体专项名。

    点名了具体专项名的不算（交给 _explicit_skill_name 精确命中），避免重复拦截。
    """
    q = (message or "").strip()
    if not q:
        return False
    if not (_RERUN_RE.search(q) and _SKILL_SIGNAL_RE.search(q)):
        return False
    return _explicit_skill_name(q, game_key) is None


def _sentinel_skill_candidates(user: dict) -> list[str]:
    """哨兵「不选游戏」模式的显式点名候选专项名（对抗审查三轮 [18]）。

    game_key=None 时 list_online_skills(None) 不做任何游戏过滤——他人个人级/绑他人游戏的项目级专项名
    会劫持首轮提问流：先按该专项绑定游戏（泄露技能→游戏映射）、再 H3 复核报「不存在或无权
    访问」让正常提问失败，甚至弹误导性游戏选择卡。这里按 _require_skill_visible 同口径预过滤：
    通用级全见、个人级仅归属当前用户、项目级需绑定游戏且用户有权（精确 key 或家族成员任一放行）；
    元数据缺失（level 空）的专项 fail closed 不参与点名。
    """
    from backend.ide_app.services.permissions import is_game_allowed
    engine = get_engine()
    allowed_keys = {g["key"] for g in games.get_games(engine) if is_game_allowed(user, g["key"])}
    owner = owner_key(user)
    out = []
    for name in ks.list_online_skills(None):
        try:
            meta = ks.read_skill_meta(name) or {}
        except Exception:  # noqa: BLE001 —— 单个专项元数据损坏不拖垮整体候选
            meta = {}
        level = meta.get("level")
        if not level:
            continue
        if level in ("通用", ""):
            out.append(name)
        elif level == "个人":
            if (meta.get("owner") or "") == owner:
                out.append(name)
        else:
            bound = meta.get("game")
            if not bound:
                continue
            fam_keys = {m["key"] for m in games.family_members({"key": bound}, engine)}
            if allowed_keys & fam_keys:
                out.append(name)
    return out


def _existing_skill_in_message(message: str, game_key: str) -> str | None:
    """在「生成/新建 X 专项」里判断 X 是否已是一个已存在的专项名（避免重复生成草稿）。

    与 _explicit_skill_name 的区别：不排除「生成/新建」等创建动词——用户说「生成 X 专项」时，
    X 若已存在，多半是想执行它而不是重建一份草稿。命中返回专项名，否则返回 None。
    """
    msg = (message or "").strip()
    if not msg:
        return None
    skills = ks.list_online_skills(game_key) or []
    if not skills:
        return None
    # 1) 精确子串（最可靠）
    exact = [s for s in skills if s and s in msg]
    if len(exact) == 1:
        return exact[0]
    if exact:
        return max(exact, key=len)
    # 2) 核心词匹配（创建动词不干扰核心词比对）
    hits = []
    for s in skills:
        core = _skill_core(s)
        if core and len(core) >= 3 and core in msg:
            hits.append(s)
    if len(hits) == 1:
        return hits[0]
    return None


def _load_bound_sqls(steps: list[dict], date_range=None, skill=None):
    """直接加载绑定 SQL（不改写），返回 (sql_to_run, originals)。date_range=(start,end) 时先做确定性日期替换。"""
    sql_to_run = []
    originals = {}
    for st in steps:
        name = st["name"]
        original = _read_step_sql(skill, st["sql"])
        if date_range:
            original = apply_date_range(original, date_range[0], date_range[1])
        originals[name] = original
        sql_to_run.append((name, original))
    return sql_to_run, originals


def _check_hardcoded_dates(steps: list[dict], skill=None):
    """识别绑定 SQL 是否硬编码了日期字面量；有则提示「暂不支持动态调整时间范围」。"""
    for st in steps:
        name = st["name"]
        original = _read_step_sql(skill, st["sql"])
        for d in detect_hardcoded_dates(original):
            yield _event("stage", stage="verify", message=(
                f"⚠️ {name} 硬编码了日期 {d}：暂不支持按专项/对话动态调整其时间范围"
                f"（建议改用 current_date() 相对表达式）"
            ))


def _similar_sql_examples(question: str, game_key: str, k: int = 3, user: dict = None) -> list[tuple[str, str]]:
    """从既有 SQL 库选 k 条与问题最相关的，返回 [(name, content)] 作 few-shot 例子。

    用问题里相邻两字（2-gram）与 SQL 文件名做轻量匹配，零额外模型调用；无相关时不硬凑。
    按「使用权限点 + 机密档位」过滤（user 非空时），超授权的 SQL 不进示例、不泄露内容。
    """
    names = _visible_sql_names(user, game_key) if user is not None else sql_store.list_sql_files(game_key)
    if not names:
        return []
    q = (question or "").strip()
    grams = {q[i:i + 2] for i in range(len(q) - 1)} if len(q) >= 2 else set()

    def score(name: str) -> int:
        stem = name[:-4] if name.endswith(".sql") else name
        return sum(1 for g in grams if g in stem)

    ranked = sorted(names, key=score, reverse=True)
    out = []
    for name in ranked[:k]:
        if score(name) == 0:
            continue
        out.append((name, sql_store.read_sql(name)))
    return out


def _dry_run_sql(engine, sql: str, *, project_key: str | None = None) -> str | None:
    """用 EXPLAIN 干跑 SQL 抓分析期错误（列不存在/语法等）；成功返回 None，出错返回报错文本。"""
    try:
        run_raw_sql(engine, f"EXPLAIN {sql}", project_key=project_key)
        return None
    except Exception as exc:
        return str(exc)


# 数据同步延迟兜底：事实表名跨游戏固定，仅库名随产品代码变（见 apply_db）。
_PROBE_TABLES = ("dwd_all_games_purchase_i_rt_view", "dwd_all_games_active_i_rt_view")


def _probe_latest_date(engine, db: str) -> str | None:
    """探测库内最新可用数据日（YYYY-MM-DD），逐表尝试，全失败返回 None。"""
    for tbl in _PROBE_TABLES:
        try:
            r = run_raw_sql(engine, f"SELECT max(date) AS d FROM {db}.{tbl}", project_key=games.project_key_for_db(db))
        except Exception:
            continue
        if r is not None and len(r):
            v = r.iloc[0]["d"]
            if v is not None:
                return str(v)[:10]
    return None


def _latest_upper(engine, db: str) -> str | None:
    """返回「库内最新可用日 + 1 天」（YYYY-MM-DD），作为相对时间窗口的上界。

    仅当数据落后 ≥2 天（最新日 ≤ 前天）时才返回一个更早的上界；数据已覆盖到当天/昨天
    （current_date() 窗口本就能取到最新数据）或探测失败时返回 None（不夹）。
    """
    try:
        latest = _probe_latest_date(engine, db)
        if not latest:
            return None
        upper = (datetime.strptime(latest, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
        if upper >= datetime.now().strftime("%Y-%m-%d"):
            return None
        return upper
    except Exception:
        return None


def _clamp_current_date(sql: str, upper: str | None) -> str:
    """把 SQL 里的 current_date()/now() 统一替换为 upper 字面量（upper=None 则不动作）。

    用于数据同步延迟兜底：把相对时间窗口整体夹到库内最新可用日，避免窗口落在
    尚无数据的日期上、取数为空导致后续分析无法开展。任何异常原样返回。
    """
    if not sql or not upper:
        return sql
    try:
        return re.sub(
            r"current_date\s*\(\s*\)|\bnow\s*\(\s*\)",
            f"'{upper}'",
            sql,
            flags=re.IGNORECASE,
        )
    except Exception:
        return sql


def _fill_default_placeholders(sql: str) -> str:
    """兜底：普通取数 SQL 若残留 {开始日期}/{结束日期} 占位符，替换为相对表达式
    （{开始日期}=date_sub(current_date(), interval 7 day)、{结束日期}=current_date()）。
    相对表达式随后会被 _clamp_current_date 夹到库内最新可用日，避免数据同步延迟下取空。
    预测路径（_run_forecast）不经过这里，其占位符由自身用计算出的窗口替换，不受影响。
    """
    if not sql:
        return sql
    try:
        sql = sql.replace("{开始日期}", "date_sub(current_date(), interval 7 day)")
        sql = sql.replace("{结束日期}", "current_date()")
        return sql
    except Exception:
        return sql


def _rewrite_step_sqls(model, steps, mod_prompt, skill_text, problems=None, date_range=None, skill=None, schema_text=None):
    """对若干步骤的预配置 SQL 逐条改写，并经口径保真护栏校验（不再跑第二条验证模型）。

    返回 (sql_to_run, originals)：sql_to_run 为 [(步骤名, 改写后 SQL)]，
    originals 为 {步骤名: 原始 SQL}，供预检失败时回退到已验证可用的原始 SQL。
    改写失败或护栏发现破坏口径（tz/币种/日期/丢表）时，直接回退原文——原文本身已按专项验证可用。
    problems 若提供，改写失败时把问题追加进去（供运行记忆）。
    date_range=(start,end) 时先把相对时间表达式确定性替换成明确日期，再交给改写模型。

    schema_text 可选：仅当步骤 SQL 含方括号占位符（[group_value]/[where_value] 等）时调用方
    会传入表结构上下文，供改写模型把占位符替换成真实列名/条件；无占位符时保持原有行为。
    占位符模板本身不可执行，改写后仍残留占位符（AI 未能替换）时跳过该步骤并明确提示，而非拿去执行。
    """
    sql_to_run = []
    originals = {}
    for st in steps:
        name = st["name"]
        original = _read_step_sql(skill, st["sql"])
        if date_range:
            original = apply_date_range(original, date_range[0], date_range[1])
        originals[name] = original
        has_ph = bool(detect_placeholders(original))
        yield _event("stage", stage="generate", message=f"AI 按专项方法改写 SQL：{name}")
        try:
            new_sql, _ = rewrite_sql(
                model, original, [mod_prompt] if mod_prompt else [], skill_text,
                schema_text=schema_text if has_ph else None,
            )
        except Exception as e:
            if has_ph:
                yield _event("stage", stage="generate", message=f"⚠️ {name} 改写失败：{e}（占位符模板不可直接执行，跳过该步骤）")
                if problems is not None:
                    problems.append(f"{name} 改写失败（占位符模板）：{e}")
                continue
            yield _event("stage", stage="generate", message=f"⚠️ {name} 改写失败：{e}，改用原 SQL")
            if problems is not None:
                problems.append(f"{name} 改写失败：{e}")
            sql_to_run.append((name, original))
            continue
        # 占位符兜底：改写后仍残留 [xxx] 说明 AI 没替换，模板本身不可执行，跳过并明确提示
        residual = detect_placeholders(new_sql)
        if residual:
            yield _event("stage", stage="verify", message=f"⚠️ {name} 改写后仍残留占位符 {residual}，跳过该步骤（AI 未能替换）")
            if problems is not None:
                problems.append(f"{name} 改写后残留占位符 {residual}")
            continue
        violations = guard_rewrite(original, new_sql)
        if violations:
            if has_ph:
                yield _event("stage", stage="verify", message=f"⚠️ {name} 占位符模板改写疑似破坏口径（{'；'.join(violations)}），跳过该步骤")
                if problems is not None:
                    problems.append(f"{name} 占位符模板改写破坏口径（{'；'.join(violations)}）")
                continue
            yield _event("stage", stage="verify", message=(
                f"⚠️ {name} 改写结果疑似破坏口径（{'；'.join(violations)}），回退原 SQL"
            ))
            if problems is not None:
                problems.append(f"{name} 改写破坏口径（{'；'.join(violations)}），回退原 SQL")
            sql_to_run.append((name, original))
            continue
        sql_to_run.append((name, new_sql))
    return sql_to_run, originals


def _precheck_steps(model, engine, game, game_key, sql_to_run, originals=None, problems=None, query_games=None):
    """EXPLAIN 干跑预检，出错用 AI 按报错修正一次；修正仍失败则回退到原始 SQL。

    就地修改 sql_to_run；originals 为 {步骤名: 原始 SQL}，未提供时（自由提问现写
    SQL）无原始可回退，保持当前 SQL。problems 若提供，把修正/回退记录追加进去（供运行记忆）。
    """
    originals = originals or {}
    for idx, (name, sql) in enumerate(sql_to_run):
        # 预检前先填充 {开始日期}/{结束日期} 占位符，与执行路径（_execute_steps）及
        # sql_checks.precheck_sql 同口径：否则含占位符的已保存 SQL 必然语法报错，
        # 被 fix_sql 静默改写、破坏日期窗口语义。
        applied = games.apply_sql(_fill_default_placeholders(sql), game["db"])
        err = _dry_run_sql(engine, applied, project_key=game["key"])
        if err is None:
            # 多地区库时，对主库之外的地区库也做一次轻量 EXPLAIN（不改写），
            # 提前暴露地区库上的 schema/权限差异，避免到执行阶段才发现。
            for g in (query_games or [game]):
                if g["db"] == game["db"]:
                    continue
                err2 = _dry_run_sql(engine, games.apply_sql(_fill_default_placeholders(sql), g["db"]), project_key=g["key"])
                if err2 is not None:
                    yield _event("stage", stage="verify",
                                 message=f"⚠️ {name} 在 {g['key']} 预检报错（{err2}），执行时将跳过该地区")
                    if problems is not None:
                        problems.append(f"{name} 在 {g['key']} 预检报错：{err2}")
            continue
        yield _event("stage", stage="verify", message=f"预检发现 {name} 有问题，AI 正在修正…")
        try:
            schema_text, _, _ = schema_context.build_sql_context(engine, game["db"], game_key)
            fixed, _ = fix_sql(model, applied, err, schema_text)
            if _dry_run_sql(engine, games.apply_sql(_fill_default_placeholders(fixed), game["db"]), project_key=game["key"]) is None:
                sql_to_run[idx] = (name, fixed)
                yield _event("stage", stage="verify", message=f"✅ {name} 已按报错修正")
            elif name in originals:
                sql_to_run[idx] = (name, originals[name])
                yield _event("stage", stage="verify", message=f"⚠️ {name} 修正无效，回退原始 SQL")
                if problems is not None:
                    problems.append(f"{name} 预检修正无效，回退原始 SQL")
            else:
                yield _event("stage", stage="verify", message=f"⚠️ {name} 修正后仍有问题，将按当前 SQL 执行")
        except Exception as exc:
            if name in originals:
                sql_to_run[idx] = (name, originals[name])
                yield _event("stage", stage="verify", message=f"⚠️ {name} 自动修正失败（{exc}），回退原始 SQL")
                if problems is not None:
                    problems.append(f"{name} 自动修正失败：{exc}")
            else:
                yield _event("stage", stage="verify", message=f"⚠️ {name} 自动修正失败（{exc}），将按当前 SQL 执行")
    return sql_to_run


_EXEC_REPAIR_ATTEMPTS = 2  # 执行报错后的 AI 自修正次数上限（通用自修正循环）


def _self_repair(model, engine, game, game_key, name, sql, err):
    """执行报错后的通用自修正循环：按报错反馈让 AI 修正 SQL 并重跑（最多 _EXEC_REPAIR_ATTEMPTS 次）。

    返回修正后取到的 DataFrame；全部失败返回 None（调用方按原逻辑兜底）。
    仅 model 提供时启用；多地区不自动改写（多为地区差异），见 _repair_empty_steps 同款决策。
    """
    if model is None:
        return None
    cur, cur_err = sql, err
    for attempt in range(1, _EXEC_REPAIR_ATTEMPTS + 1):
        yield _event("stage", stage="verify",
                     message=f"⚠️ {name} 执行报错，AI 自修正第 {attempt}/{_EXEC_REPAIR_ATTEMPTS} 次…")
        fixed = None
        try:
            schema_text, _, _ = schema_context.build_sql_context(engine, game["db"], game_key)
            fixed, _ = fix_sql(model, cur, cur_err, schema_text)
            applied = games.apply_sql(fixed, game["db"])
            if _dry_run_sql(engine, applied, project_key=game["key"]) is not None:
                raise ValueError("修正后的 SQL 预检仍报错")
            df = run_raw_sql(engine, applied, project_key=game["key"])
            yield _event("stage", stage="verify", message=f"✅ {name} 自修正后执行成功（{len(df)} 行）")
            return df
        except Exception as exc:
            if fixed is not None:
                cur = fixed
            cur_err = str(exc)
            yield _event("stage", stage="verify", message=f"⚠️ {name} 自修正第 {attempt} 次仍失败（{exc}）")
    return None


def _record_glossary_candidates(sql):
    """运行期术语候选自记录：从产出的 SQL 抽取「术语表尚未收录」的列，按表结构描述入候选队列。

    纯确定性、零额外模型调用；任何异常静默，绝不影响取数主流程。
    """
    try:
        glossary.capture_sql_candidates(sql, "data_ai")
    except Exception as exc:
        logger.warning("术语候选自记录失败（不影响取数）：%s", exc)


def _execute_steps(engine, game, query_games, sql_to_run, postprocess=None, model=None, game_key=None):
    """执行 SQL（单库逐条；同一游戏多地区库时每条 SQL 各库跑一遍并合并带「地区」列的结果）。

    返回 (query_results, primary_df, run_sql, displayed)；执行出错时返回 (None, None, None, None)
    （调用方须 return）。displayed 为 [(名称, DataFrame)]，与每个 data 事件一一对应，供每个表格各配一张图。
    postprocess 为可选回调 df -> df（命中既有 SQL 时用于按问题裁剪结果列，在 emit data 之前生效）。
    """
    run_sql = sql_to_run[0][1] if sql_to_run else None  # 供提炼建议复用（原始 SQL，未 apply_db）
    multi = len(query_games) > 1
    # 数据同步延迟兜底：预探测各库最新可用日，落后当天时把 SQL 的相对时间窗口夹到最新可用日
    clamps = {}
    if not multi:
        clamps[game["db"]] = _latest_upper(engine, game["db"])
    else:
        for g in query_games:
            clamps[g["db"]] = _latest_upper(engine, g["db"])
    query_results = {}
    primary_df = None
    displayed = []
    for name, sql in sql_to_run:
        _record_glossary_candidates(sql)
        hint = chart.parse_chart_hint(sql)  # 从 SQL 头部注释读图表提示（图表类型/右轴），驱动各图默认形态
        if not multi:
            s = games.apply_sql(sql, game["db"])
            s = _fill_default_placeholders(s)
            s = _clamp_current_date(s, clamps.get(game["db"]))
            yield _event("stage", stage="query", message=f"执行 {name}…")
            yield _event("sql", sql=s, explain=explain_sql(s), name=name, db=game["db"])
            try:
                df = run_raw_sql(engine, s, project_key=game["key"])
            except Exception as e:
                df = yield from _self_repair(model, engine, game, game_key, name, s, str(e))
                if df is None:
                    yield _event("error", message=f"{name} 执行失败：{e}")
                    return None, None, None, None
            if postprocess is not None:
                df = postprocess(df)
            df.attrs["chart_hint"] = hint
            query_results[name] = df
            primary_df = primary_df if primary_df is not None else df
            displayed.append((name, df))
            if not df.empty:
                yield _event("data", name=name, table=df_to_table(df))
        else:
            parts = []
            exports = []  # 各库最终 SQL（供前端「导出全量」按拼后数据重跑，只含执行成功的库）
            failed_regions = []  # 失败地区的标签（对抗审查二轮 G4：拼后报告缺地区必须显式警示，防用户误当全量）
            for g in query_games:
                s = games.apply_sql(sql, g["db"])
                s = _fill_default_placeholders(s)
                s = _clamp_current_date(s, clamps.get(g["db"]))
                label = games.region_label(g)
                yield _event("stage", stage="query", message=f"执行 {name}（{g['key']}）…")
                yield _event("sql", sql=s, explain=explain_sql(s), name=f"{name}｜{label}", db=g["db"])
                try:
                    df = run_raw_sql(engine, s, project_key=g["key"])
                except Exception as e:
                    # 单个地区失败不拖垮整份多地区报告：记录错误并跳过，继续跑其它地区
                    yield _event("error", message=f"{name}（{label}）执行失败，跳过该地区：{e}")
                    failed_regions.append(label)
                    continue
                exports.append({"sql": s, "db": g["db"], "label": label})
                if postprocess is not None:
                    df = postprocess(df)
                key = label if len(sql_to_run) == 1 else f"{name}｜{label}"
                query_results[key] = df
                view = df.copy()
                if "地区" in view.columns:
                    view = view.rename(columns={"地区": "地区(原)"})
                view.insert(0, "地区", label)
                parts.append(view)
            if not parts:
                # 所有地区都失败 → 无任何数据，整体放弃（与单库失败一致）
                return None, None, None, None
            if failed_regions:
                # 拼接结果是「成功地区的并集」，缺的地区必须收口警示（G4）
                yield _event("caveats", items=[{
                    "category": "例外警示",
                    "text": f"{name}：{'、'.join(failed_regions)} 执行失败已跳过（结果仅含成功地区）",
                }])
            concat = pd.concat(parts, ignore_index=True)
            concat.attrs["chart_hint"] = hint
            if primary_df is None:
                primary_df = concat  # 主视图固定用第一个步骤（分日流水达成），与单库分支一致
            displayed.append((name, concat))
            if not concat.empty:
                yield _event("data", name=name, table=df_to_table(concat), export=exports)
    return query_results, primary_df, run_sql, displayed


def _repair_empty_steps(model, engine, game, game_key, sql_to_run, query_results, problems=None):
    """对执行后为空表（0 行）的步骤做一次「结果为空」自纠错：按空结果反馈让 AI 修正 SQL 并重跑。

    仅单库调用（多地区空表更可能是地区差异，不自动改写）。就地修改 query_results：
    修正后非空则替换结果并补发 data 事件；仍空则保留并记入 problems。返回 {步骤名: 修正后 df}。
    """
    by_name = {name: sql for name, sql in sql_to_run}
    upper = _latest_upper(engine, game["db"])
    schema_text = None
    repaired = {}
    for name, df in list(query_results.items()):
        if df is not None and not df.empty:
            continue
        sql = by_name.get(name)
        if not sql:
            continue
        yield _event("stage", stage="verify", message=f"⚠️ {name} 结果为空，AI 按「无数据」反馈修正 SQL 后重试…")
        try:
            if schema_text is None:
                schema_text, _, _ = schema_context.build_sql_context(engine, game["db"], game_key)
            applied = _clamp_current_date(_fill_default_placeholders(games.apply_sql(sql, game["db"])), upper)
            fixed, _ = fix_sql(model, applied, "SQL 执行成功但结果为空（无数据），请检查时间窗口/过滤条件/表名是否正确并修正", schema_text)
            fixed_applied = _clamp_current_date(_fill_default_placeholders(games.apply_sql(fixed, game["db"])), upper)
            if _dry_run_sql(engine, fixed_applied, project_key=game["key"]) is not None:
                raise ValueError("修正后的 SQL 预检仍报错")
            new_df = run_raw_sql(engine, fixed_applied, project_key=game["key"])
        except Exception as exc:
            yield _event("stage", stage="verify", message=f"⚠️ {name} 空表修正失败（{exc}），按无数据处理")
            if problems is not None:
                problems.append(f"{name} 结果为空")
            continue
        if new_df is not None and not new_df.empty:
            new_df.attrs["chart_hint"] = chart.parse_chart_hint(fixed)
            query_results[name] = new_df
            repaired[name] = new_df
            yield _event("stage", stage="verify", message=f"✅ {name} 修正后取到 {len(new_df)} 行")
            yield _event("data", name=name, table=df_to_table(new_df))
        else:
            yield _event("stage", stage="verify", message=f"⚠️ {name} 修正后仍为空，按无数据处理")
            if problems is not None:
                problems.append(f"{name} 结果为空")
    return repaired


# 预测能力注册表中的元数据键（非调度、非方法参数，解析时剔除）
_FORECAST_META_KEYS = {"name", "desc", "input", "app", "func"}
# 调度键（取数/日期窗口），其余键作为方法参数透传（如 window）
_FORECAST_ORCH_KEYS = {"granularity", "sql", "target_sql", "hist_days", "hist_months", "horizon_days", "horizon_months"}


def _forecast_actual_comparison(engine, game, result, period, granularity, currency=None):
    """回填预测（指定已发生时间段）时，取同一时段的实际流水，与预测合并成「预测 vs 实际」对比表。

    返回 DataFrame（日期/月份 + 预测流水(xxx) + 实际流水(xxx) + 误差(xxx) + 误差率(%)），
    无预测表 / 取数失败时返回 None（不阻断主预测结果）。
    """
    target_name = "流水预测(分月)" if granularity == "month" else "流水预测(分日)"
    df_pred = None
    for t in result.get("tables") or []:
        if t.get("name") == target_name and t.get("df") is not None and not t["df"].empty:
            df_pred = t["df"]
            break
    if df_pred is None:
        return None
    pred_col = next((c for c in df_pred.columns if c.startswith("预测流水")), None)
    if not pred_col:
        return None
    start, end = period.get("start"), period.get("end")
    if not start or not end:
        return None

    return None

    cur = "USD" if str(currency or "").upper() == "USD" else "CNY"
    price_col = "<schema-confirmed-amount-column>"

    if granularity == "month":
        key_expr, key_alias, fmt = "DATE_TRUNC('month', date)", "月份", "%Y-%m"
        pred_keys = df_pred["月份"].astype(str).str[:7]
    else:
        key_expr, key_alias, fmt = "date", "日期", "%Y-%m-%d"
        pred_keys = pd.to_datetime(df_pred["日期"]).dt.strftime(fmt)

    sql = (
        f"SELECT {key_expr} AS \"{key_alias}\", SUM({price_col}) AS \"实际流水\" "
        f"FROM pf_rooc_am.dwd_all_games_purchase_i_rt_view "
        f"WHERE date >= '{start}' AND date <= '{end}' "
        f"GROUP BY {key_expr} ORDER BY {key_alias}"
    )
    try:
        actual = run_raw_sql(engine, games.apply_sql(sql, game["db"]), project_key=game["key"])
    except Exception:
        return None
    if actual is None or actual.empty:
        return None
    actual[key_alias] = pd.to_datetime(actual[key_alias]).dt.strftime(fmt)

    out = pd.DataFrame({
        key_alias: pred_keys.reset_index(drop=True),
        pred_col: df_pred[pred_col].reset_index(drop=True),
    })
    out = out.merge(actual, on=key_alias, how="left")
    out.rename(columns={"实际流水": f"实际流水({cur})"}, inplace=True)
    actual_col = f"实际流水({cur})"
    out[f"误差({cur})"] = (out[actual_col] - out[pred_col]).round(2)
    out[f"误差率(%)"] = (
        (out[actual_col] - out[pred_col]) / out[pred_col].replace(0, pd.NA) * 100
    ).round(1)
    return out


def _forecast_backtest(func, df_hist, params, currency=None, backtest_days=14, threshold=0.30):
    """默认未来预测的「最近 N 天回测」：逐日截断历史做一步外推，对比实际流水算 FER。

    技能要求「定期回测最近 1~2 周预测与实际偏差，超阈值需调整模型或人工干预」
    （FER = 预测误差率 = abs(实际/预测 − 1)）。这里对最近 backtest_days 天做 walk-forward 回测：
      - 对每个被留出的历史日 D，用 D 之前的历史重跑模型预测 D，与 df_hist 实际「总收入」比 FER；
      - 返回 (回测表 DataFrame, meta) 或 (None, None)（历史不足 / 无日表时跳过）。

    只对分日模型（run 产出「流水预测(分日)」表 + df_hist 含「总收入」）适用；分月/其它返回 None。
    """
    if func is None or df_hist is None or df_hist.empty:
        return None, None
    if "日期" not in df_hist.columns or "总收入" not in df_hist.columns:
        return None, None
    h = df_hist.copy()
    h["日期"] = pd.to_datetime(h["日期"])
    h = h.sort_values("日期").reset_index(drop=True)
    h["总收入"] = pd.to_numeric(h["总收入"], errors="coerce")
    if len(h) < 2:
        return None, None
    cur = "USD" if str(currency or "").upper() == "USD" else "CNY"
    window = int((params or {}).get("window", 30))
    rows = []
    for i in range(len(h) - 1, max(len(h) - backtest_days - 1, -1), -1):
        d = h.loc[i, "日期"]
        truncated = h[h["日期"] < d]
        if len(truncated) < window:
            continue  # 留出日之前的历史不足一个滚动窗口，回测不可信
        try:
            r = func(truncated, d, **params)
        except Exception:
            continue
        pred = None
        for t in (r.get("tables") or []):
            if t.get("name") != "流水预测(分日)":
                continue
            tdf = t.get("df")
            if not isinstance(tdf, pd.DataFrame) or tdf.empty:
                continue
            pc = next((c for c in tdf.columns if c.startswith("预测流水")), None)
            if pc is None:
                break
            dd = tdf.copy()
            dd["_d"] = pd.to_datetime(dd["日期"])
            hit = dd[dd["_d"] == d]
            if not hit.empty:
                pred = float(hit.iloc[0][pc])
            break
        if pred is None or pred == 0:
            continue
        actual = float(h.loc[i, "总收入"])
        if pd.isna(actual) or pd.isna(pred):
            continue
        rows.append((d, pred, actual, abs(actual / pred - 1.0)))
    if not rows:
        return None, None
    bdf = pd.DataFrame(rows, columns=["日期", f"预测流水({cur})", f"实际流水({cur})", "FER(%)"])
    bdf["日期"] = bdf["日期"].dt.strftime("%Y-%m-%d")
    bdf[f"预测流水({cur})"] = bdf[f"预测流水({cur})"].round(2)
    bdf[f"实际流水({cur})"] = bdf[f"实际流水({cur})"].round(2)
    bdf["FER(%)"] = (bdf["FER(%)"] * 100).round(1)
    fer = bdf["FER(%)"]
    meta = {
        "days": len(rows),
        "fer_mean_pct": round(float(fer.mean()), 1),
        "fer_median_pct": round(float(fer.median()), 1),
        "fer_max_pct": round(float(fer.max()), 1),
        "threshold_pct": round(threshold * 100, 1),
        "over_threshold": float(fer.median()) > threshold * 100,
    }
    return bdf, meta


# 取数 SQL 对金额/ARPU 列别名加币种标签（如「新账号ARPU(CNY)」），而模型内部固定用
# 「新账号ARPU」等无后缀列名。币种标签是展示约定，不应泄漏进模型输入契约——在 df 边界
# 统一剥离，模型无论取数 SQL 是否带币种后缀都能对上（CNY/USD/人民币/美金均兼容）。
_CUR_SUFFIX_RE = re.compile(r"\((?:CNY|USD|人民币|美金)\)$", re.IGNORECASE)


def _strip_currency_suffix(df):
    """剥离预测取数 df_hist 列名里的币种后缀；None/空 df 原样返回。"""
    if df is None or df.empty:
        return df
    rename = {c: _CUR_SUFFIX_RE.sub("", c) for c in df.columns if _CUR_SUFFIX_RE.search(c)}
    return df.rename(columns=rename) if rename else df


def _run_daily_as_monthly(engine, game, daily_cap, hist_end, pred_end, overrides):
    """新游月历史不足时的兜底：用分日模型 dau_arpu_roll 预测，再把每日流水按月汇总成月流水。

    返回与 mau_monthly_roll 同构的结果 dict（流水预测(分月) 表）；失败返回 None（由调用方回退原分月模型）。
    """
    cfg = {k: v for k, v in daily_cap.items() if k not in _FORECAST_META_KEYS}
    if overrides.get("currency"):
        cfg["currency"] = overrides["currency"]
    sql_name = cfg.get("sql")
    sql_tpl = code_store.read_model_sql("dau_arpu_roll") or ""
    if not sql_tpl.strip() and sql_name:
        sql_tpl = sql_store.read_sql(sql_name)
    if not sql_tpl.strip():
        return None

    hist_days = int(cfg.get("hist_days", 84))
    d_hist_end = pd.Timestamp(hist_end)
    d_hist_start = d_hist_end - pd.Timedelta(days=hist_days)
    sql = (sql_tpl
           .replace("{开始日期}", d_hist_start.strftime("%Y-%m-%d"))
           .replace("{结束日期}", d_hist_end.strftime("%Y-%m-%d")))
    sql = games.apply_sql(sql, game["db"])
    # 币种覆盖：用户要美金/美元时换 USD（与 _run_forecast 一致）

    try:
        df_hist = run_raw_sql(engine, sql, project_key=game["key"])
    except Exception:
        return None
    df_hist = _strip_currency_suffix(df_hist)
    if df_hist is None or df_hist.empty:
        return None

    func = daily_cap.get("func")
    if func is None:
        return None
    params = {k: v for k, v in cfg.items() if k not in _FORECAST_ORCH_KEYS}
    try:
        result = func(df_hist, pd.Timestamp(pred_end), **params)
    except Exception:
        return None

    cur = "USD" if str(params.get("currency", "CNY")).upper() == "USD" else "CNY"
    daily_df = None
    for t in result.get("tables", []):
        if t.get("name") == "流水预测(分日)" and t.get("df") is not None and not t["df"].empty:
            daily_df = t["df"]
            break
    if daily_df is None:
        return None
    daily_df = daily_df.copy()
    daily_df["日期"] = pd.to_datetime(daily_df["日期"])
    # 只保留「目标预测月」起的日期：分日模型从最后一天可用历史之后逐日预测，若历史截止
    # 在上月末之前（如今天还在 9 月、历史只到 9/26），会先补出 9 月末的零头天，需裁掉，
    # 使分月汇总恰好是 10/11/12 三个完整月，而不是混入 9 月的残段。
    pred_start = d_hist_end + pd.Timedelta(days=1)
    daily_df = daily_df[daily_df["日期"] >= pred_start]
    if daily_df.empty:
        return None
    flow_col = f"预测流水({cur})"
    if flow_col not in daily_df.columns:
        return None
    # 「预测DAU」列可能因模型/能力输出波动缺失：分月汇总依赖它，缺列时跳过（否则 agg 抛 KeyError 杀死整个 SSE 流）
    if "预测DAU" not in daily_df.columns:
        return None

    monthly = (
        daily_df.assign(_m=daily_df["日期"].dt.to_period("M"))
        .groupby("_m", as_index=False)
        .agg(**{f"预测流水({cur})": (flow_col, "sum"), "日均预测DAU": ("预测DAU", "mean")})
    )
    monthly["月份"] = monthly["_m"].astype(str)
    monthly = monthly[["月份", f"预测流水({cur})", "日均预测DAU"]]
    monthly[f"预测流水({cur})"] = monthly[f"预测流水({cur})"].round(2)
    monthly["日均预测DAU"] = monthly["日均预测DAU"].round(0).astype("Int64")

    return {
        "tables": [{"name": "流水预测(分月)", "df": monthly, "display": True}],
        "meta": {"method": "dau_arpu_roll", "window": cfg.get("window"), "pred_end": str(pred_end)},
    }


def _fetch_forecast_target(engine, game, skill, target_sql_name):
    """取「未来周目标」数据（预测达成率用）。未配置 / 取数失败 / 为空返回 None，不阻断预测。

    目标表列约定：日期 / 目标(CNY)（kpi_type='sales' 的 dim_kpi_target_view.kpi_value），
    取未来 4 个完整自然周（相对 current_date 的 date_trunc('week') 区间），交给模型按周对齐。
    """
    if not target_sql_name:
        return None
    sql_tpl = _read_step_sql(skill, target_sql_name)
    if not sql_tpl.strip():
        return None
    sql = games.apply_sql(sql_tpl, game["db"])
    try:
        df = run_raw_sql(engine, sql, project_key=game["key"])
    except Exception:
        return None
    return df if (df is not None and not df.empty) else None


def _forecast_fetch_sql_names(fc) -> list[str]:
    """返回专项绑定预测能力的「取数专用」SQL 名（历史群组取数 sql + 目标取数 target_sql）。

    这些 SQL 只由 _run_forecast / _fetch_forecast_target 取数，不作为普通报告步骤执行，
    也不作为图表出现在报告里（其 {开始日期}/{结束日期} 占位符只在预测路径替换，普通步骤跑会取空）。
    """
    method = (fc or {}).get("method") if isinstance(fc, dict) else fc
    if not method:
        return []
    cap = forecast.PREDICTION_CAPABILITIES.get(method)
    if not cap:
        return []
    return [n for n in (cap.get("sql"), cap.get("target_sql")) if n]


def _run_forecast(model, engine, game, game_key, fc, skill=None, period=None, note_games=None):
    """按专项绑定的预测能力（可配置项）执行预测：取历史群组数据 → 预测 → 返回结果 dict。

    fc 为专项 meta 的 forecast 字段，两种写法：
      - 字符串（能力名）：直接用 forecast.PREDICTION_CAPABILITIES 里该能力的默认配置；
      - 对象 {"method": 能力名, ...覆盖项}：覆盖注册表默认配置（如 horizon_days/window）。
    离线上传型（input=upload）/ 取数失败 / 数据为空时发 stage 提示并返回 None，不阻断主报告。
    skill 非空且为打包专项时，优先用专项包内冻结的模型代码与预测取数 SQL。
    period 非空时（{"start","end"}）表示「预测一个已确认的指定时间段」：历史截止到
    period.start 前一天，预测到 period.end（用于「预测 9 月份每天流水」这类已发生回填）。
    note_games 非空且多游戏时先明示：预测只基于主游戏执行（多选口径）。
    """
    if note_games and len(note_games) > 1:
        yield _event("stage", stage="forecast",
                     message=f"⚠️ 已选择 {len(note_games)} 个游戏，预测仅基于主游戏「{game['name']}」执行")
    if isinstance(fc, str):
        method, overrides = fc, {}
    else:
        method = (fc or {}).get("method")
        overrides = {k: v for k, v in (fc or {}).items() if k != "method"}
    if not method:
        return None
    cap = forecast.PREDICTION_CAPABILITIES.get(method)
    if cap is None:
        yield _event("stage", stage="forecast", message=f"⚠️ 未知预测能力「{method}」，跳过预测")
        return None
    # 运行时可见性闸门（P0-12）：外部能力按 meta 的 level/game/owner 隔离，他人个人模型不可按名执行
    if not forecast.can_run_capability(method, game_key):
        yield _event("stage", stage="forecast", message=f"⚠️ 预测能力「{cap.get('name', method)}」无当前游戏/用户权限，跳过预测")
        return None
    if cap.get("input") == "upload":
        yield _event("stage", stage="forecast", message=f"⚠️ 预测能力「{cap.get('name', method)}」为离线上传型，暂不支持自动取数，跳过预测")
        return None

    # 能力默认配置 + 专项覆盖
    cfg = {k: v for k, v in cap.items() if k not in _FORECAST_META_KEYS}
    cfg.update(overrides)

    sql_name = cfg.get("sql")
    # 取数 SQL 加载顺序：专项包内冻结 → 外部模型专属修改 SQL（code/<名>.sql）→ 独立 sql/ 库
    if skill:
        sql_tpl = _read_step_sql(skill, sql_name or "")
    elif method and not forecast.is_builtin(method):
        sql_tpl = code_store.read_model_sql(method)
    else:
        sql_tpl = ""
    if not sql_tpl.strip() and sql_name:
        sql_tpl = sql_store.read_sql(sql_name)
    if not sql_tpl.strip():
        yield _event("stage", stage="forecast", message=f"⚠️ 预测 SQL「{sql_name}」不存在，跳过预测")
        return None

    # 日期窗口：默认按日；granularity=month 时按自然月（历史截止上月末）
    today = date.today()
    granularity = cfg.get("granularity", "day")
    if period:
        # 已确认的指定时间段（如「9月1日~15日」）：历史截止到 period.start 前一天，预测到 period.end。
        # 指定段的回填/对比按日展示——「未来4周」周表只对未来展望有意义，回填对比时不应出现。
        if granularity == "day":
            cfg["display_granularity"] = "day"
        p_start = pd.Timestamp(period["start"])
        p_end = pd.Timestamp(period["end"])
        if granularity == "month":
            hist_months = int(cfg.get("hist_months", 24))
            hist_end = p_start.replace(day=1) - pd.Timedelta(days=1)
            hist_start = hist_end.replace(day=1) - pd.DateOffset(months=hist_months - 1)
            pred_end = p_end
        else:
            hist_days = int(cfg.get("hist_days", 84))
            hist_end = p_start - pd.Timedelta(days=1)
            hist_start = hist_end - timedelta(days=hist_days)
            pred_end = p_end
    elif granularity == "month":
        ref = pd.Timestamp(today)
        hist_end = ref.replace(day=1) - pd.Timedelta(days=1)  # 上月末
        hist_months = int(cfg.get("hist_months", 24))
        horizon_months = int(cfg.get("horizon_months", 6))
        hist_start = hist_end.replace(day=1) - pd.DateOffset(months=hist_months - 1)
        pred_end = hist_end + pd.DateOffset(months=horizon_months)
    else:
        hist_days = int(cfg.get("hist_days", 84))
        # 历史截止到前天（前一天的留存需要「次日的完整活跃数据」才算全，见 22_线上游戏分日流水预测）
        hist_end = today - timedelta(days=2)
        hist_start = hist_end - timedelta(days=hist_days)
        # 预测截止：问题里明确给了「未来N天 / 下个月」时按天外推；否则默认到未来第 4 个
        # 完整自然周（周一~周日）的周日，保证周聚合恰好取到 4 个整周
        hd = overrides.get("horizon_days")
        if hd:
            pred_end = hist_end + timedelta(days=int(hd))
        else:
            first_pred_day = hist_end + timedelta(days=1)
            first_monday = first_pred_day + timedelta(days=(7 - first_pred_day.weekday()) % 7)
            pred_end = first_monday + timedelta(days=27)

    # 币种覆盖：用户要美金/美元预测时，把取数 SQL 的 CNY 换成 USD（模型据此输出 USD）

    sql = (sql_tpl
           .replace("{开始日期}", hist_start.strftime("%Y-%m-%d"))
           .replace("{结束日期}", hist_end.strftime("%Y-%m-%d")))
    sql = games.apply_sql(sql, game["db"])

    yield _event("stage", stage="forecast", message=f"运行预测能力「{cap.get('name', method)}」…")
    yield _event("sql", sql=sql, explain=explain_sql(sql), name=sql_name or "预测取数", db=game["db"])
    # EXPLAIN 预检 + 出错 AI 修正一次（与主步骤一致）
    err = _dry_run_sql(engine, sql, project_key=game["key"])
    if err is not None:
        yield _event("stage", stage="forecast", message="预测 SQL 预检发现问题，AI 修正…")
        try:
            schema_text, _, _ = schema_context.build_sql_context(engine, game["db"], game_key)
            fixed, _ = fix_sql(model, sql, err, schema_text)
            if _dry_run_sql(engine, games.apply_sql(fixed, game["db"]), project_key=game["key"]) is None:
                sql = games.apply_sql(fixed, game["db"])
        except Exception:
            pass  # 修正失败则按原 SQL 尝试执行
    try:
        df_hist = run_raw_sql(engine, sql, project_key=game["key"])
    except Exception as exc:
        yield _event("stage", stage="forecast", message=f"⚠️ 预测取数失败（{exc}），跳过预测")
        return None

    df_hist = _strip_currency_suffix(df_hist)
    if df_hist is None or df_hist.empty:
        yield _event("stage", stage="forecast", message="⚠️ 预测历史数据为空，跳过预测")
        return None

    # 新游月历史不足：分月模型需要≥12个月稳定历史，否则改用分日模型 dau_arpu_roll 预测，
    # 再把每日流水按月汇总成月流水（避免新游起步期 RUU 等序列被指数外推爆表）
    result = None
    if granularity == "month" and len(df_hist) < 12:
        yield _event("stage", stage="forecast",
                     message="新游历史不足，选用分日预测模型，12个月之后才用分月模型")
        daily_cap = forecast.PREDICTION_CAPABILITIES.get("dau_arpu_roll")
        if daily_cap and daily_cap.get("func") is not None and forecast.can_run_capability("dau_arpu_roll", game_key):
            result = _run_daily_as_monthly(engine, game, daily_cap, hist_end, pred_end, overrides)
        if result is None:
            yield _event("stage", stage="forecast", message="⚠️ 分日模型不可用，按原分月模型继续")

    if result is None:
        # 实现函数：外部能力优先用专项包内冻结代码（保证执行准确性）；否则用注册表当前实现
        func = None
        if skill and not forecast.is_builtin(method):
            code = ks.read_skill_model(skill, method)
            if code.strip():
                func = forecast.load_func_from_code(method, code)
        if func is None:
            func = cap.get("func")
        if func is None:
            yield _event("stage", stage="forecast", message=f"⚠️ 预测能力「{method}」无法加载实现，跳过预测")
            return None

        params = {k: v for k, v in cfg.items() if k not in _FORECAST_ORCH_KEYS}
        # 未来周目标（预测达成率用）：有 target_sql 配置时取目标数据，随 params 传给模型按周对齐
        params["df_target"] = _fetch_forecast_target(engine, game, skill, cfg.get("target_sql"))
        try:
            result = func(df_hist, pred_end, **params)
        except Exception as exc:
            yield _event("stage", stage="forecast", message=f"⚠️ 预测计算失败（{exc}），跳过预测")
            return None

    # 回填预测（指定已发生时间段）：同时取实际流水，产出「预测 vs 实际」对比表
    if period and isinstance(result, dict):
        try:
            cmp_df = _forecast_actual_comparison(
                engine, game, result, period, granularity, currency=overrides.get("currency")
            )
            if cmp_df is not None and not cmp_df.empty:
                result.setdefault("tables", []).append(
                    {"name": "预测vs实际流水", "df": cmp_df, "display": True}
                )
                yield _event("stage", stage="forecast", message="✅ 已附实际流水对比表")
        except Exception as exc:
            logger.warning("预测vs实际对比取数失败（不阻断预测结果）：%s", exc)  # 对比取数失败不阻断预测结果

    # 默认未来预测：跑最近 N 天 walk-forward 回测（FER），量化预测误差并给出校准触发依据
    # （技能要求「定期回测最近 1~2 周预测与实际偏差，超阈值需调整模型或人工干预」）
    if granularity == "day" and not period and isinstance(result, dict) and func is not None:
        try:
            bt_days = int(cfg.get("backtest_days", 14))
            bt_thr = float(cfg.get("backtest_fer_threshold", 0.30))
            bdf, bmeta = _forecast_backtest(
                func, df_hist, params, currency=overrides.get("currency"),
                backtest_days=bt_days, threshold=bt_thr,
            )
            if bdf is not None:
                # 回测表只作「校验结果」：数据仍进 query_results 供报告结论/校准判断，
                # 但不展示为图表/表格（display=False 跳过 data 事件与图表生成）
                result.setdefault("tables", []).append(
                    {"name": f"预测回测(FER, 最近{bmeta['days']}天)", "df": bdf, "display": False}
                )
                result.setdefault("meta", {})["backtest"] = bmeta
                if bmeta["over_threshold"]:
                    yield _event("stage", stage="forecast", message=(
                        f"⚠️ 回测 FER 中位 {bmeta['fer_median_pct']}% 超阈值 {bmeta['threshold_pct']}%，"
                        f"预测误差偏大，建议校准模型或人工干预"
                    ))
                else:
                    yield _event("stage", stage="forecast", message=(
                        f"✅ 回测 FER 中位 {bmeta['fer_median_pct']}%（阈值 {bmeta['threshold_pct']}%），预测误差可接受"
                    ))
        except Exception as exc:
            logger.warning("预测回测失败（不阻断预测结果）：%s", exc)  # 回测失败不阻断预测结果

    try:
        return _guard_forecast_result(result)
    except Exception as exc:
        yield _event("stage", stage="forecast", message=f"⚠️ 预测结果异常，跳过：{exc}")
        return None


_FORECAST_MAX_ROWS = 5000
_FORECAST_MAX_COLS = 100


def _guard_forecast_result(result):
    """校验并限流模型返回：只接受 {"tables":[{"name","df","display"}], "meta":{...}}。

    每表限行数/列数，防异常/恶意模型返回巨量或非序列化载荷；违规抛 ValueError。
    """
    if not isinstance(result, dict):
        raise ValueError("模型未返回 dict")
    raw_tables = result.get("tables")
    if raw_tables is None:
        raw_tables = []
    if not isinstance(raw_tables, list):
        raise ValueError("tables 不是列表")
    meta = result.get("meta") if isinstance(result.get("meta"), dict) else {}
    tables = []
    for t in raw_tables:
        if not isinstance(t, dict):
            continue
        df = t.get("df")
        if df is None:
            continue
        if not isinstance(df, pd.DataFrame):
            raise ValueError("table.df 不是 DataFrame")
        if df.shape[0] > _FORECAST_MAX_ROWS or df.shape[1] > _FORECAST_MAX_COLS:
            raise ValueError(f"结果表过大（{df.shape}），已拦截")
        tables.append({"name": str(t.get("name") or ""), "df": df, "display": bool(t.get("display"))})
    return {"tables": tables, "meta": meta}


# 预测结果里仅作内部输入、不展示为图表/表格的表名（数据仍进 query_results 供结论生成）。
# 「流水预测(未来4周)」周聚合表只作为结论（预测达成率/风险）取数，正文不单独出表；
# 展示层改由「流水预测(分日)」折线图承担。
_FORECAST_HIDDEN_TABLES = {"流水预测(未来4周)"}

# 预测结果表 → 前端图表形态：分日明细默认折线图（ARPU 走右轴，避免与 DAU/流水量纲打架），其余默认表格。
_FORECAST_CHART_HINTS = {
    "流水预测(分日)": {"chart_type": "line", "right_axis": ["预测ARPU(CNY)", "预测ARPU(USD)"]},
    "LTV预测曲线": {"chart_type": "line", "right_axis": ["留存ARPU(USD)", "分日LTV增长金额(USD)", "累计LTV(USD)"]},
}


def _forecast_chart_hint(name: str) -> dict:
    """按预测表名给图表提示；未命中的预测表默认按表格展示。"""
    return _FORECAST_CHART_HINTS.get(name, {"chart_type": "table"})


def _emit_forecast_result(req: ChatRequest, model_ver: str, method: str, fc_result, user: dict | None = None):
    """把预测结果 dict 转成 SSE 事件（data/kpi/charts/解读/answer/suggest）。

    首轮命中与二次确认回传两条路径共用，避免结果编排逻辑重复。
    """
    if not fc_result:
        return
    disp: list = []
    for t in fc_result.get("tables", []):
        tname, tdf = t.get("name"), t.get("df")
        if not tname or tdf is None or tdf.empty:
            continue
        if t.get("display") and tname not in _FORECAST_HIDDEN_TABLES:
            tdf.attrs["chart_hint"] = _forecast_chart_hint(tname)  # 分日→折线图，其余→表格（前端默认折叠）
            disp.append((tname, tdf))
            yield _event("data", name=tname, table=df_to_table(tdf))
    primary_df = disp[0][1] if disp else None
    if primary_df is not None and not primary_df.empty:
        kpis = chart.build_kpis(primary_df)
        if kpis:
            yield _event("kpi", kpis=kpis)
    charts = []
    for tname, tdf in disp:
        hint = getattr(tdf, "attrs", {}).get("chart_hint") or {}
        spec = chart.build_chart_spec(tdf, req.chart_type, hint)
        spec["name"] = tname
        charts.append(spec)
    yield _event("charts", charts=charts)
    yield _event("stage", stage="analyze", message="AI 结合历史对话解读…")
    # 只把「展示层」的结果表喂给解读，避免「每天」粒度被内部周表带偏叙述
    answer = analyze.analyze_brief(model_ver, {name: df for name, df in disp},
                                   source_line=f"> 🔮 预测结果来自算法能力《{method}》",
                                   history=build_history_section(req.history or []),
                                   user=user)
    yield _event("answer", markdown=answer)
    # 反写：跑过模型 → 外部模型可「保存优化」草稿（内置能力无独立代码，不提供）
    if not forecast.is_builtin(method):
        try:
            mcode = code_store.read_code(method)
            if mcode.strip():
                yield _event("suggest", model={"action": "update", "target": method, "name": method, "draft": mcode})
        except Exception:
            pass


def _recover_model_from_history(history: list[dict]) -> str | None:
    """从历史里找最近一次「算法预测」命中的能力名（meta.source == "model" 的 skill）。"""
    for m in reversed(history or []):
        if not isinstance(m, dict):
            continue
        meta = m.get("meta")
        if isinstance(meta, dict) and meta.get("source") == "model":
            name = (meta.get("skill") or "").strip()
            if name:
                return name
    return None


def _recover_skill_from_history(history: list[dict]) -> str | None:
    """从历史里找最近一次「专项」命中的专项名（meta.source == "skill" 的 skill）。

    供「重跑一下专项」这类不点名的重跑指令回填上一次跑的专项。
    """
    for m in reversed(history or []):
        if not isinstance(m, dict):
            continue
        meta = m.get("meta")
        if isinstance(meta, dict) and meta.get("source") == "skill":
            name = (meta.get("skill") or "").strip()
            if name:
                return name
    return None


def _recover_sql_from_history(history: list[dict]) -> str | None:
    """从历史里找最近一次 assistant 的已执行 SQL，供「修正上一轮」在其基础上局部改。"""
    for m in reversed(history or []):
        if not isinstance(m, dict):
            continue
        if m.get("role") == "assistant":
            sql = (m.get("sql") or "").strip()
            if sql:
                return sql
    return None


_MAX_CONFIRM_ROUNDS = 2

# AI 现写 SQL 的自纠错上限：生成（第 1 次）+ 最多再修正重试（报错/空结果时触发）
_SQL_MAX_ATTEMPTS = 3


def _confirm_rounds(history: list[dict]) -> int:
    """统计最近连续几轮是「候选确认/澄清」交互（meta.source ∈ candidates/clarify）。

    用于实现「多轮确认后仍不命中 → 强制 SQL 兜底」的轮次闸门。
    """
    n = 0
    for m in reversed(history or []):
        if not isinstance(m, dict):
            break
        meta = m.get("meta")
        if isinstance(meta, dict) and meta.get("source") in ("candidates", "clarify"):
            n += 1
        else:
            break
    return n


_HEADING_RE = re.compile(r"^(#{1,3})[ \t]+(.+?)[ \t]*$", re.MULTILINE)

_GAP_SECTION_RE = re.compile(r"(数据缺口|补数建议|缺口与补数)")

# STE 收尾段（⑤「需要你：」⑥「顺带」）：正式报告里是正文小节之后的收尾段落、不加标题
# （对抗审查 2026-10-23），若模型仍自创了标题，也不能进「报告结构记忆」——否则下次运行
# 被当作固定小节注入，即使无决策也会复刻「需要你」小节。
_STE_TAIL_RE = re.compile(r"(需要你|顺带)")

def _is_gap_section(title: str) -> bool:
    """判断标题是否不属于报告固定小节结构，不应进入「报告结构记忆」。

    两类：独立模块统一生成的「数据缺口 / 补数建议」小节；STE 收尾段（⑤「需要你：」、
    ⑥「顺带」）——它们是动态出现的收尾段落，不是可复用的固定小节。
    """
    return bool(_GAP_SECTION_RE.search(title or "") or _STE_TAIL_RE.search(title or ""))

def _extract_report_structure(markdown_text: str) -> list[str]:
    """从最终报告抽取 1~3 级标题作为「报告结构骨架」，供下次运行沿用（只存结构，不存数字）。"""
    out = []
    for m in _HEADING_RE.finditer(markdown_text or ""):
        title = m.group(2).strip()
        if _is_gap_section(title):
            continue
        out.append(m.group(1) + " " + title)
    return out


def _emit_three_model(query_results, skill_texts, doc_texts, structure=None, user=None, deep_thinking=False):
    """运行三模型交叉验证，把中间事件转成 chat SSE，返回最终报告 markdown。

    structure：上次最终报告的小节骨架；提供时改用两轮模式（生成 → 验证定稿），省掉汇总轮。
    deep_thinking：True 时报告三模型开推理（深度思考，耗时久、放宽超时）。
    """
    skip_summarize = bool(structure)
    gen_md = ver_md = final_md = None
    for ev in run_three_model(build_data_block(query_results), skill_texts, doc_texts,
                              structure=structure, skip_summarize=skip_summarize, user=user,
                              deep_thinking=deep_thinking):
        t = ev["type"]
        if t == "stage":
            yield _event("stage", stage=ev.get("stage"), message=ev.get("message"))
        elif t == "progress":
            yield _event("progress", message=ev.get("message"))
        elif t == "error":
            yield _event("error", message=ev.get("message"))
            return None
        elif t == "markdown":
            stage = ev.get("stage")
            if stage == "generate":
                gen_md = ev["markdown"]
            elif stage == "verify":
                ver_md = ev["markdown"]
            elif stage == "final":
                final_md = ev["markdown"]
    return final_md or ver_md or gen_md


def _resolve_game(question: str, game: dict, game_key: str, engine, ai_target: str | None = None, user: dict | None = None, raw_question: str | None = None):
    """识别用户问题指向的游戏（规则匹配优先，AI target_game 兜底），并展开为「地区家族」。

    返回 (query_games, game, game_key, 提示消息, direct)：
    - query_games：需要查询的游戏列表（同一游戏多地区服时包含全部，否则仅一个）；
    - game / game_key：主游戏（家族里无地区后缀的规范成员），用于 schema/专项/知识库作用域；
    - 提示消息：命中其它游戏或展开多地区时返回一句提示，否则 None；
    - direct：True = 用户明确点名了具体游戏且已直接按其切库（无需游戏二次确认卡）；
      False = 命中来自 AI 归一化或家族展开，维持原确认卡流程。

    点名优先（2026-10-23 用户反馈修复）：规则匹配先于 AI target_game——用户明确打出
    「ro_hmt」时 AI 常把它归一化成家族（ro），导致 7 个地区服全部展开、生成 7 份 SQL；
    明确点名就只查那一个游戏（跨家族也如此：选中 rooc_am 下问 ro_hmt 不再展开 ro 家族）。

    「点名」口径（2026-10-28 用户反馈修复）：只有用户「当前这条消息」（raw_question）
    里出现游戏名才算点名（direct=True）。question 可能是 decide 结合历史补全后的精化问题
    ——历史里 10 轮前提过的游戏名会被 LLM 补全进精化问题，若也当作点名，右上角选中
    rooc_am 也会被静默切到历史里的 kof；这类「历史推断」只能切库但 direct=False，走确认卡。

    越权保护：切库/家族展开只允许落在 effective_games(user) 允许的范围内；
    命中的目标无权访问时留在当前游戏并给出提示（anonymous 用户全放行，与 get_game 口径一致）。
    """
    from backend.ide_app.services.permissions import is_game_allowed

    user = user or {}
    # 1) 规则匹配优先：用户「当前这条消息」明确点名具体游戏（名称/简称/代码 子串匹配，取最长命中）。
    #    raw_question 未传时退回 question（兼容旧调用点，语义等同「当前消息=精化后问题」）。
    raw = raw_question if raw_question is not None else question
    target = games.match_game_in_text(raw)
    named = target is not None  # 目标来自用户当前消息明确点名（direct 语义只对点名生效）
    if target is None:
        # 精化问题（decide 结合历史补全）带出的游戏：切库但不算点名（direct=False）
        target = games.match_game_in_text(question)
    # 2) AI target_game 兜底：规则未命中才用（decide 的语义识别，如「东南亚」→ kof_sea）
    if target is None and ai_target:
        for g in games.get_games(engine):
            if g["key"] == ai_target:
                target = g
                break
    if target is None:
        return [game], game, game_key, None, False
    if not is_game_allowed(user, target["key"]):
        return ([game], game, game_key,
                f"识别到问题指向「{target['name']}」，但你暂无其数据权限，已按当前选中的游戏查询", False)
    # 3) 目标 ≠ 当前选中 → 只查目标那个游戏（不展开家族）。明确点名的不弹确认卡；
    #    AI 归一化命中的维持确认卡（direct=False），防「东南亚」这类语义识别误判。
    if target["key"] != game_key:
        hint = f"问题点名「{target['name']}」（{target['key']}），已按其查询（而非当前选中的 {game_key}）"
        if named:
            hint += "。建议在顶部切换到该游戏，效果最佳。"
        return [target], target, target["key"], hint, named

    # 4) 点名 = 当前选中：选中家族主键（无地区后缀）→ 展开家族；选中具体地区服 → 不展开
    members = [g for g in games.family_members(target, engine) if is_game_allowed(user, g["key"])]
    if not members:
        return [game], game, game_key, None, False
    primary = members[0]
    primary_key = primary["key"]
    # 显式选中的是具体地区服（key 带地区后缀，family_key 归一后 != 原 key）还是家族主键（无后缀时二者相等）。
    # 用 family_key 做显式家族判断，而非拿家族键跟原 key 隐式比较。
    selected_is_region = games.family_key(game_key) != (game_key or "").strip().lower()
    if selected_is_region:
        # 选中具体地区服且点名正是它 → 尊重选择，不展开家族（如选中 rooc_am 就只查 AM）
        return [game], game, game_key, None, False

    if len(members) == 1:
        return [game], game, game_key, None, False
    labels = "、".join(games.region_label(g) for g in members)
    msg = f"识别到「{target['name']}」包含 {len(members)} 个地区服，将同时查询：{labels}"
    return members, primary, primary_key, msg, False


def _spawn_indicator_draft(uid: str, question: str, final_sql: str, game_key: str | None = None) -> None:
    """后台线程生成指标草稿：不阻断取数/解读主流程，失败静默（仅打日志）。"""
    import threading

    def _run():
        try:
            import asyncio
            from ..services import indicator_scan
            result = asyncio.run(indicator_scan.match_and_draft_for_sql(uid, question, final_sql, game_key))
            if result.get("created"):
                print(f"[indicator_draft] created: {(result.get('indicator') or {}).get('metric_name', '')}")
            elif result.get("matched"):
                print(f"[indicator_draft] matched existing: {', '.join(result['matched'])}")
        except Exception as e:  # noqa: BLE001
            print(f"[indicator_draft] skipped: {e}")

    threading.Thread(target=_run, daemon=True).start()


def _china_revenue_fast_path(question: str, game: dict | None) -> bool:
    """Use the verified AliCloud order table for the common China revenue ask."""
    if not game or game.get("key") != "slam_dunk_cn_ali":
        return False
    q = (question or "").lower()
    return any(word in q for word in ("收入", "流水", "充值", "revenue"))


def _run_china_revenue_fast_path():
    """Deterministic smoke path for Slam Dunk China revenue queries.

    This prevents generic reference-platform SQL templates from selecting
    unavailable pf_* views. It deliberately uses the validated ODPS order
    table and emits the same stream primitives as the normal chat pipeline.
    """
    end_day = date.today() - timedelta(days=1)
    start_day = end_day - timedelta(days=6)
    start = start_day.strftime("%Y%m%d")
    end = end_day.strftime("%Y%m%d")
    sql = (
        "SELECT CAST(day AS STRING) AS day, "
        "SUM(CAST(price_show AS DOUBLE)) AS revenue, "
        "COUNT(1) AS orders, COUNT(DISTINCT lcm_id) AS payers "
        "FROM dm_platform.daily_lcx_user_purchase "
        "WHERE CAST(app_id AS STRING) = '13002010' "
        f"AND CAST(day AS BIGINT) BETWEEN {start} AND {end} "
        "AND COALESCE(CAST(price_show AS DOUBLE), 0) > 0 "
        "GROUP BY day ORDER BY day"
    )
    yield _event("stage", stage="query", message="使用灌篮高手中国已验证的阿里云订单明细口径…")
    yield _event("sql", sql=sql, explain="AliCloud MaxCompute / ODPS", name="中国近7日收入", db="AliCloud")
    df = run_raw_sql(None, sql, project_key="slam_dunk_cn_ali")
    if df.empty:
        yield _event("answer", markdown=f"查询窗口 `{start_day}` 至 `{end_day}` 暂无有效订单数据。")
        return
    total = float(pd.to_numeric(df["revenue"], errors="coerce").fillna(0).sum())
    orders = int(pd.to_numeric(df["orders"], errors="coerce").fillna(0).sum())
    payers = int(pd.to_numeric(df["payers"], errors="coerce").fillna(0).sum())
    rows = ["| 日期 | 收入 | 订单数 | 付费用户数 |", "|---|---:|---:|---:|"]
    for _, row in df.iterrows():
        rows.append(f"| {row['day']} | {float(row['revenue']):,.2f} | {int(row['orders'])} | {int(row['payers'])} |")
    markdown = (
        "## 📊 概览\n"
        f"查询窗口：`{start_day}` 至 `{end_day}`；币种：原始 `price_show`；收入口径：有效订单金额之和。\n\n"
        f"合计收入 **{total:,.2f}**，订单 **{orders:,}** 笔，按日付费用户去重后合计 **{payers:,}**（日付费用户不可直接相加为周期去重人数）。\n\n"
        + "\n".join(rows)
    )
    yield _event("data", name="中国近7日收入", table=df_to_table(df))
    yield _event("answer", markdown=markdown)


def _local_backup_revenue_fast_path(question: str, game: dict | None) -> bool:
    # Fail closed for ALL local-backup requests; never enter cloud SQL generation.
    return bool(game and game.get("source_type") == "local_backup")


def _run_local_backup_revenue_fast_path(game: dict, question: str):
    from backend.services.local_backup import read_launch_revenue
    yield _event("stage", stage="query", message="读取已登记的外部备份文件…")
    try:
        out, markdown = read_launch_revenue(question, game)
    except (ValueError, OSError, KeyError) as exc:
        yield _event("answer", markdown=f"本地备份查询未执行：{exc}")
        return
    yield _event("data", name="本地备份经营收入（CNY）", table=df_to_table(out))
    yield _event("answer", markdown=markdown)



def _sentinel_bind(question: str, req: ChatRequest, engine, user, preset_skill=None, ai_target=None):
    """聊天「不选游戏」（game=None）时把提问绑定到具体游戏（可多个）。

    返回 ("run", query_games, game, game_key, note, direct) 或 ("ask", games, preselected, reason)：
    - run：直接绑定执行。query_games 可多个（多选回传/会话延续），game 为主游戏；
      note 为绑定说明（stage 展示）；direct 仅用于语义标记。
    - ask：调用方应发 game_select 多选卡。games 为选项 [{key, name, label}]（label 一律由
      region_label 现算——game dict 无 label 字段），preselected 为默认勾选的 key 列表。

    优先级：target_games 多选回传 > 问题点名 > session_games 会话延续 > preset_skill 绑定游戏 >
    恰 1 款有权限游戏自动绑 > ask 多选卡。所有路径都经 is_game_allowed 过滤；
    target_games/session_games 必须先按 games key 集校验再 resolve（resolve 对未知 key 会
    静默回落默认游戏——直接 resolve 会把伪造 key 变成默认游戏、绕过权限过滤）。
    """
    from backend.ide_app.services.permissions import is_game_allowed

    user = user or {}
    all_games = games.get_games(engine)
    by_key = {g["key"]: g for g in all_games}

    def _valid(keys):
        """先按 key 集校验、再逐项鉴权，返回 [(game)]（保持输入顺序、去重、过滤）。"""
        out, seen = [], set()
        for k in (keys or []):
            k = (k or "").strip()
            g = by_key.get(k)
            if g is None or k in seen:
                continue
            seen.add(k)
            if is_game_allowed(user, k):
                out.append(g)
        return out

    def _ask(options, preselected, reason):
        label_opts = [{"key": g["key"], "name": g["name"], "label": games.region_label(g)} for g in options]
        return "ask", label_opts, preselected, reason

    allowed_list = [g for g in all_games if is_game_allowed(user, g["key"])]
    # 1) 多选卡回传（一次性，优先级最高；全无效 → 重新提问）
    if req.target_games:
        chosen = _valid(req.target_games)
        if chosen:
            primary = chosen[0]
            note = (f"已按所选 {len(chosen)} 个游戏分析："
                    + "、".join(games.region_label(g) for g in chosen)) if len(chosen) > 1 else ""
            return "run", chosen, primary, primary["key"], note, False
        return _ask(allowed_list, [], "所选游戏均无权限或不存在，请重新选择")
    # 2) 问题点名（规则匹配优先，AI target_game 兜底；与 _resolve_game 同口径）
    target = games.match_game_in_text(question)
    if target is None and ai_target:
        for g in all_games:
            if g["key"] == ai_target:
                target = g
                break
    if target is not None:
        # 点名家族主键（无地区后缀）→ 先展开成员∩允许集（评审 L1）：只持成员服权限的用户点名
        # 家族产品（如「拳皇」而仅有 kof_sea 权限）不应得到误导性「无权限」卡，而是预选/直跑其
        # 有权限的成员服；成员全无权才给无权限文案。点名具体地区服 → 精确鉴权，不展开家族。
        if family_key(target["key"]) == target["key"]:
            members = [g for g in games.family_members(target, engine) if is_game_allowed(user, g["key"])]
            if len(members) > 1:
                return _ask(allowed_list, [m["key"] for m in members],
                            f"识别到「{target['name']}」包含 {len(members)} 个地区服，请选择要查询的游戏")
            if len(members) == 1:
                g = members[0]
                # 用户仅有成员服权限时实际执行的是成员 g（≠ 点名的家族主键），文案用成员服标签
                # （与 agent_deep.resolve_cross_game 的 grace 分支同口径，防「已按主键查询」误导）
                return "run", [g], g, g["key"], f"问题点名「{target['name']}」，已按「{games.region_label(g)}」查询", True
            return _ask(allowed_list, [],
                        f"识别到问题指向「{target['name']}」，但你暂无其数据权限，请选择要查询的游戏")
        if not is_game_allowed(user, target["key"]):
            return _ask(allowed_list, [],
                        f"识别到问题指向「{target['name']}」，但你暂无其数据权限，请选择要查询的游戏")
        return "run", [target], target, target["key"], f"问题点名「{target['name']}」，已按其查询", True
    # 3) 会话延续（追问/refine 时前端携带；点名优先于本项）
    if req.session_games:
        chosen = _valid(req.session_games)
        if chosen:
            primary = chosen[0]
            note = f"已沿用上轮选择的游戏分析（{'、'.join(games.region_label(g) for g in chosen)}）" if len(chosen) > 1 else ""
            return "run", chosen, primary, primary["key"], note, False
    # 4) 预设专项的绑定游戏
    if preset_skill:
        try:
            bound = ks.read_skill_meta(preset_skill).get("game")
        except Exception:  # noqa: BLE001
            bound = None
        if bound and bound in by_key:
            if is_game_allowed(user, bound):
                g = by_key[bound]
                return "run", [g], g, g["key"], f"专项「{preset_skill}」绑定游戏「{g['name']}」，已按其查询", False
            return _ask(allowed_list, [], f"专项「{preset_skill}」绑定的游戏暂无权限，请选择要查询的游戏")
    # 5) 恰 1 款有权限游戏 → 自动绑定
    if len(allowed_list) == 1:
        g = allowed_list[0]
        return "run", [g], g, g["key"], f"你仅有「{g['name']}」一款游戏权限，已自动按其查询", False
    # 6) ask 多选卡（全部有权限游戏，无预选）
    return _ask(allowed_list, [], None)

def _sentinel_ensure(req: ChatRequest, engine, user, question, preset_skill=None, ai_target=None):
    """哨兵模式（game=None）的统一绑定入口（generator）：绑定成功 yield 说明并返回
    (query_games, game, game_key, direct)；需要用户选择时发 game_select 多选卡并返回 None。

    调用方拿到 None 必须立即 return（多选卡事件已交付，前端会以 target_games 回传重发）；
    拿到绑定结果时须同步重绑 selected_game = game（game_confirm 比较依赖它）。
    """
    out = _sentinel_bind(question, req, engine, user, preset_skill=preset_skill, ai_target=ai_target)
    if out[0] == "ask":
        _kind, games_opts, preselected, reason = out
        yield _event("game_select", question=question, games=games_opts,
                     preselected=preselected or [], reason=reason)
        yield _event("stage", stage="match", message="待选择分析游戏…")
        return None
    _kind, query_games, game, game_key, note, direct = out
    # 对抗审查三轮 [5][6][8][9]：直接绑定（无多选卡）路径同样回传实际绑定游戏，前端据此
    # 同步 sessionGames——点名/专项绑定/恰1款自动绑/确认链重发后的提炼、合并、追问都拿得到
    # 会话游戏（此前只有多选卡 executeGameSelect 路径会写会话游戏，直接绑定路径提炼必 400）
    yield _event("bound_games", games=[g["key"] for g in query_games], primary=game_key)
    if note:
        yield _event("stage", stage="game", message=note)
    return query_games, game, game_key, direct


def _local_backup_request(req, game, user):
    """Resolve file requests before any model/schema/cloud work; preserve selection."""
    from backend.ide_app.services.permissions import is_game_allowed, can_use_asset
    question = re.sub(r"^\s*【预设专项\s+本地备份文件分析】\s*", "", req.message or "").strip()
    preset = req.preset_skill == "本地备份文件分析" or "【预设专项 本地备份文件分析】" in (req.message or "")
    if game is None:
        by_key = {g["key"]: g for g in games.get_games(None)}
        keys = req.target_games or req.session_games or ([req.target_game] if req.target_game else [])
        chosen = [by_key[k] for k in keys if k in by_key and is_game_allowed(user, k)]
        if len(chosen) == 1:
            game = chosen[0]
    if (preset or (game and game.get("source_type") == "local_backup")) and re.search(r"数数|thinkingdata|\bta\b", question, re.I):
        return True, None, "当前本地备份专项/来源与明确要求的数数在线数据源冲突。请切换专项并选择对应数数项目后确认；未读取本地文件、未生成或执行云端SQL。"
    is_local = bool(game and game.get("source_type") == "local_backup")
    if not is_local and not preset:
        return False, None, question
    if not is_local:
        return True, None, "请先选择本地备份项目，并确认需要查询的收入日期窗口；未调用SQL或模型。"
    if not is_game_allowed(user, game["key"]) or not can_use_asset(user, "sql", None):
        return True, None, "无此项目的数据查询权限。"
    if question.strip("。！! ") in ("继续", "继续查询", "好的", "确认"):
        for item in reversed(req.history or []):
            if item.get("role") != "user":
                continue
            previous = item.get("text") or item.get("content") or ""
            previous = re.sub(r"^\s*【预设专项\s+本地备份文件分析】\s*", "", previous).strip()
            if previous and previous not in ("继续", "继续查询", "好的", "确认"):
                question = previous
                break
    if question.endswith("的收"):
        return True, None, "问题似乎在‘收’处截断，请确认是否查询‘收入’，并补全问题；未调用SQL或模型。"
    return True, game, question


def _handle(req: ChatRequest, game: dict, user: dict = None):
    local_request, local_game, local_question = _local_backup_request(req, game, user)
    if local_request:
        if local_game is None:
            yield _event("answer", markdown=local_question)
        else:
            yield _event("bound_games", games=[local_game["key"]], primary=local_game["key"])
            yield from _run_local_backup_revenue_fast_path(local_game, local_question)
        return
    uid = anonymous_uid(user)  # 指标联动草稿归属（匿名回落 anonymous）
    # 任务→模型单一入口（审计 P1-4）：前端下拉显式传参 > 个人配置（chat 任务允许） > 任务默认
    model = resolve_model_for_task("chat", user, req.model)
    # FiveCross chat routes data through the vendored client bridge; avoid
    # initializing the disabled reference-company SQLAlchemy engine.
    engine = None
    # 聊天解读/复核模型：主对话槽位（2026-10-26 解耦：原读「报告验证轮」配置 model_ver——
    # 验证轮任务默认改 deepseek-v4-flash 后，SQL 检索/复核/结果解读会静默从 pro 降档。
    # 解读/复核是聊天质量环节，跟随主对话槽位，模型管理页可统一调整）
    model_ver = config.task_model("chat")
    game_key = game["key"] if game else None  # 哨兵「不选游戏」模式：game=None，走 _sentinel_ensure 提问绑定
    selected_game = game  # 用户当前选中的游戏（确认卡片里作为「按当前选中」的选项；哨兵模式绑定后重绑）
    query_games = [game] if game else []  # 需要执行 SQL 的游戏库（同一游戏多地区服时为多个；哨兵模式绑定后填充）
    history_text = build_history_section(req.history or [])
    question = (req.message or "").strip()  # 有效取数问题（auto 模式会被对话理解精化）
    if _china_revenue_fast_path(question, game):
        yield from _run_china_revenue_fast_path()
        return
    if _local_backup_revenue_fast_path(question, game):
        yield from _run_local_backup_revenue_fast_path(game, question)
        return
    raw_question = question
    is_refine = False  # 是否「修正上一轮结果」（true 时跳过 SQL 检索，直接基于历史改上一轮 SQL）
    prev_structure = []  # 上次运行本专项的报告结构骨架（命中专项且成功跑过报告后才有值）
    displayed = []  # 每张表格（data 事件）对应的 (名称, DataFrame)，最后逐一各配一张可切换图
    force_sql_name = None  # 候选卡选中某条既有 SQL 时，跳过检索直接跑该 SQL
    force_ai_fallback = False  # 候选卡「都猜错」/ 多轮未命中 → 直接 AI 现写 SQL
    do_auto_report = False  # 未命中且用户已确认「AI 自动生成报告」→ 三模型报告
    sql_explicit = False  # 用户候选卡显式点选的既有 SQL（尊重用户选择）
    rewrite_sql_name = None  # 就近改写确认回传的 SQL 名：以其为底稿改写后执行（未命中既有工件时的优化路径）
    yield _event("stage", stage="start", message=f"使用模型 {model}")

    # 【LLM 前置闸门】进入 AI 管线前先确认 LLM 可用：非管理员未配个人 Key 时立即反馈配置问题，
    # 不再先弹「未命中既有工件，待确认是否由 AI 自动生成报告」确认卡、确认后才报无 LLM。
    # 纯本地应答（问候/日期/无上下文的「重跑专项」反问）不依赖 LLM，先行放行。
    # 2026-10-23 强化：resolve_llm 通过（admin/匿名回落全局 .env）不代表真能连通——服务端无
    # 全局 Key、Key 失效或网关不可达时，此前仍会先弹「自由生成SQL」确认卡、点确认后才报错；
    # 现在改调 ensure_llm_ready 做一次连通性探测（带 TTL 缓存），探测失败在确认卡之前报错。
    # 注：req.model 为空（默认路径）时，上方 resolve_model_for_task 会经 resolve_llm 直接抛
    # LLMNotConfigured，由 /chat 外层 stream() 收口成 error；此处闸门覆盖「显式传 model」这条
    # 路径（resolve_model_for_task 命中显式模型时不校验个人 Key）。两条路径都在确认卡之前报错。
    # 对抗审查 2026-10-23 收口：放行条件必须与「本地应答分支真实存在」对齐——
    # 问候的本地分支只在 preset 模式（下方 _is_greeting 分支），日期的本地分支只在 auto 首轮
    # （_is_date_ask 分支），「重跑专项」反问也只在 auto 首轮——其余组合放行后仍会调 LLM
    # （decide/专项执行/三模型解读），跳过闸门等于把错误挪回确认卡之后。
    is_first_pass = (req.confirm is None and req.game_confirm is None and req.forecast_confirm is None
                     and req.candidate is None and req.ai_report_confirm is None and req.rewrite_confirm is None
                     and req.generate_confirm is None)
    _llm_free = (
        (req.mode == "preset" and _is_greeting(question))
        or (req.mode != "preset" and is_first_pass
            and (_is_date_ask(question)
                 or (_rerun_skill_request(question, game_key)
                     and not _recover_skill_from_history(req.history or []))))
    )
    if not _llm_free:
        try:
            ensure_llm_ready(user)
        except LLMNotConfigured as exc:
            yield _event("error", message=str(exc))
            return

    # 确定专项：preset 用显式选中的专项；auto 先检索，命中则二次确认（confirm 事件）后执行
    if req.mode == "preset":
        skill = req.preset_skill or None
        if not skill:
            raise ValueError("预设专项模式缺少 skill 参数")
        # 提速：纯跑专项（输入无时间/维度/筛选等特殊要求）时，跳过对话理解的 LLM 检索，
        # 只用本地闲聊兜底，直接加载绑定 SQL 执行；有特殊要求才走对话理解识别闲聊/追问。
        if _needs_rewrite(question, skill):
            try:
                decision = conversation.decide(model, req.message, req.history or [], games.get_games(engine), user=user)
            except Exception as e:
                yield _event("stage", stage="match", message=f"对话理解失败（{e}），按取数问题继续")
                decision = {"intent": "query"}
            if decision.get("intent") == "chat":
                yield _event("stage", stage="chat", message="闲聊应答…")
                yield _event("answer", markdown=decision.get("reply") or "有什么数据想让我帮你查吗？")
                return
        elif _is_greeting(question):
            yield _event("stage", stage="chat", message="闲聊应答…")
            yield _event("answer", markdown=f"你好！我是数据分析助手。当前已选中「{skill}」专项，直接发送（或补充说明，如「只看美国」）即可生成分析。")
            return
        # 跨游戏识别：预设专项下也允许用户问其他游戏的数据；哨兵「不选游戏」模式先绑定游戏
        # （优先级含专项绑定游戏：绑了哪个库就按哪个库执行）
        if game is None:
            bound = yield from _sentinel_ensure(req, engine, user, question, preset_skill=skill)
            if bound is None:
                return
            query_games, game, game_key, _direct = bound
            selected_game = game  # 绑定后重绑（game_confirm 比较依赖）
        else:
            query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, user=user)
            if gm:
                yield _event("stage", stage="game", message=gm)
        # 多游戏时按并集校验专项存在性：绑在次选游戏上的专项不应被误报「不存在」
        if len(query_games) > 1:
            skill_ok = any(skill in ks.list_online_skills(g["key"]) for g in query_games)
        else:
            skill_ok = skill in ks.list_online_skills(game_key)
        if not skill_ok:
            raise ValueError(f"专项「{skill}」不存在")
        yield _skill_meta(skill)
        yield _event("stage", stage="match", message=f"已选择专项：{skill}")
    else:
        # is_first_pass 已上提至 LLM 闸门处计算（放行条件要用），这里直接复用
        # 【确定性兜底】首轮用户点名了某个已存在专项名（且非「生成/新建」新专项、非问口径）→ 直接执行该专项，
        # 跳过意图分类（避免「做个X专项分析」被误判成生成草稿）与检索阶段的时间/指标对齐守卫（避免点名了却漏判回落只查SQL）。
        if is_first_pass:
            if game is None:
                # 对抗审查三轮 [18]：哨兵模式 game_key=None 时 list_online_skills(None) 不过滤游戏，
                # 他人个人级/绑他人游戏的项目级专项名会劫持首轮提问流（先按它绑定游戏、
                # 泄露技能→游戏映射，再 H3 复核报错/弹误导性游戏选择卡）。按用户可见性
                # 过滤候选后再匹配（follow 模式 game_key 非 None，list_online_skills 自带过滤，不动）
                explicit_skill = _explicit_skill_name(
                    question, game_key, _sentinel_skill_candidates(user))
            else:
                explicit_skill = _explicit_skill_name(question, game_key)
        else:
            explicit_skill = None
        rerun_skill = _rerun_skill_request(question, game_key) if is_first_pass else None
        if explicit_skill:
            # 哨兵「不选游戏」模式：先绑定游戏（专项绑定的游戏优先）
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, preset_skill=explicit_skill)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            skill = explicit_skill
            # 评审 H3：绑定后的 game_key 可能与绑定前不同（哨兵模式），按绑定结果复核专项可见性，
            # 多游戏时取并集（绑在次选游戏上的专项不应被误报「不存在」）
            if len(query_games) > 1:
                skill_ok = any(skill in ks.list_online_skills(g["key"]) for g in query_games)
            else:
                skill_ok = skill in ks.list_online_skills(game_key)
            if not skill_ok:
                raise ValueError(f"专项「{skill}」不存在或无权访问")
            yield _skill_meta(skill)
            yield _event("stage", stage="match", message=f"命中专项「{skill}」，直接执行")
        elif rerun_skill:
            # 【重跑专项】用户说「重跑一下专项」但没点名是哪个：有上下文就重跑上一次的专项，没上下文就反问，
            # 而不是交给跨源检索去「猜」最相关的 SQL/专项（否则会随机命中如「流水达成.sql」这类不相关的工件）。
            # 与 explicit_skill 一样直接短路、跳过 conversation.decide——否则 decide 会把「重跑专项」
            # 精化出「最近/上周」等词，反而把纯重跑误判成有改写意图，触发运行时改写拖慢出报告。
            last_skill = _recover_skill_from_history(req.history)
            if last_skill and last_skill in ks.list_online_skills(game_key):
                # 哨兵「不选游戏」模式：先绑定游戏（上次专项绑定的游戏优先）
                if game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, preset_skill=last_skill)
                    if bound is None:
                        return
                    query_games, game, game_key, _direct = bound
                    selected_game = game
                else:
                    query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, user=user)
                    if gm:
                        yield _event("stage", stage="game", message=gm)
                skill = last_skill
                # 评审 H3：绑定后的 game_key 可能与绑定前不同（哨兵模式），按绑定结果复核专项可见性
                if len(query_games) > 1:
                    skill_ok = any(skill in ks.list_online_skills(g["key"]) for g in query_games)
                else:
                    skill_ok = skill in ks.list_online_skills(game_key)
                if not skill_ok:
                    raise ValueError(f"专项「{skill}」不存在或无权访问")
                yield _skill_meta(skill)
                yield _event("stage", stage="match", message=f"重跑上次专项「{skill}」")
            else:
                yield _event("meta", source="clarify")
                yield _event("stage", stage="clarify", message="需要补充信息…")
                yield _event("answer", markdown="你想重跑哪个专项？请告诉我专项名（例如「重跑流水达成分析专项」）。")
                return
        elif is_first_pass:
            # 确定性日期应答：纯「今天几号/星期几」直接返回真实日期，不进模型
            if _is_date_ask(question):
                yield _event("stage", stage="chat", message="应答日期…")
                yield _event("answer", markdown=_today_reply())
                return
            # 第一遍：先做对话理解（闲聊 / 追问澄清 / 取数），再决定是否检索专项
            yield _event("stage", stage="match", message="理解你的问题…")
            try:
                decision = conversation.decide(model, req.message, req.history or [], games.get_games(engine), user=user)
            except Exception as e:
                yield _event("stage", stage="match", message=f"对话理解失败（{e}），按取数问题继续")
                decision = {"intent": "query", "refined_question": question}
            intent = decision["intent"]
            if intent == "chat":
                yield _event("stage", stage="chat", message="闲聊应答…")
                yield _event("answer", markdown=decision["reply"] or "有什么数据想让我帮你查吗？")
                return
            if intent == "clarify":
                # 多轮澄清仍未明确 → 不再追问，落到底部 query 路径（统一检索 / SQL 兜底）
                if _confirm_rounds(req.history or []) >= _MAX_CONFIRM_ROUNDS:
                    yield _event("stage", stage="clarify", message="多轮澄清仍未明确，按取数问题继续…")
                    intent = "query"
                else:
                    yield _event("meta", source="clarify")
                    yield _event("stage", stage="clarify", message="需要补充信息…")
                    yield _event("answer", markdown=decision["clarify_question"] or "能再具体说说想查什么吗？")
                    return
            if intent == "knowledge":
                # 知识/口径问答：检索知识库总结作答（纯文本，不取数、不生成 SQL）。
                # 哨兵「不选游戏」模式也必须先绑定游戏——否则 game_key=None 会跳过
                # answer_knowledge 的 visible_to 隔离，跨游戏/跨用户作答。
                question = decision["refined_question"] or question
                if game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=decision.get("target_game"))
                    if bound is None:
                        return
                    query_games, game, game_key, direct = bound
                    selected_game = game
                    gm = None
                else:
                    query_games, game, game_key, gm, direct = _resolve_game(question, game, game_key, engine, decision.get("target_game"), user=user, raw_question=raw_question)
                    if gm:
                        yield _event("stage", stage="game", message=gm)
                # 历史推断出的目标游戏与当前选中不一致 → 先确认再作答（与 query/model 同口径）
                resolved_changed = (selected_game is not None
                                    and (game_key != selected_game["key"]
                                         or any(g["key"] != selected_game["key"] for g in query_games)))
                if gm is not None and resolved_changed and not direct:
                    yield _event("game_confirm",
                                 question=question,
                                 games=[{"key": g["key"], "name": g["name"], "label": games.region_label(g)} for g in query_games],
                                 target_game=game_key,
                                 current={"key": selected_game["key"], "name": selected_game["name"]},
                                 reason=gm, source="knowledge")
                    yield _event("stage", stage="match", message="待确认分析项目…")
                    return
                yield _event("stage", stage="match", message="检索知识库作答…")
                try:
                    answer = kb_qa.answer_knowledge(model, question, game_key, history=history_text, user=user)
                except Exception as e:
                    answer = f"知识库问答失败：{e}"
                yield _event("answer", markdown=answer)
                return
            if intent == "model":
                # 算法/预测：选能力 → 取数 → 跑模型 → 出结果表
                question = decision["refined_question"] or question
                if game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=decision.get("target_game"))
                    if bound is None:
                        return
                    query_games, game, game_key, direct = bound
                    selected_game = game
                    gm = None
                else:
                    query_games, game, game_key, gm, direct = _resolve_game(question, game, game_key, engine, decision.get("target_game"), user=user, raw_question=raw_question)
                    if gm:
                        yield _event("stage", stage="game", message=gm)
                # 历史推断出的目标游戏与当前选中不一致 → 先确认再预测（2026-10-28 用户反馈：
                # 右上角 rooc_am、10 轮前提过拳皇时预测被静默切到拳皇）。明确点名才 direct=直跑。
                resolved_changed = (selected_game is not None
                                    and (game_key != selected_game["key"]
                                         or any(g["key"] != selected_game["key"] for g in query_games)))
                if gm is not None and resolved_changed and not direct:
                    yield _event("game_confirm",
                                 question=question,
                                 games=[{"key": g["key"], "name": g["name"], "label": games.region_label(g)} for g in query_games],
                                 target_game=game_key,
                                 current={"key": selected_game["key"], "name": selected_game["name"]},
                                 reason=gm, source="model")
                    yield _event("stage", stage="match", message="待确认分析项目…")
                    return
                yield from _model_forecast_flow(model, engine, game, game_key, question, query_games, req, model_ver, user)
                return
            if intent == "modify":
                # 能力3反写：用户对上一轮预测结果质疑、要改预测代码 → 改代码出草稿，而不是重新预测
                question = decision["refined_question"] or question
                # 哨兵「不选游戏」模式：绑定游戏（match_model 需要 game_key）
                if game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=decision.get("target_game"))
                    if bound is None:
                        return
                    query_games, game, game_key, _direct = bound
                    selected_game = game
                yield _event("stage", stage="match", message="理解你对预测代码的修改需求…")
                method = _recover_model_from_history(req.history) or decision.get("modify_target")
                if method and method not in forecast.PREDICTION_CAPABILITIES:
                    method = None
                if not method:
                    try:
                        method = model_run.match_model(model, question, game_key, user=user)
                    except Exception:
                        method = None
                if not method:
                    yield _event("answer", markdown=(
                        "没有找到你上一轮用到的预测能力，无法确定要改哪段代码。"
                        "请先跑一次预测，或在反馈里点明能力名（如「修改 dau_arpu_roll 的代码」）。"
                    ))
                    return
                yield _event("meta", source="model", skill=method, flagged=False)
                cap = forecast.PREDICTION_CAPABILITIES[method]
                is_builtin = forecast.is_builtin(method)
                if is_builtin:
                    existing = ""
                    meta = {}
                    bound_sqls = [cap.get("sql")] if cap.get("sql") else []
                    doc_names = []
                    desc = (
                        f"{question}\n\n（基于当前内置预测能力《{cap.get('name', method)}》："
                        f"{cap.get('desc', '')}，在其思路上按上述意见修改）"
                    )
                else:
                    existing = code_store.read_code(method)
                    meta = code_store.read_code_meta(method)
                    bound_sqls = [meta.get("sql")] if isinstance(meta, dict) and meta.get("sql") else []
                    doc_names = [s.get("name") for s in (meta.get("sources") or []) if isinstance(s, dict) and s.get("kind") == "doc"]
                    desc = question
                yield _event("stage", stage="generate", message=f"按反馈修改预测代码（{method}）…")
                try:
                    result = model_gen.generate_model(model, desc, bound_sqls, doc_names, existing=existing)
                except Exception as exc:
                    yield _event("error", message=f"修改预测代码失败：{exc}")
                    return
                new_code = (result.get("code") or "").strip()
                if not new_code:
                    yield _event("error", message="AI 未返回修改后的代码，请重试")
                    return
                if is_builtin:
                    # 内置能力代码不可覆盖 → 另存为新模型名（保存后即可作为新能力用于预测）
                    name = f"{method}_修改"
                    slot = {
                        "action": "new",
                        "target": None,
                        "name": name,
                        "draft": new_code,
                        "manifest": {
                            "sql": cap.get("sql", ""),
                            "granularity": cap.get("granularity", "day"),
                            "hist_days": cap.get("hist_days"),
                            "hist_months": cap.get("hist_months"),
                            "horizon_days": cap.get("horizon_days"),
                            "horizon_months": cap.get("horizon_months"),
                            "window": cap.get("window"),
                            "desc": f"由内置能力《{cap.get('name', method)}》按用户反馈修改",
                        },
                        "sources": result.get("sources") or [],
                        "transformed_sqls": result.get("transformed_sqls") or {},
                    }
                else:
                    slot = {
                        "action": "update",
                        "target": method,
                        "name": method,
                        "draft": new_code,
                        "manifest": meta,
                        "sources": result.get("sources") or [],
                        "transformed_sqls": result.get("transformed_sqls") or {},
                    }
                yield _event("suggest", model=slot)
                note = "暂不支持在聊天窗口保存算法模型，请到「分析配置 → 算法管理」中维护。"
                yield _event("answer", markdown=f"已按你的反馈修改预测代码《{method}》。\n\n{note}")
                return
            if intent == "generate":
                # 能力 1：AI 自动生成 SQL/模型/专项 → 扫描→生成→关联→改造→冻结 → 草稿卡待确认
                question = decision["refined_question"] or question
                if game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=decision.get("target_game"))
                    if bound is None:
                        return
                    query_games, game, game_key, _direct = bound
                    selected_game = game
                else:
                    query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, decision.get("target_game"), user=user, raw_question=raw_question)
                    if gm:
                        yield _event("stage", stage="game", message=gm)
                target = decision.get("generate_target") or "sql"
                label = {"sql": "SQL", "model": "模型", "skill": "专项"}.get(target, "SQL")
                if target == "model":
                    # 需求：暂不允许在聊天窗口生成算法模型，引导到算法管理
                    yield _event("answer", markdown="暂不支持在聊天窗口生成算法模型，请到「分析配置 → 算法管理」中创建。")
                    return
                if target == "skill":
                    # 「生成 X 专项」里的 X 其实已存在 → 不重复生成草稿，直接执行已有专项（确认后）
                    existing = _existing_skill_in_message(question, game_key)
                    if existing:
                        yield _event("confirm", skill=existing, summary=skill_match.summarize_skill_text(existing), question=question, game=game_key)
                        yield _event("stage", stage="match", message=f"检测到专项「{existing}」已存在，直接执行，不再生成草稿")
                        return
                    # 生成专项草稿耗时较长 → 先人为确认，再进入耗时生成
                    if req.generate_confirm != "ok":
                        yield _event("generate_confirm", question=question, target_game=game_key)
                        yield _event("stage", stage="match", message="生成专项草稿耗时较长，请确认是否继续")
                        return
                yield _event("stage", stage="match", message=f"生成{label}草稿…")
                try:
                    if target == "skill":
                        result = generate_flow.generate_skill_flow(model, question, game, engine)
                    else:
                        result = generate_flow.generate_sql_flow(model, question, game, engine)
                except Exception as exc:
                    yield _event("error", message=str(exc))
                    return
                yield _event("generate", **result)
                return
            # intent == query：用精化后的问题继续取数（追问/指代已补全）
            if decision.get("route_deep"):
                # 智能路由（聊天窗口 1+2）：探索性/开放性分析问题 → 普通模式单发检索/候选卡/SQL 生成
                # 命中率低且易答偏，直接交给深度分析 Agent（多步检索+取数验证+图表）。前端收到
                # route_deep 事件后用同一问题自动切换深度分析流（用户无感）。refine/点名专项/
                # 常规取数不受影响（conversation.decide 已保证 refine=false 才置位）。
                yield _event("meta", source="deep")
                yield _event("stage", stage="deep", message="识别为探索性分析问题，切换深度分析…")
                yield _event("route_deep", question=question,
                             refined_question=decision.get("refined_question") or question)
                return
            question = decision["refined_question"] or question
            # 跨游戏识别：问题点名具体游戏时规则匹配优先（direct=直接按其查询，不弹确认卡）；
            # 规则未命中才用 AI target_game 兜底（AI 归一化命中仍需确认卡，防误判切换）。
            # 哨兵「不选游戏」模式：绑定即确认（game_select 多选卡就是确认机制），不再弹 game_confirm。
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=decision.get("target_game"))
                if bound is None:
                    return
                query_games, game, game_key, direct = bound
                selected_game = game  # 绑定后重绑（game_confirm 比较依赖）
                gm = None
            else:
                query_games, game, game_key, gm, direct = _resolve_game(question, game, game_key, engine, decision.get("target_game"), user=user, raw_question=raw_question)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            if decision.get("refine"):
                # 用户指出上一轮结果哪里不对：跳过专项检索/二次确认，直接基于历史里的
                # 上一轮 SQL/结论做局部调整后重跑（history 已随请求带入）
                skill = None
                is_refine = True
                yield _event("stage", stage="match", message="按你的反馈修正上一轮逻辑并重跑…")
            else:
                # 目标项目与当前选中不一致 / 跨地区 → 先二次确认再检索。
                # 用户明确点名具体游戏（direct）时不弹卡：点名的意图无歧义，已按点名校验过权限。
                # 仅当解析结果确实偏离当前选中才弹卡：越权被拒时解析结果留在当前游戏，
                # 此时只显示上面的提示（gm 非 None 但无需确认），直接继续检索。
                # 哨兵模式（selected_game 初始为 None、绑定后已重绑）下 gm 恒为 None，不进确认卡：
                # game_select 多选卡本身就是该模式的确认机制。显式判空是兜底，防任何路径漏绑。
                resolved_changed = (selected_game is not None
                                    and (game_key != selected_game["key"]
                                         or any(g["key"] != selected_game["key"] for g in query_games)))
                if gm is not None and resolved_changed and not direct:
                    yield _event("game_confirm",
                                 question=question,
                                 games=[{"key": g["key"], "name": g["name"], "label": games.region_label(g)} for g in query_games],
                                 target_game=game_key,
                                 current={"key": selected_game["key"], "name": selected_game["name"]},
                                 reason=gm)
                    yield _event("stage", stage="match", message="待确认分析项目…")
                    return
                # 跨源统一检索：SQL / 知识库 / 专项 / 算法模型 哪个符合
                yield _event("stage", stage="match", message="检索 SQL/知识库/专项/模型…")
                try:
                    ret = retrieval.retrieve_candidates(model, question, game_key, needs_confirm=decision.get("needs_confirm"), user=user)
                except Exception as e:
                    yield _event("stage", stage="match", message=f"统一检索失败（{e}），按只查SQL继续")
                    ret = {"candidates": [], "best": None, "ambiguous": False}
                # 命中率兜底：对话理解常把「最近」补成「最近7天」，既而因时间窗口冲突漏掉
                # 「上一自然周」的既有 SQL/专项。0 命中时再用用户原话检索一次（原话保留模糊措辞，
                # 往往能直接命中既有工件，比 AI 现写更准、更快）。
                if not ret["best"] and not ret["candidates"]:
                    orig_q = (req.message or "").strip()
                    if orig_q and orig_q != question:
                        try:
                            ret2 = retrieval.retrieve_candidates(model, orig_q, game_key, needs_confirm=False, user=user)
                        except Exception:
                            ret2 = None
                        if ret2:
                            if not ret["indicators"] and ret2.get("indicators"):
                                ret["indicators"] = ret2["indicators"]
                            if not ret["candidates"] and not ret2["candidates"]:
                                # 原话命中候选才整体替换（best 同步）
                                ret = ret2
                # 指标通道（审计 P1-1）：命中「已确认指标」只做过程展示，口径已注入 SQL 生成上下文
                if ret.get("indicators"):
                    names = "、".join(f"「{i['name']}」" for i in ret["indicators"])
                    yield _event("stage", stage="match", message=f"命中已确认指标口径 {names}，SQL 生成优先采用其公式")
                if ret["ambiguous"]:
                    # 命中多个候选 / 低置信：多轮后仍不命中则强制 SQL 兜底；有候选才出卡；否则直接 AI 现写
                    if _confirm_rounds(req.history) >= _MAX_CONFIRM_ROUNDS:
                        skill = None
                        force_ai_fallback = True
                        yield _event("stage", stage="match", message="多轮仍未命中，AI 现写 SQL…")
                    elif not ret["candidates"]:
                        # 低置信但四通道全空：不出空候选卡，直接 AI 现写 SQL
                        skill = None
                        force_ai_fallback = True
                        yield _event("stage", stage="match", message="低置信且未命中既有工件，AI 现写 SQL…")
                    else:
                        yield _event("meta", source="candidates")
                        yield _event("candidates",
                                     candidates=[{"type": c["type"], "name": c["name"], "label": c["label"], "summary": c["summary"]} for c in ret["candidates"]],
                                     question=question, game=game_key)
                        yield _event("stage", stage="match", message=f"命中 {len(ret['candidates'])} 个候选，待确认…")
                        return
                elif ret["best"]:
                    # 唯一命中：按类型直接执行
                    ctype, cname = ret["best"]["type"], ret["best"]["name"]
                    if ctype == "skill":
                        skill = cname
                        yield _skill_meta(skill)
                        yield _event("stage", stage="match", message=f"命中专项「{skill}」，直接执行")
                    elif ctype == "sql":
                        skill = None
                        force_sql_name = cname
                        yield _event("meta", source="sql", skill=cname, flagged=False)
                        yield _event("stage", stage="match", message=f"命中既有 SQL「{cname}」，直接运行")
                    elif ctype == "doc":
                        skill = None
                        yield _event("stage", stage="match", message="检索知识库作答…")
                        try:
                            answer = kb_qa.answer_knowledge(model, question, game_key, history=history_text, user=user)
                        except Exception as e:
                            answer = f"知识库问答失败：{e}"
                        yield _event("answer", markdown=answer)
                        return
                    else:  # model
                        skill = None
                        yield _event("meta", source="model", skill=cname, flagged=False)
                        hint = forecast.parse_forecast_hint(question)
                        period = forecast.parse_forecast_period(question)
                        if period and (period.get("past") or period.get("year_ambiguous")):
                            yield _event("forecast_confirm", method=cname, question=question, target_game=game_key, **period)
                            yield _event("stage", stage="forecast", message=f"命中预测能力「{cname}」，待确认预测时间段…")
                            return
                        if period:
                            yield _event("stage", stage="forecast", message=f"命中预测能力「{cname}」，预测 {period['start']} ~ {period['end']}…")
                            fc_result = yield from _run_forecast(model, engine, game, game_key, {"method": cname, **hint}, period=period, note_games=query_games)
                            yield from _emit_forecast_result(req, model_ver, cname, fc_result, user)
                            return
                        yield _event("stage", stage="forecast", message=f"命中预测能力「{cname}」，取数并预测…")
                        fc_result = yield from _run_forecast(model, engine, game, game_key, {"method": cname, **hint}, note_games=query_games)
                        yield from _emit_forecast_result(req, model_ver, cname, fc_result, user)
                        return
                else:
                    # 0 命中：AI 现写 SQL（兜底）
                    skill = None
                    force_ai_fallback = True
                    yield _event("stage", stage="match", message="未命中既有工件，AI 现写 SQL…")
        elif req.candidate is not None:
            # 候选卡回传：用户点选了某个候选（或「都猜错 → AI 现写 SQL」）
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            if req.candidate == "":
                # 都猜错 → AI 现写 SQL
                skill = None
                force_sql_name = None
                force_ai_fallback = True
                yield _event("stage", stage="match", message="按你的选择，AI 现写 SQL…")
            else:
                try:
                    choice = json.loads(req.candidate)
                except Exception:
                    choice = {}
                ctype = choice.get("type")
                cname = (choice.get("name") or "").strip()
                # 多游戏时并集校验：绑在次选游戏上的专项不应被误判非法
                skill_ok = cname in ks.list_online_skills(game_key) if len(query_games) <= 1 else any(
                    cname in ks.list_online_skills(g["key"]) for g in query_games)
                if ctype == "skill" and skill_ok:
                    skill = cname
                    yield _skill_meta(skill)
                    yield _event("stage", stage="match", message=f"已确认专项：{skill}")
                elif ctype == "sql":
                    skill = None
                    force_sql_name = cname
                    sql_explicit = True
                    yield _event("meta", source="sql", skill=cname, flagged=False)
                    yield _event("stage", stage="match", message=f"命中既有 SQL「{cname}」，直接运行")
                elif ctype == "doc":
                    skill = None
                    yield _event("stage", stage="match", message="检索知识库作答…")
                    try:
                        answer = kb_qa.answer_knowledge(model, question, game_key, history=history_text, user=user)
                    except Exception as e:
                        answer = f"知识库问答失败：{e}"
                    yield _event("answer", markdown=answer)
                    return
                elif ctype == "model" and cname in forecast.PREDICTION_CAPABILITIES:
                    skill = None
                    from backend.ide_app.services.permissions import has_perm
                    if not has_perm(user, "model_use"):
                        yield _event("error", message="你没有「算法使用」权限，无法使用预测/算法能力。")
                        return
                    yield _event("meta", source="model", skill=cname, flagged=False)
                    hint = forecast.parse_forecast_hint(question)
                    period = forecast.parse_forecast_period(question)
                    if period and (period.get("past") or period.get("year_ambiguous")):
                        yield _event("forecast_confirm", method=cname, question=question, target_game=game_key, **period)
                        yield _event("stage", stage="forecast", message=f"命中预测能力「{cname}」，待确认预测时间段…")
                        return
                    if period:
                        yield _event("stage", stage="forecast", message=f"命中预测能力「{cname}」，预测 {period['start']} ~ {period['end']}…")
                        fc_result = yield from _run_forecast(model, engine, game, game_key, {"method": cname, **hint}, period=period, note_games=query_games)
                        yield from _emit_forecast_result(req, model_ver, cname, fc_result, user)
                        return
                    yield _event("stage", stage="forecast", message=f"命中预测能力「{cname}」，取数并预测…")
                    fc_result = yield from _run_forecast(model, engine, game, game_key, {"method": cname, **hint}, note_games=query_games)
                    yield from _emit_forecast_result(req, model_ver, cname, fc_result, user)
                    return
                else:
                    # 未知/非法候选 → 兜底 AI 现写
                    skill = None
                    force_sql_name = None
                    force_ai_fallback = True
                    yield _event("stage", stage="match", message="未识别候选，AI 现写 SQL…")
        elif req.rewrite_confirm is not None:
            # 就近改写二次确认回传：""=不改写、AI现写新SQL；"<SQL名>"=以该SQL为底稿改写后执行
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            skill = None
            force_sql_name = None
            do_auto_report = False
            if req.rewrite_confirm == "":
                # 不改写 → 回落到普通 AI 现写（跳过后续二次确认，直接生成+简短解读）
                force_ai_fallback = True
                rewrite_sql_name = None
                yield _event("stage", stage="match", message="按你的选择：AI 现写新 SQL…")
            else:
                name = req.rewrite_confirm.strip()
                if name in sql_store.list_sql_files(game_key):
                    force_ai_fallback = False
                    rewrite_sql_name = name
                    yield _event("meta", source="rewrite", skill=name, flagged=True)
                    yield _event("stage", stage="match", message=f"就近改写既有 SQL「{name}」后执行…")
                else:
                    # 就近 SQL 已不存在/非法 → 兜底 AI 现写
                    force_ai_fallback = True
                    rewrite_sql_name = None
                    yield _event("stage", stage="match", message="就近 SQL 不存在，AI 现写新 SQL…")
        elif req.ai_report_confirm is not None:
            # AI 自动生成报告二次确认回传："ok"=确认生成报告；""=只查SQL（不出报告）
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            skill = None
            force_sql_name = None
            force_ai_fallback = True
            do_auto_report = (req.ai_report_confirm == "ok")
            yield _event("stage", stage="match", message=(
                "已确认：AI 自动生成报告（现写 SQL → 三模型报告）…" if do_auto_report
                else "按你的选择：AI 现写 SQL（只取数，不出报告）…"))
        elif req.forecast_confirm is not None:
            # 预测二次确认回传：用户已确认预测时间段/年份，按该时间段回填预测（如「9月份每天流水」）
            from backend.ide_app.services.permissions import has_perm
            if not has_perm(user, "model_use"):
                yield _event("error", message="你没有「算法使用」权限，无法使用预测/算法能力。")
                return
            try:
                fc_data = json.loads(req.forecast_confirm or "{}")
            except Exception:
                fc_data = {}
            method = fc_data.get("method") or _recover_model_from_history(req.history)
            if method not in forecast.PREDICTION_CAPABILITIES:
                yield _event("error", message="未找到对应的预测能力，请重新发起预测")
                return
            start, end = fc_data.get("start"), fc_data.get("end")
            if not start or not end:
                yield _event("error", message="预测时间段缺失，请重新发起预测")
                return
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=fc_data.get("target_game") or req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, fc_data.get("target_game"), user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            yield _event("meta", source="model", skill=method, flagged=False)
            yield _event("stage", stage="forecast", message=f"已确认预测时间段 {start} ~ {end}，取数并预测…")
            # 二次确认回传也要保留「每天/逐日」等展示粒度提示（首轮已解析、此处需重新解析）
            hint = forecast.parse_forecast_hint(question)
            fc_result = yield from _run_forecast(
                model, engine, game, game_key, {"method": method, **hint},
                period={"start": start, "end": end}, note_games=query_games,
            )
            yield from _emit_forecast_result(req, model_ver, method, fc_result, user)
            return
        elif req.generate_confirm is not None:
            # 生成专项草稿二次确认回传："ok"=确认生成；否则取消生成
            if req.generate_confirm != "ok":
                yield _event("answer", markdown="已取消生成专项草稿。")
                return
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            yield _event("stage", stage="match", message="生成专项草稿…")
            try:
                result = generate_flow.generate_skill_flow(model, question, game, engine)
            except Exception as exc:
                yield _event("error", message=str(exc))
                return
            yield _event("generate", **result)
            return
        elif req.game_confirm is not None:
            # 游戏二次确认回传：ok=按解析出的项目；""=按当前选中游戏。
            # 哨兵「不选游戏」模式（含 follow 弹卡后切 none 再确认的陈旧回传）→ 走哨兵绑定兜底。
            if req.game_confirm == "":
                if selected_game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                    if bound is None:
                        return
                    query_games, game, game_key, _direct = bound
                    selected_game = game
                else:
                    query_games = [selected_game]
                    game = selected_game
                    game_key = selected_game["key"]
                    yield _event("stage", stage="game", message=f"按当前选中游戏「{selected_game['name']}」分析")
            else:
                if game is None:
                    bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                    if bound is None:
                        return
                    query_games, game, game_key, _direct = bound
                    selected_game = game
                else:
                    query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                    if gm:
                        yield _event("stage", stage="game", message=gm)
                yield _event("stage", stage="match", message="已确认分析项目…")
            # 按来源意图路由回对应流程：model → 预测；knowledge → 知识库作答；query（缺省）→ 下方专项检索。
            # game_confirm_source 仅由 model/knowledge 路径的确认卡回传，旧 query 路径回传为空 → 走默认专项检索。
            if req.game_confirm_source == "model":
                yield from _model_forecast_flow(model, engine, game, game_key, question, query_games, req, model_ver, user)
                return
            if req.game_confirm_source == "knowledge":
                yield _event("stage", stage="match", message="检索知识库作答…")
                try:
                    answer = kb_qa.answer_knowledge(model, question, game_key, history=history_text, user=user)
                except Exception as e:
                    answer = f"知识库问答失败：{e}"
                yield _event("answer", markdown=answer)
                return
            try:
                skill = skill_match.match_skill(model, question, game_key, user=user)
            except Exception as e:
                yield _event("stage", stage="match", message=f"专项匹配失败（{e}），按只查SQL继续")
                skill = None
            if skill:
                yield _event("confirm", skill=skill, summary=skill_match.summarize_skill_text(skill), question=question, game=game_key)
                yield _event("stage", stage="match", message=f"命中专项「{skill}」，等待确认…")
                return
            yield _event("stage", stage="match", message="未命中专项，检索既有 SQL…")
        elif req.confirm == "":
            # 用户选择「只查SQL」
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            skill = None
            yield _event("stage", stage="match", message="只查SQL：检索既有 SQL…")
        else:
            # 用户确认按某专项执行（建议项或换选的专项）
            if game is None:
                bound = yield from _sentinel_ensure(req, engine, user, question, ai_target=req.target_game)
                if bound is None:
                    return
                query_games, game, game_key, _direct = bound
                selected_game = game
            else:
                query_games, game, game_key, gm, _direct = _resolve_game(question, game, game_key, engine, req.target_game, user=user)
                if gm:
                    yield _event("stage", stage="game", message=gm)
            skill = req.confirm
            # 多游戏时并集校验：绑在次选游戏上的专项不应被误报「不存在」
            if len(query_games) > 1:
                skill_ok = any(skill in ks.list_online_skills(g["key"]) for g in query_games)
            else:
                skill_ok = skill in ks.list_online_skills(game_key)
            if not skill_ok:
                raise ValueError(f"专项「{skill}」不存在")
            yield _skill_meta(skill)
            yield _event("stage", stage="match", message=f"已确认专项：{skill}")

    # 该专项若已有订阅报告，通知前端可「换日期调出」（仅本人订阅，个人隔离）
    if skill:
        subs = [s for s in subscriptions.list_subscriptions(owner=owner_key(user)) if s.get("skill") == skill]
        if subs:
            yield _event("subscriptions", skill=skill, subscriptions=subs)

    if skill:
        meta = ks.read_skill_meta(skill)
        # 使用权限点 + 机密档位闸门（专项执行只看专项自身档位；其绑定 SQL/文档/预测按专项等级执行，
        # 不在此处逐个校验——「一切以专项的机密等级为准」）
        from backend.ide_app.services.permissions import can_use_asset
        if not can_use_asset(user, "skill", meta.get("confidentiality")):
            yield _event("error", message="你没有「专项使用」权限，或该专项的机密等级超出你的授权，无法执行。")
            return
        sqls = meta.get("sqls", []) or []
        doc_names = meta.get("docs", []) or []
        skill_texts = [ks.read_skill(skill)] if ks.read_skill(skill).strip() else []
        _notes = ks.read_skill_notes(skill)
        if _notes.strip():
            skill_texts.append(f"# 本专项补充口径与经验（专项笔记）\n\n{_notes}")
        doc_texts = _doc_pairs(doc_names, game_key, skill=skill)
    else:
        sqls = []
        skill_texts = [ks.read_skill(s) for s in _visible_online_skills(user, game_key) if ks.read_skill(s).strip()]
        doc_names = [d for d in list(req.docs) if d in _visible_docs(user, game_key)]
        doc_texts = _doc_pairs(doc_names, game_key)
        # 未命中：通篇扫描（专项 + 知识库 + 取数代码），AI 兜底生成——扫描也按使用权限点 + 档位过滤
        all_docs = [d for d in _visible_docs(user, game_key) if d not in doc_names]
        doc_texts += _doc_pairs(all_docs, game_key)

    # 组装待执行的 SQL：命中专项用其预配置步骤（先让 AI 按专项方法 + 用户问题改写，再执行）；否则 AI 现写一条
    if sqls:
        skill_text = skill_texts[0] if skill_texts else None
        # 运行记忆：每专项仅 1 份（最近一次），复用上次下钻选择 + 把踩过的坑注入改写提示
        memory = ks.read_skill_memory(skill)
        prev_drilldowns = [d for d in (memory.get("drilldowns") or []) if isinstance(d, str)]
        prev_problems = [p for p in (memory.get("problems") or []) if isinstance(p, str)]
        prev_structure = [s for s in (memory.get("report_structure") or []) if isinstance(s, str) and not _is_gap_section(s)]
        if req.full_report:
            prev_structure = []  # 用户要求完整重新生成：忽略上次报告结构记忆，走三模型完整流程
        problems = []  # 本次运行遇到的问题（写回记忆）
        # 改写依据：用户的有效问题；无问题时退化为「按专项方法补全维度/口径/时间」
        mod_prompt = question or (f"按专项「{skill}」的方法说明补全分析维度、口径与时间范围" if skill else "")
        if prev_problems:
            hint = "；注意：上次运行本专项遇到——" + "；".join(prev_problems[:3]) + "——请避免重复"
            mod_prompt = (mod_prompt + hint) if mod_prompt else ("按专项方法执行" + hint)
        steps = skill_agent.normalize_steps(meta)
        # 预测取数 SQL（历史群组 + 目标）只由 _run_forecast / _fetch_forecast_target 取数，
        # 不作为普通报告步骤执行、也不进报告图表
        # （其 {开始日期}/{结束日期} 占位符只在预测路径替换，普通步骤跑会取空）
        fc_sql_names = set(_forecast_fetch_sql_names(meta.get("forecast")))
        if fc_sql_names:
            steps = [s for s in steps if s["sql"] not in fc_sql_names]
        required_steps = [s for s in steps if s["required"]]
        optional_steps = [s for s in steps if not s["required"]]

        # 占位符模板（[group_value]/[where_value] 等）是可选的「额外方式」：仅当任一绑定 SQL 含
        # 方括号占位符时，才额外取表结构上下文并强制走模型改写以填充占位符；无占位符时
        # has_ph=False，行为与之前完全一致（零开销、零变化）。
        has_ph = any(detect_placeholders(_read_step_sql(skill, st["sql"])) for st in steps)
        schema_text = None
        if has_ph:
            try:
                schema_text, _, _ = schema_context.build_sql_context(engine, game["db"], game_key, question=question, user=user)
            except Exception:
                schema_text = None

        # 轻量层：从问题里确定性解析时间范围，能算清的范围不交给模型猜；
        # 写死 date 字面量的 SQL 暂不支持动态调整，先识别并提示（_check_hardcoded_dates）。
        parsed_start, parsed_end = parse_time_range(question)
        date_range = (parsed_start, parsed_end) if (parsed_start or parsed_end) else None
        if date_range:
            suffix = f"；已解析取数时间范围 {parsed_start or '?'} ～ {parsed_end or '?'}，SQL 日期窗口必须落在该区间内"
            mod_prompt = (mod_prompt + suffix) if mod_prompt else f"取数时间范围为 {parsed_start or '?'} ～ {parsed_end or '?'}"
        yield from _check_hardcoded_dates(required_steps, skill)

        # 固定步骤：改写 → 预检 → 执行
        # 提速：纯跑专项（无时间/维度/筛选意图）不改写绑定 SQL，直接跑原文，仍走 EXPLAIN 预检兜底。
        # 时间意图且能确定性解析出区间 → 走 apply_date_range 确定性注入（零模型）；
        # 仅维度/筛选/对比/排行/国家等才交给模型改写。
        do_rewrite = (_rewrite_intent(question, skill) == "model") or has_ph
        if do_rewrite:
            sql_to_run, originals = yield from _rewrite_step_sqls(model, required_steps, mod_prompt, skill_text, problems, date_range=date_range, skill=skill, schema_text=schema_text)
        elif date_range:
            # 仅有明确日期区间、无其它改写意图：确定性注入即可，不额外调用改写模型
            sql_to_run, originals = _load_bound_sqls(required_steps, date_range=date_range, skill=skill)
            yield _event("stage", stage="generate", message=f"已按指定日期范围 {parsed_start} ~ {parsed_end} 取数")
        else:
            sql_to_run, originals = _load_bound_sqls(required_steps, skill=skill)
        sql_to_run = yield from _precheck_steps(model, engine, game, game_key, sql_to_run, originals, problems, query_games=query_games)
        query_results, primary_df, run_sql, displayed = yield from _execute_steps(engine, game, query_games, sql_to_run, model=model, game_key=game_key)
        if query_results is None:
            return

        # 空表自纠错：单库下某步骤取到空表时，按「无数据」反馈让 AI 修正 SQL 重试一次（多地区空表多为地区差异，不改写）
        if len(query_games) == 1:
            repaired = yield from _repair_empty_steps(model, engine, game, game_key, sql_to_run, query_results, problems)
            if repaired:
                first_name = sql_to_run[0][0] if sql_to_run else None
                for name, ndf in repaired.items():
                    if name == first_name:
                        primary_df = ndf
                    for i, (dn, _df) in enumerate(displayed):
                        if dn == name:
                            displayed[i] = (name, ndf)
                            break

        # 可选下钻：裸跑且上次有下钻记录时直接复用（省一次规划调用）；否则 AI 依据中间结果规划
        triggered = []
        if optional_steps:
            summary = skill_agent.summarize_results(query_results)
            if prev_drilldowns and not do_rewrite:
                triggered = [s["name"] for s in optional_steps if s["name"] in prev_drilldowns]
                if triggered:
                    yield _event("stage", stage="analyze", message="🔍 复用上次下钻：" + "、".join(triggered))
            if not triggered:
                yield _event("stage", stage="analyze", message="AI 依据中间结果规划下钻维度…")
                try:
                    triggered = skill_agent.plan_drilldowns(model, skill_text, optional_steps, summary, user=user)
                except Exception as e:
                    triggered = []
                    yield _event("stage", stage="analyze", message=f"⚠️ 下钻规划失败（{e}），跳过下钻")
                yield _event("stage", stage="analyze", message=("🔍 触发下钻：" + "、".join(triggered)) if triggered else "无需下钻")
            if triggered:
                opt_steps = [s for s in optional_steps if s["name"] in triggered]
                if do_rewrite:
                    opt_to_run, opt_originals = yield from _rewrite_step_sqls(model, opt_steps, mod_prompt, skill_text, problems, date_range=date_range, skill=skill, schema_text=schema_text)
                else:
                    opt_to_run, opt_originals = _load_bound_sqls(opt_steps, date_range=date_range, skill=skill)
                opt_to_run = yield from _precheck_steps(model, engine, game, game_key, opt_to_run, opt_originals, problems, query_games=query_games)
                opt_results, _, _, opt_displayed = yield from _execute_steps(engine, game, query_games, opt_to_run, model=model, game_key=game_key)
                if opt_results is None:
                    return
                if len(query_games) == 1:
                    opt_repaired = yield from _repair_empty_steps(model, engine, game, game_key, opt_to_run, opt_results, problems)
                    for i, (dn, _df) in enumerate(opt_displayed):
                        if dn in opt_repaired:
                            opt_displayed[i] = (dn, opt_repaired[dn])
                query_results.update(opt_results)
                displayed.extend(opt_displayed)

        # 保存运行记忆（覆盖最近一次；只记固定步骤成功 + 下钻完成后的结果）
        # 注意：先读旧 memory 再 update，保留 gaps 登记册（白名单/已处理缺口），
        # 否则每次跑报告都会冲掉用户加过的白名单。
        try:
            mem = ks.read_skill_memory(skill)
            mem.update({
                "skill": skill,
                "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "drilldowns": triggered,
                "problems": problems,
            })
            ks.write_skill_memory(skill, mem)
        except Exception as e:
            yield _event("stage", stage="analyze", message=f"⚠️ 运行记忆保存失败（{e}）")

        # 流水预测：专项绑定了预测方法时执行（失败不阻断主报告，预测层由 LLM 标注数据不足）
        if meta.get("forecast"):
            fc_result = yield from _run_forecast(model, engine, game, game_key, meta["forecast"], skill=skill, note_games=query_games)
            if fc_result:
                for t in fc_result.get("tables", []):
                    name, tdf = t.get("name"), t.get("df")
                    if not name or tdf is None or tdf.empty:
                        continue
                    query_results[name] = tdf
                    if t.get("display") and name not in _FORECAST_HIDDEN_TABLES:
                        tdf.attrs["chart_hint"] = _forecast_chart_hint(name)  # 分日→折线图，其余→表格（前端默认折叠）
                        displayed.append((name, tdf))
                        yield _event("data", name=name, table=df_to_table(tdf))
                yield _event("stage", stage="forecast", message="✅ 流水预测完成，已纳入报告")
    else:
        # —— 只查SQL：先检索既有 SQL，命中则直接运行；未命中才 AI 现写（标记准确率无法保证）——
        # SQL 使用闸门：无 sql_use → 自由对话不能跑 SQL（含 AI 现写 / 就近改写）。
        from backend.ide_app.services.permissions import has_perm
        if not has_perm(user, "sql_use"):
            yield _event("error", message="你没有「SQL查询使用」权限，无法在此查询数据。")
            return
        sql_name = None
        if is_refine:
            yield _event("stage", stage="match", message="修正上一轮逻辑并重跑…")
        elif force_ai_fallback:
            if req.ai_report_confirm is None and req.rewrite_confirm is None:
                # 首次未命中：先就近改写提案（找到就近 SQL 时）→ 否则二次确认是否自动生成报告
                near = sql_match.nearest_sql(question, game_key)
                if near:
                    yield _event("meta", source="rewrite", skill=near, flagged=True)
                    yield _event("rewrite_confirm", sql_name=near, question=question, game=game_key)
                    yield _event("stage", stage="match", message=f"未精准命中，但找到就近 SQL「{near}」，待确认是否改写后执行…")
                    return
                yield _event("meta", source="ai", skill=None, flagged=True)
                yield _event("ai_report_confirm", question=question, game=game_key)
                yield _event("stage", stage="match", message="未命中既有工件，待确认是否由 AI 自动生成报告（结果不稳定、准确率无法保证）…")
                return
            yield _event("stage", stage="match", message=("AI 自动生成报告：现写 SQL…" if do_auto_report else "AI 现写 SQL…"))
        elif force_sql_name:
            sql_name = force_sql_name
        elif rewrite_sql_name:
            # 就近改写：落到下方 AI 生成路径（sql_name 保持 None），以就近 SQL 为底稿改写
            pass
        else:
            yield _event("stage", stage="match", message="检索既有 SQL…")
            try:
                sql_name = sql_match.match_sql(model_ver, question, game_key, user=user)
            except Exception as e:
                yield _event("stage", stage="match", message=f"SQL 检索失败（{e}），改为 AI 生成")
                sql_name = None
        sql_low_conf = False
        if sql_name:
            # 命中既有 SQL：先验机密档位（超出授权则拦截，不读取内容），再直接运行（仍走 EXPLAIN 预检兜底）
            from backend.ide_app.services.permissions import can_use_asset
            if not can_use_asset(user, "sql", sql_store.read_sql_meta(sql_name).get("confidentiality")):
                yield _event("error", message=f"SQL「{sql_name}」的机密等级超出你的授权，无法运行。")
                return
            yield _event("meta", source="sql", skill=sql_name, flagged=False)
            yield _event("stage", stage="match", message=f"命中既有 SQL「{sql_name}」，直接运行")
            sql_to_run = [(sql_name, sql_store.read_sql(sql_name))]
            sql_to_run = yield from _precheck_steps(model, engine, game, game_key, sql_to_run, query_games=query_games)
            _crop_fields = sql_match.declared_fields(sql_name)
            query_results, primary_df, run_sql, displayed = yield from _execute_steps(
                engine, game, query_games, sql_to_run,
                postprocess=(lambda df: sql_match.crop_columns(model, question, df, _crop_fields, user)),
                model=model, game_key=game_key,
            )
            if query_results is None:
                return
        else:
            # 未命中既有 SQL：AI 现写（优先扫知识库表结构/口径文档，缺失再扫真实表）
            if rewrite_sql_name:
                yield _event("meta", source="rewrite", skill=rewrite_sql_name, flagged=True)
            else:
                yield _event("meta", source="ai", skill=None, flagged=True)
            schema_text, ctx_docs, src = schema_context.build_sql_context(engine, game["db"], game_key, question=question, user=user)
            yield _event("stage", stage="schema", message=f"表结构上下文：{src}")
            # 专项说明 / 知识库文档 / 取数代码都作为业务口径参考
            ref_pairs = list(doc_texts) + ctx_docs
            for i, st in enumerate(skill_texts):
                ref_pairs.append((f"专项方法{i + 1}", st))
            # 提速：从既有 SQL 库选与问题最相关的实际 SQL 内容作 few-shot 示例（比只给名字更利于改出可用 SQL）
            similar = _similar_sql_examples(question, game_key, user=user)
            if similar:
                for name, content in similar:
                    ref_pairs.append((f"取数示例：{name}", content))
            else:
                sql_names = _visible_sql_names(user, game_key)
                if sql_names:
                    ref_pairs.append(("取数代码清单", "可用 SQL：" + ", ".join(sql_names)))
            # —— 自纠错循环：生成/修正 SQL → EXPLAIN 预检 → 试跑判定 → 报错/空结果则修正重试 ——
            final_sql = None
            query_results = None
            primary_df = None
            run_sql = None
            displayed = []
            sql_low_conf = False
            feedback = None
            for attempt in range(1, _SQL_MAX_ATTEMPTS + 1):
                if attempt == 1:
                    yield _event("stage", stage="generate", message=("就近改写 SQL…" if rewrite_sql_name else "AI 生成 SQL…"))
                    if not question and skill:
                        question = f"按专项「{skill}」的方法说明生成一条查询"
                    # 修正上一轮 / 就近改写：把底稿 SQL 作为 existing 传入，让 AI 在其基础上局部改，而非推倒重来
                    if rewrite_sql_name:
                        existing_sql = sql_store.read_sql(rewrite_sql_name)
                    else:
                        existing_sql = _recover_sql_from_history(req.history) if is_refine else None
                    # 审计 P2-15：SQL 生成短 TTL 缓存——重复提问（同 game、同表结构/口径上下文、无底稿 SQL）
                    # 直接复用上次生成结果，跳过 LLM 全量重生成。只缓存纯 AI 现写（existing 为空）：
                    # 就近改写/修正带底稿，每次语义不同，不缓存。模型、历史、参考口径全文进 extra 摘要，
                    # 上下文一变即自然换键；命中后 EXPLAIN 预检/只读闸门/自纠错循环照常执行，
                    # 缓存绝不短路执行链路（SQL/知识库资产写盘另有 invalidate(game_key) 兜底）。
                    cache_key = None
                    if existing_sql is None:
                        cache_key = sql_cache.make_key(
                            question, game_key, schema_text,
                            extra_context=sql_cache.context_digest(model, history_text, ref_pairs),
                        )
                        cached = sql_cache.get(cache_key)
                    else:
                        cached = None
                    if cached is not None:
                        sql, _cache_meta = cached
                        logger.info("「审计 P2-15」chat SQL 生成缓存命中：question=%r game=%s", question, game_key)
                        yield _event("stage", stage="generate", message="⚡ 命中 SQL 生成缓存，复用上次生成结果…")
                    else:
                        try:
                            sql, _ = sql_gen.generate_sql(model, schema_text, question, ref_pairs, history_text, existing=existing_sql)
                        except Exception as e:
                            yield _event("error", message=f"SQL 生成失败：{e}")
                            return
                        if cache_key is not None:
                            sql_cache.put(cache_key, (sql, {"source": "chat_generate"}), game_key=game_key)
                    for d in detect_hardcoded_dates(sql):
                        yield _event("stage", stage="verify", message=(
                            f"⚠️ AI 生成的 SQL 硬编码了日期 {d}：暂不支持动态调整时间范围"
                            f"（建议改用 current_date() 相对表达式）"
                        ))
                    # 验证模型复核：AI 自己检查现写 SQL 对不对，有问题则给出修正
                    verify_refs = [("表结构", schema_text)] + ref_pairs
                    yield _event("stage", stage="verify", message=f"验证模型复核 SQL（{model_ver}）")
                    try:
                        ok, final_sql, verdict = verify_sql(model_ver, sql, question, verify_refs)
                    except Exception as e:
                        ok, final_sql = False, sql
                        yield _event("stage", stage="verify", message=f"⚠️ 验证失败（{e}），按生成结果执行")
                    else:
                        yield _event("stage", stage="verify", message=("✅ 验证通过" if ok else f"✏️ 验证模型已修正：{verdict}"))
                else:
                    # 上一版报错/空结果 → 按反馈修正后重试（只改导致报错处，尽量保持原结构）
                    yield _event("stage", stage="generate", message=f"第 {attempt} 次尝试：{feedback}，AI 修正 SQL…")
                    try:
                        final_sql, _ = fix_sql(model, final_sql, feedback, schema_text)
                    except Exception as e:
                        yield _event("stage", stage="verify", message=f"⚠️ 修正失败（{e}），沿用上一版 SQL 重试")
                # EXPLAIN 预检（含一次自动修正）+ 真实执行
                sql_to_run = [("查询结果", final_sql)]
                sql_to_run = yield from _precheck_steps(model, engine, game, game_key, sql_to_run, query_games=query_games)
                final_sql = sql_to_run[0][1]
                # 就近改写：结果列按问题裁剪（复用底稿 SQL 的字段声明），避免多指标底稿带出无关指标（如流水达成里的目标/达成率）
                _crop_fields = sql_match.declared_fields(rewrite_sql_name) if rewrite_sql_name else None
                _post = (lambda df: sql_match.crop_columns(model, question, df, _crop_fields, user)) if rewrite_sql_name else None
                query_results, primary_df, run_sql, displayed = yield from _execute_steps(engine, game, query_games, sql_to_run, postprocess=_post, model=model, game_key=game_key)
                if query_results is None:
                    feedback = "SQL 执行报错，请检查表名/字段/语法/类型并修正"
                elif primary_df is None or primary_df.empty:
                    feedback = "SQL 执行成功但结果为空（无数据），请检查时间窗口/过滤条件/表名是否正确并修正"
                else:
                    break  # 拿到有效结果，结束自纠错
                if attempt >= _SQL_MAX_ATTEMPTS:
                    yield _event("stage", stage="verify", message=f"已尝试 {attempt} 次仍未得到有效结果，按最后一次结果解读（可能为空）…")
            if query_results is None:
                return

            # 指标联动：AI 新写 SQL（非就近改写）→ 后台检索已有指标，无高置信匹配则生成 draft 草稿
            # （后台线程，不阻断取数/解读主流程；失败静默）
            if final_sql and sql_name is None and rewrite_sql_name is None:
                _spawn_indicator_draft(uid, question, final_sql, game_key)

    # 2) AI 解读（附专项说明与知识库文档作参考）
    if req.context_report:
        # 后续追问：基于上一版官方报告自由发散（单一模型，附报告上下文）
        yield _event("stage", stage="analyze", message="基于上一版报告自由发散…")
        ref_docs = list(doc_texts) + [("上一版官方报告", req.context_report)]
        answer = analyze.analyze_combined(model, query_results, skill_texts, ref_docs, history_text, user=user)
        yield _event("answer", markdown=answer)
    elif skill:
        # 首轮选中/命中专项：有报告结构记忆时走两轮（生成→验证定稿，省汇总）；无记忆走三模型交叉验证
        if prev_structure:
            yield _event("stage", stage="analyze", message="专项分析：复用上次报告结构，生成 → 验证定稿（省汇总轮）")
        else:
            yield _event("stage", stage="analyze", message="专项分析：三模型交叉验证（生成 → 验证 → 汇总）")
        answer = yield from _emit_three_model(query_results, skill_texts, doc_texts, structure=prev_structure, user=user, deep_thinking=req.deep_thinking)
        if not answer:
            return
        yield _event("answer", markdown=answer)
        # 抽取本次最终报告的结构骨架，写回运行记忆（覆盖最近一次，只存结构不存数字）
        try:
            structure = _extract_report_structure(answer)
            if structure:
                mem = ks.read_skill_memory(skill)
                mem.update({
                    "skill": skill,
                    "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    "report_structure": structure,
                })
                ks.write_skill_memory(skill, mem)
        except Exception as e:
            yield _event("stage", stage="analyze", message=f"⚠️ 报告结构记忆保存失败（{e}）")
    elif do_auto_report:
        ref_docs = list(doc_texts)
        yield _event("stage", stage="analyze", message="AI 自动生成报告：三模型交叉验证（生成 → 验证 → 汇总）…")
        answer = yield from _emit_three_model(query_results, [], ref_docs, user=user, deep_thinking=req.deep_thinking)
        if not answer:
            return
        disclaimer = ("> ⚠️ 本报告由 AI 自动生成（未命中既有专项 / SQL / 模型 / 知识库，经三模型交叉验证），"
                      "结果不稳定、准确率无法保证，请人工复核后使用。\n\n")
        yield _event("answer", markdown=disclaimer + answer)
    else:
        # 命中既有 SQL / 修正 / 只查SQL：简短解读（不跑三模型报告）；命中既有 SQL 标注来源，否则标注 AI 生成·准确率无法保证
        yield _event("stage", stage="analyze", message="AI 结合知识库 / 专项口径 / 历史对话解读…")
        src_line = (f"> 📄 数据来源：既有 SQL《{sql_name}》" if sql_name
                    else (f"> 🔧 数据来源：就近 SQL《{rewrite_sql_name}》改写，准确率无法保证" if rewrite_sql_name
                          else "> ⚠️ 未命中既有 SQL，本查询由 AI 自动生成，准确率无法保证"))
        answer = analyze.analyze_brief(model_ver, query_results, source_line=src_line,
                                       skill_texts=skill_texts, doc_texts=doc_texts,
                                       history=history_text, user=user)
        yield _event("answer", markdown=answer)

    # 3) KPI 卡片 + 图表建议（每张表格各配一张可切换图，不再只有主视图一张图）
    if primary_df is not None and not primary_df.empty:
        kpis = chart.build_kpis(primary_df)
        if kpis:
            yield _event("kpi", kpis=kpis)
    charts = []
    for name, df in displayed:
        hint = getattr(df, "attrs", {}).get("chart_hint") or {}
        spec = chart.build_chart_spec(df, req.chart_type, hint)
        spec["name"] = name
        charts.append(spec)
    yield _event("charts", charts=charts)

    # 4) 提炼建议改为手动触发：前端收到 done 后展示「💡 提炼建议」按钮，点击才调 POST /chat/suggest
    #    （生成 SQL/知识库/专项草稿需多次 LLM 调用、较耗时，不阻塞本轮结果展示）。



async def _usage_scope() -> None:
    """审计 P2-7：在路由任务上下文里为本请求开独立 token 用量桶。

    chat 是同步端点、SSE 生成器的每个步都跑在线程池，且每个步的 contextvars 都从路由
    任务上下文复制（anyio run_sync 每步 copy_context），步内 start() 只对当步生效。这里
    以 async 依赖在路由任务上下文建桶，后续所有生成器步、并行 worker 线程（submission
    处 clone_context(ctx).run 传播，见 services/retrieval.py、skill_bundle.py）都写回同一个桶，
    多用户并发互不串桶。
    """
    usage_tracker.start()


@router.post("/chat")
def chat(req: ChatRequest, request: Request, user=Depends(get_current_user), game=Depends(get_game), _usage=Depends(_usage_scope)):
    # 审计 P1-21（按用户每分钟限流）+ P1-20（按用户并发闸）：同步端点跑在线程池，
    # 无限并发会把线程池拖垮；超限直接 429，不排队。
    rate_limit.check_rate(user, request, rate_limit.CHAT_LIMIT_PER_MINUTE)
    slot_key = rate_limit.acquire_slot(user, request, rate_limit.CHAT_MAX_CONCURRENT)

    def stream():
        start = time.monotonic()
        # 深度思考（开推理）整轮放宽到 CHAT_DEEP_TOTAL_TIMEOUT_S（默认 1800s），普通档维持 900s
        _timeout_attr = "CHAT_DEEP_TOTAL_TIMEOUT_S" if req.deep_thinking else "CHAT_TOTAL_TIMEOUT_S"
        total_timeout = int(getattr(config, _timeout_attr, 1800 if req.deep_thinking else 900) or (1800 if req.deep_thinking else 900))
        deadline = start + total_timeout
        gen = inject_temperature(_handle(req, game, user), "chat")
        timeout_msg = f"运行超过总时长上限（{total_timeout}s），已自动停止，请缩小范围或稍后重试"
        try:
            # 每步线程上下文隔离：注入的温度只在当步生效（见 _usage_scope），包装后步内 LLM 调用都能读到
            for chunk in gen:
                yield chunk
                if time.monotonic() <= deadline:
                    continue
                # 审计·聊天优化块 C：整轮看门狗——此前无整轮上限，网关挂起重试会把单轮拖到 1000+ 秒。
                # 对抗审查修复：到点先探测下一帧——生成器已自然结束（最后一帧即完整报告已交付）
                # 就不再补 error：error 会让前端把已交付的报告标成出错、丢出历史，「已自动停止」
                # 提示也失实。仍有帧待发（真截断）则交付已就绪的这帧后补 error 停发。
                # 对抗审查修复（round-2）：探测的 next(gen) 会真执行下一步代码（生成器无缓冲、
                # 无法 peek），下一步若是完整 LLM 轮会静默阻塞 2-4 分钟。探测期间注入外部整轮
                # 预算——ai_client 每次 LLM HTTP 尝试前检查、到点立即抛错，误差从「一个 LLM 轮」
                # 缩到「一次数据库读（≤300s read_timeout）」。
                ext_token = set_external_deadline(deadline)
                try:
                    pending = next(gen)
                except StopIteration:
                    break
                except Exception as exc:
                    # 探测期间 LLM 预算异常（或生成器内部异常）→ 统一按超时文案收口
                    if "总时长预算" not in str(exc):
                        yield _event("error", message=f"{str(exc)}（且运行超过总时长上限，已自动停止）")
                    else:
                        yield _event("error", message=timeout_msg)
                    break
                finally:
                    reset_external_deadline(ext_token)
                yield pending
                yield _event("error", message=timeout_msg)
                break
        except Exception as exc:  # 统一把异常作为 error 事件推给前端
            yield _event("error", message=str(exc))
        finally:
            rate_limit.release_slot(slot_key)
            res = usage_tracker.finish()
            if res.get("calls"):
                yield _sse(usage.build_usage_event(res))
            elapsed = round(time.monotonic() - start, 2)
            yield _event("done", elapsed=elapsed)

    return StreamingResponse(stream(), media_type="text/event-stream")


@router.post("/chat/suggest")
def chat_suggest(body: SuggestReq, user=Depends(get_current_user), game=Depends(get_game)):
    """手动触发「提炼建议」：把一轮数据对话生成 SQL / 知识库 / 专项 草稿（前端点按钮才调用）。"""
    try:
        # P1-4：与其它生成入口同口径，经任务→模型/温度单一入口（chat=对话生成类，显式下拉模型优先）
        model = resolve_model_for_task("chat", user, body.model)
        # 哨兵「不选游戏」模式（game=None）：按前端回传会话游戏/专项绑定游戏恢复 game_key
        # （评审 H2：全失败 → 400，不再用 None-safe 的全量资产列表兜底——那会跨游戏泄漏）
        if game is not None:
            game_key = game["key"]
        else:
            game_key, _db = _recover_sentinel_game(user, body.games, skill=body.skill)
        return refine.build_suggestion(
            model, skill=body.skill, question=body.question,
            sql=body.sql, answer=body.answer, game_key=game_key,
            kinds=body.kinds,
        )
    except LLMNotConfigured:
        raise
    except HTTPException:
        raise  # 哨兵模式缺游戏等业务 4xx 原样透传，不被兜底 502 吞掉
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"提炼建议生成失败：{exc}")


@router.post("/chat/suggest-merge")
def suggest_merge(body: SuggestMergeReq, user=Depends(get_current_user), game=Depends(get_game)):
    """把一轮对话合并进某个既有专项/知识库/SQL，返回合并草稿（前端展示后再写回 target）。"""
    if body.kind not in ("sql", "docs", "skills", "models"):
        raise HTTPException(status_code=400, detail="kind 只能是 sql / docs / skills / models")
    if not body.target:
        raise HTTPException(status_code=400, detail="缺少合并目标 target")
    try:
        # P1-4：同 /chat/suggest，经任务→模型/温度单一入口（chat=对话生成类）
        model = resolve_model_for_task("chat", user, body.model)
        # 哨兵「不选游戏」模式（game=None）：按前端回传会话游戏 → 目标资产所属游戏（在允许集内
        # 搜索）→ models 回落允许集首款恢复（评审 H2）；无法恢复 → 400
        if game is not None:
            game_key, db = game["key"], game["db"]
        else:
            game_key, db = _recover_sentinel_game(user, body.games, kind=body.kind, target=body.target)
        # 评审 A3：target 必须在该游戏范围内可见（防跨游戏/他人资产合并；read_sql/read_doc/
        # read_skill 均按名读取、不做范围校验）
        if body.kind == "sql" and body.target not in sql_store.list_sql_files(game_key):
            raise HTTPException(status_code=400, detail="目标 SQL 不存在或无权访问")
        if body.kind == "docs" and body.target not in ks.list_docs(game_key):
            raise HTTPException(status_code=400, detail="目标知识库文档不存在或无权访问")
        if body.kind == "skills" and body.target not in ks.list_online_skills(game_key):
            raise HTTPException(status_code=400, detail="目标专项不存在或无权访问")
        return refine.build_merge(
            model, kind=body.kind, target=body.target,
            question=body.question, sql=body.sql, answer=body.answer,
            game_key=game_key, db=db, engine=get_engine(),
        )
    except LLMNotConfigured:
        raise
    except HTTPException:
        raise  # 哨兵模式缺游戏等业务 4xx 原样透传，不被兜底 502 吞掉
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"合并生成失败：{exc}")


@router.post("/chat/gaps")
def chat_gaps(body: ChatGapReq, user=Depends(get_current_user), game=Depends(get_game)):
    """手动触发「查看报告缺口与补数建议」：对一份已生成的报告正文识别缺口并给补救建议（只读、不落盘）。

    这里补上本轮专项的元信息（关联专项、取数 SQL、知识库文档），让缺口建议更贴合该专项口径。
    （订阅报告页的 /reports/{id}/gaps 已随 2026-10-26 缺口建议整体 to-B 化摘除。）
    """
    if not body.report_md.strip():
        raise HTTPException(status_code=400, detail="缺少报告正文 report_md")
    model = resolve_model_for_task("gap", user, body.model)
    meta = {}
    if body.skill:
        # 对抗审查三轮 F3：家族上下文改用专项自身绑定游戏（game_key=None → ctx=meta.game），
        # 而非当前选中游戏——用户生成报告后切换游戏回看缺口时不再被误 403。
        _require_skill_visible(user, body.skill, None, "分析缺口")
        smeta = ks.read_skill_meta(body.skill)
        meta["skill"] = body.skill
        meta["selected_sql"] = smeta.get("sqls") or []
        meta["selected_docs"] = smeta.get("docs") or []
    try:
        result = gap_analysis.analyze_gaps(model, body.report_md, meta)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"缺口分析失败：{exc}")
    gaps = gap_fix.annotate_gaps(body.skill, result["gaps"])
    return {"skill": body.skill, "gaps": gaps, "whitelist": gap_fix.list_whitelist(body.skill)}


@router.post("/chat/gap-whitelist")
def chat_gap_whitelist(body: ChatGapWhitelistReq, user=Depends(get_current_user)):
    """把一条缺口加入白名单（不需处理）：后续运行该缺口不再出现。"""
    if body.skill:
        _require_skill_visible(user, body.skill, None, "维护白名单")
    return gap_fix.whitelist_gap(body.skill, body.gap or {})


@router.get("/chat/gap-whitelist")
def chat_gap_whitelist_list(skill: str | None = None, user=Depends(get_current_user)):
    """列出某专项的白名单条目。"""
    if skill:
        _require_skill_visible(user, skill, None, "查看白名单")
    return {"skill": skill, "whitelist": gap_fix.list_whitelist(skill)}


@router.delete("/chat/gap-whitelist/{sig}")
def chat_gap_whitelist_delete(sig: str, skill: str | None = None, user=Depends(get_current_user)):
    """从白名单移除一条：下次运行该缺口可能再次出现。"""
    if skill:
        _require_skill_visible(user, skill, None, "维护白名单")
    return gap_fix.remove_whitelist(skill, sig)


def _recover_sentinel_game(user: dict, games_req: list[str] | None, kind: str | None = None,
                           target: str | None = None, skill: str | None = None) -> tuple[str, str]:
    """哨兵「不选游戏」模式（game=None）的游戏恢复链（评审 H2/A3）：
    1) 回传游戏内的目标资产定位（kind+target 齐备时，即合并草稿）：目标在对话锚定的回传
       游戏内 → 用该游戏（对抗审查二轮：此前先全允许集搜目标、完全忽略 games_req，多游戏
       会话会把 allowed[0] 误当目标归属，合并草稿按错误库的表结构生成）；
    2) 目标资产所属（全允许集，仅 kind+target 齐备时）：按 kind 搜索 target
       （sql/docs/skills）——目标唯一锚定其归属游戏；所有候选都先过已知+鉴权
       （games.resolve 对未知 key 静默回落默认游戏，直接 resolve 会越权）；
    3) 前端回传 games：key 必须已知 + 有权限（防伪造 key）；
    4) 专项绑定游戏：允许集内才用；
    5) kind=models：允许集首款（算法不分层、全通用）；
    6) 恰 1 款有权限游戏：自动绑定（与 _sentinel_bind 第 5 步 / sentinel_bind_games 第 3 步
       对齐——单游戏权限用户聊天/深度能自动绑，提炼/合并也应当，否则功能不对称）。
    全失败 → 400（list 函数传 None 会返回全量资产，不能作为恢复依据）。
    """
    from backend.ide_app.services.permissions import is_game_allowed

    engine = get_engine()
    known = {g["key"]: g for g in games.get_games(engine)}
    allowed = [g for g in known.values() if is_game_allowed(user, g["key"])]
    req_games = [known[k] for k in (games_req or []) if k in known and is_game_allowed(user, k)]

    def _in_scope(g, kind, target):
        if kind == "sql":
            return target in sql_store.list_sql_files(g["key"])
        if kind == "docs":
            return target in ks.list_docs(g["key"])
        if kind == "skills":
            return target in ks.list_online_skills(g["key"])
        return False

    if kind and target:
        # 1) 回传游戏（对话锚定）内的目标资产优先
        for g in req_games:
            if _in_scope(g, kind, target):
                return g["key"], g["db"]
        # 2) 全允许集搜索（回传游戏内没命中，或前端未回传——目标可能属于会话外的有权游戏）
        for g in allowed:
            if _in_scope(g, kind, target):
                return g["key"], g["db"]
    # 3) 前端回传会话游戏
    if req_games:
        return req_games[0]["key"], req_games[0]["db"]
    # 4) 专项绑定游戏
    if skill:
        try:
            bound = ks.read_skill_meta(skill).get("game")
        except Exception:  # noqa: BLE001
            bound = None
        if bound and bound in known and is_game_allowed(user, bound):
            return known[bound]["key"], known[bound]["db"]
    # 5) models：算法不分层，回落允许集首款
    if kind == "models" and allowed:
        return allowed[0]["key"], allowed[0]["db"]
    # 6) 恰 1 款有权限游戏 → 自动绑定
    if len(allowed) == 1:
        return allowed[0]["key"], allowed[0]["db"]
    raise HTTPException(status_code=400,
                        detail="未指定游戏，无法生成建议/合并草稿（请先选择游戏，或为该专项绑定游戏）")


def _require_skill_visible(user: dict, skill: str | None, game_key: str | None, action: str = "访问"):
    """缺口接口族（gap-*）的技能可见性闸门（对抗审查二轮）：镜像 skills.py _require_visible 的
    visible_to 规则——通用级全局可见、项目级同族（family_key 匹配）可见、个人级仅归属用户；
    跨游戏/跨人 403（此前 gap-fix/apply/answer/whitelist 等按专项名直接读写专项内容，
    仅要求攻击者持任一游戏权限即可读写他人个人级专项）。

    家族上下文：调用方有选中游戏（非哨兵）时用选中游戏；哨兵模式（game=None）时用专项
    绑定游戏作家族上下文。另叠加绑定游戏权限闸门（is_game_allowed 为精确 key 匹配，
    kof_sea 用户对 kof 家族专项按「家族成员有权限」放行——与 visible_to 同族语义一致）。
    """
    from backend.ide_app.services.permissions import is_game_allowed

    if not skill:
        raise HTTPException(status_code=403, detail="未关联专项，无权执行缺口操作")
    # 先验存在性：不存在的专项名此前会当作「通用级空元数据」放行，随后 gap_fix 按名写入
    # run.json 注册文件（versioning 留痕）→ 垃圾落盘；非法名称在 _validate_name 处抛 ValueError
    # → 未捕获 500。统一转 404（对抗审查二轮补强）。
    try:
        exists = ks.skill_exists(skill)
        meta = ks.read_skill_meta(skill) or {}
    except ValueError:
        raise HTTPException(status_code=404, detail=f"专项「{skill}」不存在")
    if not exists:
        raise HTTPException(status_code=404, detail=f"专项「{skill}」不存在，无法{action}")
    if not meta.get("level"):
        # 存在但元数据缺失/损坏：可见性不可判定 → 一律拒绝（fail closed）。此前空元数据被
        # visible_to 当「通用」放行，任意用户可写此类专项（覆盖 run.json 登记册/写笔记/建绑定）。
        raise HTTPException(status_code=403,
                            detail=f"专项「{skill}」缺少层级元数据（level/game/owner），"
                                   f"请先在「专项管理」保存一次，无法{action}")
    owner = owner_key(user)  # 与 current_owner_key 同口径（user 直给，不依赖 ContextVar）
    ctx_key = game_key or meta.get("game")
    if not visible_to(meta.get("level"), meta.get("game"), ctx_key, meta.get("owner"), owner):
        raise HTTPException(status_code=403, detail=f"专项「{skill}」属于其他游戏或用户，无权{action}")
    bound = meta.get("game")
    if bound:
        if is_game_allowed(user, bound):
            return
        fam = [m["key"] for m in games.family_members({"key": bound}, get_engine())]
        if not any(is_game_allowed(user, k) for k in fam):
            raise HTTPException(status_code=403, detail=f"专项「{skill}」绑定的游戏暂无权限，无权{action}")


def _gap_game(skill: str | None, game: dict, user: dict) -> tuple[str, str]:
    """缺口修复端点的游戏恢复链：正常模式直接用选中游戏；哨兵「不选游戏」模式（game=None）
    按专项绑定游戏恢复 key/db（key 先校验、再鉴权——games.resolve 对未知 key 静默回落默认游戏，
    直接 resolve 会越权）。无法恢复 → 400。
    """
    if game is not None:
        return game["key"], game["db"]
    bound = None
    if skill:
        try:
            bound = ks.read_skill_meta(skill).get("game")
        except Exception:  # noqa: BLE001
            bound = None
    if bound:
        from backend.ide_app.services.permissions import is_game_allowed
        known = {g["key"]: g for g in games.get_games(get_engine())}
        g = known.get(bound)
        if g is not None:
            # 家族放行（对抗审查三轮 F2）：与 _require_skill_visible 的绑定游戏闸门同口径——
            # 成员服用户可操作绑定家族主键的专项（此前精确 key 匹配把家族成员在哨兵模式拦成 400）。
            if is_game_allowed(user, bound) or any(
                    is_game_allowed(user, m["key"])
                    for m in games.family_members(g, get_engine())):
                return g["key"], g["db"]
    raise HTTPException(status_code=400,
                        detail="未指定游戏，无法执行缺口修复（请先选择游戏，或为该专项绑定游戏）")


@router.post("/chat/gap-fix")
def chat_gap_fix(body: ChatGapFixReq, user=Depends(get_current_user), game=Depends(get_game)):
    """对单条缺口执行「AI 自动修复」：按类型分派（换日期自动修 / 生成 SQL 草稿 / 扫库绑定）。

    返回 action ∈ applied（已自动落盘）/ draft（草稿待人审保存）/ prompt（仅提示手动处理）。
    """
    gap = body.gap or {}
    if not gap.get("issue") and not gap.get("remedy_type"):
        raise HTTPException(status_code=400, detail="缺少缺口信息 gap")
    model = resolve_model_for_task("gap", user, body.model)
    # 先鉴权后恢复游戏（对抗审查三轮 F2）：哨兵模式下 _gap_game 先撞 400（精确 key 鉴权、
    # 无家族放行），可见性闸门的家族语义永远够不到；不存在/无元数据专项也应先 404/403。
    if body.skill:
        _require_skill_visible(user, body.skill, game["key"] if game else None, "修复缺口")
    game_key, db = _gap_game(body.skill, game, user)
    try:
        result = gap_fix.resolve_gap(model, body.skill, gap, game_key, db, get_engine())
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"缺口修复失败：{exc}")
    result["gap_sig"] = gap_fix.gap_signature(gap)
    return result


@router.post("/chat/gap-fix/apply")
def chat_gap_fix_apply(body: ChatGapFixApplyReq, user=Depends(get_current_user), game=Depends(get_game)):
    """保存缺口修复草稿（人审通过后）：写全局 SQL + 绑专项 + 写快照 + 记父链接。"""
    draft = body.draft or {}
    if not draft.get("kind"):
        raise HTTPException(status_code=400, detail="缺少草稿 draft")
    model = resolve_model_for_task("gap", user, body.model)
    if body.skill:
        _require_skill_visible(user, body.skill, game["key"] if game else None, "保存修复草稿")
    game_key, db = _gap_game(body.skill, game, user)
    try:
        result = gap_fix.apply_gap_draft(body.skill, draft, model, game_key, db, get_engine())
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"保存草稿失败：{exc}")
    return result


@router.post("/chat/gap-answer")
def chat_gap_answer(body: ChatGapAnswerReq, user=Depends(get_current_user), game=Depends(get_game)):
    """用户用文字说明缺口怎么补 / 为什么这么改，AI 按说明产出调整草稿（仅草稿，不落盘）。"""
    gap = body.gap or {}
    if not gap.get("remedy_type"):
        raise HTTPException(status_code=400, detail="缺少缺口信息 gap")
    if not (body.answer or "").strip():
        raise HTTPException(status_code=400, detail="缺少调整说明 answer")
    model = resolve_model_for_task("gap", user, body.model)
    if body.skill:
        _require_skill_visible(user, body.skill, game["key"] if game else None, "调整缺口")
    game_key, db = _gap_game(body.skill, game, user)
    try:
        result = gap_fix.resolve_gap_answer(model, game_key, db, get_engine(), gap, body.answer, body.skill)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"文本调整失败：{exc}")
    result["gap_sig"] = gap_fix.gap_signature(gap)
    return result


@router.post("/chat/gap-answer/apply")
def chat_gap_answer_apply(body: ChatGapAnswerApplyReq, user=Depends(get_current_user), game=Depends(get_game)):
    """保存文本调整草稿（人审通过后落盘，走版本化 writer 留痕）。"""
    draft = body.draft or {}
    if not draft.get("kind"):
        raise HTTPException(status_code=400, detail="缺少草稿 draft")
    model = resolve_model_for_task("gap", user, body.model)
    if body.skill:
        _require_skill_visible(user, body.skill, game["key"] if game else None, "保存调整草稿")
    game_key, db = _gap_game(body.skill, game, user)
    try:
        result = gap_fix.apply_gap_answer_draft(body.skill, draft, body.gap or {}, model, game_key, db, get_engine())
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"保存草稿失败：{exc}")
    return result


class ExportCsvReq(BaseModel):
    sql: str = ""
    name: str = "export"
    db: str | None = None  # 单库导出显式指定库（哨兵「不选游戏」模式无选中游戏时前端回传）
    sqls: list[dict] | None = None  # 多游戏导出：[{sql, db, label}]，逐库执行后拼「地区」列导出


# 导出 CSV 的行数上限：前端传回的是「最终 SQL」，这里再兜底一次硬上限，防失控 SELECT 把后端内存打爆。
_EXPORT_MAX_ROWS = 200000
# 多库导出条目上限（对抗审查三轮）：sqls 条目数客户端可控且无界 → 1000 条重查询 + 无界 concat
# 可打爆共享 MySQL 与后端内存。合法前端使用 ≤ 允许游戏数（当前家族最多 7 款），20 足够且封顶。
_EXPORT_MAX_SQLS = 20


def _csv_safe_cell(value: str) -> str:
    """CSV 注入防护（对抗审查三轮）：以 = + - @ 开头的单元格会被 Excel 当公式执行，
    前缀 ' 转义为文本。"""
    text = str(value)
    return "'" + text if text[:1] in ("=", "+", "-", "@") else text


@router.post("/chat/export-csv")
def export_csv(req: ExportCsvReq, user=Depends(get_current_user), game=Depends(get_game)):
    """把某次查询的 SQL 重跑一遍并导出 CSV（供聊天表格/图导出全量数据）。

    前端传入的是已 apply_db + 夹过日期窗口的最终 SQL；这里做只读护栏 + 游戏库作用域 + 行数上限三重兜底
    （apply_sql 幂等：已 apply 过的 SQL 重复替换库名无变化，且会补上漏写的 active 视图 tz 过滤），
    返回 utf-8-sig 编码的 CSV（带 BOM，Excel 打开中文不乱码）。

    哨兵「不选游戏」模式：前端回传 sqls=[{sql, db, label}]（多游戏逐库执行拼「地区」列）
    或单条 sql+db。db 字段客户端可控 → 每个 db 必须反查到游戏且用户有权，否则 403（防跨游戏外泄）。
    """
    from backend.ide_app.services.permissions import is_game_allowed

    engine = get_engine()
    all_games = games.get_games(engine)

    def _db_game(db: str) -> dict:
        for g in all_games:
            if g["db"] == db:
                if not is_game_allowed(user, g["key"]):
                    raise HTTPException(status_code=403, detail="无此游戏权限")
                return g
        raise HTTPException(status_code=403, detail="无此游戏权限")

    def _fetch(sql: str, db: str) -> pd.DataFrame:
        try:
            final = validate_sql(sql)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        _db_game(db)  # 权限闸门：非法/越权库一律 403
        try:
            return run_raw_sql(engine, games.apply_sql(final, db), max_rows=_EXPORT_MAX_ROWS, project_key=_db_game(db)["key"])
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except Exception as exc:  # noqa: BLE001 —— 执行失败返回可读错误，不泄漏堆栈
            raise HTTPException(status_code=400, detail=f"导出执行失败：{exc}")

    if req.sqls:
        valid_sqls = [it for it in req.sqls if isinstance(it, dict)
                      and isinstance(it.get("sql"), str) and isinstance(it.get("db"), str)
                      and (it.get("sql") or "").strip() and (it.get("db") or "").strip()]
        if len(valid_sqls) > _EXPORT_MAX_SQLS:
            raise HTTPException(status_code=400, detail=f"导出条目过多（>{_EXPORT_MAX_SQLS}），请分批导出")
        parts = []
        for item in valid_sqls:
            sql, db = item["sql"].strip(), item["db"].strip()
            df = _fetch(sql, db)
            view = df.copy()
            if "地区" in view.columns:
                view = view.rename(columns={"地区": "地区(原)"})
            view.insert(0, "地区", _csv_safe_cell(item.get("label") or db))
            parts.append(view)
        if not parts:
            raise HTTPException(status_code=400, detail="缺少可导出的 SQL")
        df = pd.concat(parts, ignore_index=True)
    else:
        db = req.db or (game or {}).get("db")
        if not db:
            raise HTTPException(status_code=400, detail="未指定游戏库，无法导出（请先选择游戏）")
        df = _fetch(req.sql, db)
    name = re.sub(r'[\\/:*?"<>|]', "_", (req.name or "").strip())[:80] or "export"
    csv_bytes = df.to_csv(index=False).encode("utf-8-sig")
    return Response(
        content=csv_bytes,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{name}.csv"'},
    )
