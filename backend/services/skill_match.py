"""聊天自由提问的专项检索：AI 判断用户问题最匹配哪个专项（分析方法）。

专项数量少，用单次 AI 判定成本低、实现简单；专项变多后可换向量检索。
"""
import json
import re

from analysis import knowledge_store as ks
from .llm import complete_with_fallback

from . import sql_match

_SYSTEM = (
    "你是一名数据分析助手。给定用户问题与一份「专项（分析方法）」清单，"
    "判断用户问题命中哪个专项、或与哪个专项最相关。"
    "只输出一个 JSON 对象：{\"skill\": \"专项名\"} 或 {\"skill\": null}。"
    "判定规则（务必同时满足才返回专项名，否则返回 null 让系统按只查SQL/现写处理）：\n"
    "1. 时间范围对齐：用户说「过去/最近N天」是滚动相对窗口，专项若固定分析「上一自然周/本月/上月」等算不匹配；\n"
    "2. 指标范围对齐：用户只问「流水/收入」本身，专项若还产出「目标/达成率/DAU/ARPU」等额外指标算不匹配；\n"
    "3. 专项名必须与清单里完全一致。\n"
    "不要输出 JSON 以外的任何内容。"
)


def _summarize(text: str, limit: int = 240) -> str:
    text = (text or "").strip()
    if not text:
        return "（无说明）"
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    s = " ".join(lines)
    return s[:limit] + ("…" if len(s) > limit else "")


_MD_NOISE_RE = re.compile(
    r"```[\s\S]*?```"      # 围栏代码块（含内容）
    r"|`[^`\n]*`"          # 行内代码
    r"|#{1,6}\s*"          # 标题 # 号
    r"|\*\*|__"            # 加粗
    r"|\|"                 # 表格竖线
    r"|^\s*>\s?"           # 引用
    r"|^\s*[-*+]\s+"       # 无序列表符号
    r"|^\s*\d+[.)]\s+"     # 有序列表符号
    , re.MULTILINE,
)


def _short_summary(text: str, limit: int = 60) -> str:
    """把方法说明压成一句话短摘要：去 markdown 语法噪音 + 截断（供二次确认卡展示）。"""
    t = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text or "")
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)
    t = _MD_NOISE_RE.sub(" ", t)
    t = re.sub(r"\s+", " ", t).strip()
    if not t:
        return "（无说明）"
    return t[:limit] + ("…" if len(t) > limit else "")


def summarize_skill_text(skill: str) -> str:
    """返回某专项的一句话说明（供二次确认卡展示命中原因）。

    优先取专项 meta.json 里手工维护的 summary；缺失时回退为方法说明的短摘录。
    """
    summary = (ks.read_skill_meta(skill).get("summary") or "").strip()
    if summary:
        return summary
    return _short_summary(ks.read_skill(skill))


def _parse(raw: str) -> dict:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    # 兜底：从原始输出里抓 "skill"
    m = re.search(r'"skill"\s*:\s*"([^"]*)"', raw)
    if m:
        return {"skill": m.group(1)}
    if re.search(r'"skill"\s*:\s*null', raw):
        return {"skill": None}
    return {}


def _skill_time_conflicts(question: str, skill: str) -> bool:
    """问题要滚动「过去/最近N天」，而专项绑定的 SQL 固定取自然周/月/固定日期 → 冲突。

    复用 sql_match 的时间语义识别：命中但时间窗口冲突时放弃复用该专项（宁可只查SQL/现写，
    也不套用错误时间窗口）。
    """
    if not sql_match._ROLLING_ASK.search(question or ""):
        return False
    meta = ks.read_skill_meta(skill)
    for sql_name in (meta.get("sqls") or []):
        text = ks.read_skill_sql(skill, sql_name)
        if sql_match._time_conflicts(question, text):
            return True
    return False


def match_skill(model: str, question: str, game: str | None = None, user: dict | None = None) -> str | None:
    """返回最匹配的专项名；无匹配或 AI 判定 null 时返回 None。"""
    skills = ks.list_online_skills(game)
    if not skills:
        return None
    # 确定性兜底：问题里精确点名了某个专项名 → 直接命中，不再过时间/指标对齐守卫
    # （点名即权威，对齐守卫只用于「隐式匹配」防误判）。
    q = (question or "").strip()
    if q:
        exact = [s for s in skills if s and s in q]
        if exact:
            return max(exact, key=len)
    listing = "\n".join(
        f"- {name}: {_summarize(ks.read_skill(name))}" for name in skills
    )
    user_prompt = (
        "# 专项清单\n\n"
        f"{listing}\n\n"
        "# 用户问题\n\n"
        f"{question.strip()}\n\n"
        "请判断命中哪个专项。"
    )
    raw = complete_with_fallback(
        model=model,
        messages=[
            {"role": "system", "content": _SYSTEM},
            {"role": "user", "content": user_prompt},
        ],
        user=user,
    )[0]
    name = (_parse(raw).get("skill") or "").strip()
    if name in skills:
        if _skill_time_conflicts(question, name):
            return None  # 命中但时间窗口冲突：放弃复用，交给只查SQL/现写
        return name
    return None
