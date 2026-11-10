"""自然语言问题 → 既有 SQL 语义匹配（只查SQL 通道的取数来源检索）。

专项数量少、SQL 库也不大，用单次 flash 判定成本低、实现简单；模型不可用时
降级为文件名关键词（2-gram）本地匹配，保证链路不崩。
"""
import json
import re

import pandas as pd

from analysis import sql_store
from .llm import complete_with_fallback

_SYSTEM = (
    "你是一名数据分析助手。给定用户问题与一份「既有 SQL」清单（每条含文件名、时间范围、输出列/指标名、内容摘要），"
    "判断用户问题与哪条 SQL 最相关、可直接用它取数。"
    "只输出一个 JSON 对象：{\"sql\": \"文件名\"} 或 {\"sql\": null}。"
    "判定规则（务必同时满足才返回文件名，否则返回 null 让系统现写）：\n"
    "1. 时间范围对齐：用户说「过去/最近N天」是滚动相对窗口，SQL 若固定取「上一自然周 / 本月 / 上月 / 固定日期」等算不匹配；\n"
    "2. 指标覆盖：以每条 SQL 的【输出列】里的指标名为准，SQL 必须能产出用户问的核心指标（不能缺指标，如用户问「流水」但 SQL 没有流水列就算不匹配）；SQL 额外多产出的其它指标不算不匹配（系统只展示相关列）；\n"
    "3. 文件名必须与清单里完全一致。\n"
    "不要输出 JSON 以外的任何内容。"
)

_WEEK_TRUNC = re.compile(r"date_trunc\s*\(\s*'week'\s*,")
_MONTH_TRUNC = re.compile(r"date_trunc\s*\(\s*'month'\s*,")
_ROLLING = re.compile(r"date_sub\s*\(\s*current_date\s*\(\s*\)\s*,\s*interval\s+(\d+)\s+day")
_HARDCODED = re.compile(r"date\s*(>=|<=|>|<|=)\s*'\d{4}-\d{2}-\d{2}'")


def _time_hint(text: str) -> str:
    """确定性识别 SQL 的时间窗口语义，辅助匹配判定（避免「上一周」被当成「过去7天」）。"""
    t = text or ""
    if _WEEK_TRUNC.search(t):
        return "上一自然周"
    if _MONTH_TRUNC.search(t):
        return "本月/上月（自然月）"
    m = _ROLLING.search(t)
    if m:
        return f"滚动最近{m.group(1)}天"
    if _HARDCODED.search(t):
        return "固定日期范围"
    return "时间未定"


def _summarize(text: str, limit: int = 240) -> str:
    text = (text or "").strip()
    if not text:
        return "（无内容）"
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    s = " ".join(lines)
    return s[:limit] + ("…" if len(s) > limit else "")


def _parse(raw: str) -> dict:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    m = re.search(r'"sql"\s*:\s*"([^"]*)"', raw)
    if m:
        return {"sql": m.group(1)}
    if re.search(r'"sql"\s*:\s*null', raw):
        return {"sql": None}
    return {}


def _keyword_match(question: str, names: list[str]) -> str | None:
    """降级：用问题 2-gram 与文件名重叠度取最高分；无任何重叠返回 None。"""
    q = (question or "").strip()
    grams = {q[i:i + 2] for i in range(len(q) - 1)} if len(q) >= 2 else set()
    best, best_score = None, 0
    for name in names:
        stem = name[:-4] if name.endswith(".sql") else name
        score = sum(1 for g in grams if g in stem)
        if score > best_score:
            best, best_score = name, score
    return best if best_score > 0 else None


def _metric_bare(col: str) -> str:
    """指标名去掉末尾括号单位/口径后缀（ARPU(CNY)→ARPU、达成率(%)→达成率），便于按裸名比对。"""
    return re.sub(r"[（(][^）)]*[）)]$", "", (col or "").lower().strip()).strip()


def _metric_aware_keyword(question: str, names: list[str]) -> str | None:
    """降级匹配：先按文件名 2-gram 重叠；无命中再按「问题里出现声明的指标名」取最高分。

    让「次留」「LTV2」这类指标名即使不在文件名里，也能定位到产出它们的多指标 SQL；
    指标名按「全名」与「裸名（去掉括号单位后缀）」两种口径比对，问「ARPU」也能命中「ARPU(CNY)」。
    """
    by_name = _keyword_match(question, names)
    if by_name:
        return by_name
    q = (question or "").lower()
    best, best_score = None, 0
    for name in names:
        score = 0
        for col in _declared_metrics(name):
            c = (col or "").lower().strip()
            bare = _metric_bare(c)
            if c and c in q or (bare and bare in q):
                score += 1
        if score > best_score:
            best, best_score = name, score
    return best if best_score > 0 else None


_ROLLING_ASK = re.compile(r"(过去|最近|近)\s*(\d+)\s*(天|日)")


def _time_conflicts(question: str, sql_text: str) -> bool:
    """问题明确要「过去/最近N天」滚动窗口，而 SQL 固定取自然周/月/固定日期 → 冲突。

    冲突时返回 True，调用方据此放弃复用该 SQL（宁可 AI 现写，也不套用错误时间窗口）。
    """
    if not _ROLLING_ASK.search(question or ""):
        return False
    return _time_hint(sql_text) in ("上一自然周", "本月/上月（自然月）", "固定日期范围")


def nearest_sql(question: str, game_key: str | None = None) -> str | None:
    """就近 SQL：放宽时间/指标对齐，返回与问题关键词最接近的既有 SQL（供「就近改写」提案）。

    与 match_sql 不同：这里故意忽略时间窗口/指标范围冲突（那正是需要改写的场景），
    先按文件名 2-gram 重叠取最高分，无则按声明指标名命中（如问「次留」定位到多指标 SQL）；
    无任何重叠返回 None。
    """
    names = sql_store.list_sql_files(game_key)
    if not names:
        return None
    return _metric_aware_keyword(question, names)


# ---- 命中既有 SQL 后按问题裁剪结果列（只展示相关指标，维度列始终保留）----

_DIM_KEYS = (
    "日期", "时间", "月份", "周", "年", "地区", "国家", "平台", "渠道", "服务器", "区服",
    "商品", "道具", "等级", "段位", "版本", "系统", "机型", "支付方式", "币种", "类型", "名称",
    "分组", "维度", "date", "time", "month", "week", "year", "region", "country",
    "channel", "platform", "server", "zone", "version",
)

_CROP_SYSTEM = (
    "你是数据分析助手。给定用户问题与一组候选指标列（含中文说明），判断哪些列与问题相关、需要展示给用户。"
    "维度列（日期/地区/国家/商品等分组列）不在候选中、无需你处理。"
    "只输出一个 JSON 数组，元素为要保留的指标列名（必须严格等于候选里的列名），例如 [\"实际(CNY)\"]；"
    "没有相关的就输出 []。不要输出 JSON 以外的任何内容。"
)


def _is_dimension(col: str, df: pd.DataFrame) -> bool:
    """列是否为维度（分组/时间键）：名称含维度关键词，或非数值类型。"""
    try:
        if not pd.api.types.is_numeric_dtype(df[col]):
            return True
    except Exception:
        pass
    low = (col or "").lower()
    return any(k in low for k in _DIM_KEYS)


def _parse_json_list(raw: str) -> list[str] | None:
    try:
        data = json.loads(raw)
        if isinstance(data, list) and all(isinstance(x, str) for x in data):
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    m = re.search(r"\[(.*?)\]", raw or "", re.S)
    if m:
        items = re.findall(r'"([^"]+)"', m.group(1))
        if items:
            return items
    return None


def declared_fields(sql_name: str) -> list[dict]:
    """返回既有 SQL 的字段声明 [{"col": 列名, "desc": 说明}, ...]。

    优先读 .sql.json 的 fields；否则用 sql_store.fields_from_sql 从 SQL 文本
    （头部注释 -- 【输出列】 / SELECT 列别名）推导；都没有返回 []。
    """
    meta = sql_store.read_sql_meta(sql_name) or {}
    fields = meta.get("fields") or []
    if fields:
        return [f for f in fields if isinstance(f, dict) and f.get("col")]
    return sql_store.fields_from_sql(sql_store.read_sql(sql_name))


def _declared_metrics(sql_name: str) -> list[str]:
    """既有 SQL 声明的输出列名（指标 + 维度），去重保序；无声明返回空。"""
    out = []
    for f in declared_fields(sql_name):
        col = (f.get("col") or "").strip()
        if col and col not in out:
            out.append(col)
    return out


def _sql_brief(sql_name: str) -> str:
    """既有 SQL 的一行简介：文件名 + 时间范围 + 输出列（指标名）+ 内容摘要。

    把指标名显式带进匹配清单，让「次留」「LTV2」这类问题能按名命中多指标 SQL，
    不再受「只喂 SQL 前 240 字符」的截断限制。
    """
    text = sql_store.read_sql(sql_name)
    metrics = _declared_metrics(sql_name)
    meta = f"【时间范围：{_time_hint(text)}】"
    if metrics:
        meta += f"【输出列：{'、'.join(metrics)}】"
    return f"- {sql_name}{meta}: {_summarize(text)}"


def crop_columns(model: str, question: str, df: pd.DataFrame, fields: list[dict] | None = None, user: dict | None = None) -> pd.DataFrame:
    """按问题裁剪查询结果列：维度列始终保留，指标列只保留与问题相关的。

    用模型单次判定相关指标列；判定失败回退到「问题 2-gram 与 列名+说明 重叠」；裁剪无效（指标全丢）则返回原表。
    """
    if df is None:
        return df
    cols = list(df.columns)
    if len(cols) <= 2:
        return df
    dims = [c for c in cols if _is_dimension(c, df)]
    metrics = [c for c in cols if c not in dims]
    if len(metrics) <= 1:
        return df
    desc_map = {f.get("col"): (f.get("desc") or "") for f in (fields or []) if isinstance(f, dict) and f.get("col")}
    listing = "\n".join(
        f"- {c}" + (f"：{desc_map[c]}" if desc_map.get(c) else "")
        for c in metrics
    )
    names = None
    try:
        raw = complete_with_fallback(
            model=model,
            messages=[
                {"role": "system", "content": _CROP_SYSTEM},
                {"role": "user", "content": f"用户问题：\n{question}\n\n候选指标列：\n{listing}\n\n请输出要保留的指标列名 JSON 数组。"},
            ],
            user=user,
        )[0]
        names = _parse_json_list(raw)
    except Exception:
        names = None
    if names is None:
        q = (question or "").strip()
        grams = {q[i:i + 2] for i in range(len(q) - 1)} if len(q) >= 2 else set()
        names = [c for c in metrics if any(g in f"{c} {desc_map.get(c, '')}" for g in grams)]
    keep_metrics = [c for c in metrics if c in names]
    if not keep_metrics:
        return df  # 指标全被裁掉 → 宁多勿少，返回原表
    keep = [c for c in cols if c in dims or c in keep_metrics]
    return df[keep]


def match_sql(model: str, question: str, game_key: str | None = None, user: dict | None = None) -> str | None:
    """返回最相关的既有 SQL 文件名（含 .sql 后缀）；无匹配返回 None。"""
    names = sql_store.list_sql_files(game_key)
    if not names:
        return None
    listing = "\n".join(_sql_brief(name) for name in names)
    user_prompt = (
        "# 既有 SQL 清单\n\n"
        f"{listing}\n\n"
        "# 用户问题\n\n"
        f"{(question or '').strip()}\n\n"
        "请判断命中哪条 SQL。"
    )
    try:
        raw = complete_with_fallback(
            model=model,
            messages=[
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": user_prompt},
            ],
            user=user,
        )[0]
    except Exception:
        raw = None
    name = (_parse(raw).get("sql") or "").strip() if raw else ""
    if name in names:
        if _time_conflicts(question, sql_store.read_sql(name)):
            return None  # 命中但时间窗口冲突：放弃复用，交给 AI 现写
        return name
    fallback = _metric_aware_keyword(question, names)
    if fallback and _time_conflicts(question, sql_store.read_sql(fallback)):
        return None
    return fallback
