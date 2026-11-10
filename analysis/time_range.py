"""时间范围解析 + SQL 日期替换（确定性，跨工具共用）。

两条能力，都与「把 date 时间范围确定化」有关：

- parse_time_range：把聊天/专项里的自然语言时间意图解析成明确的 [start, end]（YYYY-MM-DD），
  能确定算清的范围不交给模型猜；解析不了（含糊、未来时间）返回 (None, None) 交回 LLM。
- apply_date_range：把 SQL 里的相对时间表达式（current_date()/now() 等）确定性替换成明确起止日期。
  原实现位于 data_ai/backend/services/report.py，上收至此作为单一来源。

时间口径约定：
- 「近/最近/过去 N 天/周/月」：滚动窗口，截止到昨天（与取数 SQL 默认 `date < current_date()`
  及预测层「今日数据不完整」一致）；
- 「本周/本月/今年/今年以来/年初至今」：自然周期进行时，截止到今天；
- 「上周/上月/去年/上季度」：完整自然周期；
- 「明天/后天/下周/下个月/明年」等未来时间：不解析（返回 None，交回 LLM）。
"""
from __future__ import annotations

import calendar
import re
from datetime import date, timedelta

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# ---- 中文数字（0~99）----
_CN_DIGITS = {"零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
              "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}
_NUM = r"\d+|[零一二两三四五六七八九十]+"

# ---- 明确日期锚点 ----
_FULL_DATE_RE = re.compile(r"(?<!\d)(20\d{2})[-/.年](\d{1,2})[-/.月](\d{1,2})[日号]?(?!\d)")
_COMPACT_DATE_RE = re.compile(r"(?<!\d)(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)")
_YM_RE = re.compile(r"(?<!\d)(20\d{2})[-/.年](\d{1,2})月?(?!\d)")
_MONTH_ONLY_RE = re.compile(r"(?<!\d)(\d{1,2})月(?:份)?(?!\d)")
_YEAR_RE = re.compile(r"(?<!\d)(20\d{2})年(?!\d)")

# ---- 相对窗口 ----
_REL_NEAR_DAY = re.compile(r"(?:最近|过去|近)\s*(" + _NUM + r")\s*天")
_REL_NEAR_WEEK = re.compile(r"(?:最近|过去|近)\s*(" + _NUM + r")\s*周")
_REL_NEAR_MONTH = re.compile(r"(?:最近|过去|近)\s*(" + _NUM + r")\s*个?\s*月")


def _iso(d: date) -> str:
    return d.strftime("%Y-%m-%d")


def _cn_num(s: str) -> int | None:
    """解析 0~99 的中文/阿拉伯数字，解析不了返回 None。"""
    if not s:
        return None
    if s.isdigit():
        return int(s)
    if s == "十":
        return 10
    if s in _CN_DIGITS:
        return _CN_DIGITS[s]
    if s.startswith("十") and len(s) == 2:  # 十一~十九
        return 10 + _CN_DIGITS.get(s[1], 0)
    if s.endswith("十") and len(s) == 2:  # 二十~九十
        return _CN_DIGITS.get(s[0], 0) * 10
    if len(s) == 3 and s[1] == "十":  # 二十一~九十九
        tens, ones = _CN_DIGITS.get(s[0]), _CN_DIGITS.get(s[2])
        if tens is not None and ones is not None:
            return tens * 10 + ones
    if len(s) == 2 and s[1] != "十":
        tens, ones = _CN_DIGITS.get(s[0]), _CN_DIGITS.get(s[1])
        if tens is not None and ones is not None:
            return tens * 10 + ones
    return None


def _mk_date(y: str, m: str, d: str) -> date | None:
    try:
        return date(int(y), int(m), int(d))
    except ValueError:
        return None


def _month_range(y: int, m: int) -> tuple[date, date]:
    return date(y, m, 1), date(y, m, calendar.monthrange(y, m)[1])


def _quarter_range(y: int, qn: int) -> tuple[date, date]:
    start_month = (qn - 1) * 3 + 1
    return date(y, start_month, 1), date(y, start_month + 2, calendar.monthrange(y, start_month + 2)[1])


def _last_month(today: date) -> tuple[date, date]:
    if today.month == 1:
        return date(today.year - 1, 12, 1), date(today.year - 1, 12, 31)
    return date(today.year, today.month - 1, 1), date(today.year, today.month, 1) - timedelta(days=1)


def _add_months(d: date, delta: int) -> date:
    m = d.year * 12 + (d.month - 1) + delta
    y, mo = divmod(m, 12)
    mo += 1
    return date(y, mo, min(d.day, calendar.monthrange(y, mo)[1]))


def _explicit_range(q: str) -> tuple[str, str] | None:
    """两个明确日期 + 连接词 → (start, end)；单个明确日期 → (当天, 当天)。无则 None。"""
    anchors = []
    for m in _FULL_DATE_RE.finditer(q):
        d = _mk_date(m.group(1), m.group(2), m.group(3))
        if d:
            anchors.append((m.start(), d))
    for m in _COMPACT_DATE_RE.finditer(q):
        d = _mk_date(m.group(1), m.group(2), m.group(3))
        if d:
            anchors.append((m.start(), d))
    anchors.sort()
    if not anchors:
        return None
    if len(anchors) >= 2:
        between = q[anchors[0][0]:anchors[1][0]]
        if re.search(r"到|至|~|～|—|－|-|between|and", between, re.IGNORECASE):
            lo, hi = (anchors[0][1], anchors[1][1]) if anchors[0][1] <= anchors[1][1] else (anchors[1][1], anchors[0][1])
            return _iso(lo), _iso(hi)
    return _iso(anchors[0][1]), _iso(anchors[0][1])


def _monthday_range(q: str, today: date) -> tuple[str, str] | None:
    """「[年]月日 到 [年]月日」或「[年]月日 到 日」的月-日区间（年可省略）。

    覆盖 _explicit_range 抓不到的无年 / 缩写尾日写法，如：
    9月1日~9月15日、9月1日~15日、2026年9月1日~15日、2026年9月1日到9月15日。
    未写年份用 today.year；结束月早于起始月且未写年份时按跨年。无则 None。
    """
    conn = r"(?:到|至|~|～|—|－|-|between|and)"
    # 两个「[年]月日」锚点
    m = re.search(
        rf"(?<!\d)(?:(20\d{{2}})\s*年\s*)?(\d{{1,2}})\s*月\s*(\d{{1,2}})\s*[日号]?"
        rf"\s*{conn}\s*"
        rf"(?:(20\d{{2}})\s*年\s*)?(\d{{1,2}})\s*月\s*(\d{{1,2}})\s*[日号]?(?!\d)",
        q, re.IGNORECASE,
    )
    if m:
        y1 = int(m.group(1)) if m.group(1) else today.year
        mo1, d1 = int(m.group(2)), int(m.group(3))
        mo2, d2 = int(m.group(5)), int(m.group(6))
        y2 = int(m.group(4)) if m.group(4) else (y1 + 1 if mo2 < mo1 else y1)
        s = _mk_date(y1, mo1, d1)
        e = _mk_date(y2, mo2, d2)
        if s and e:
            if e < s:
                s, e = e, s
            return _iso(s), _iso(e)
    # 一个「[年]月日」+ 缩写尾日（同月）：9月1日~15日 / 2026年9月1日~15日
    m = re.search(
        rf"(?<!\d)(?:(20\d{{2}})\s*年\s*)?(\d{{1,2}})\s*月\s*(\d{{1,2}})\s*[日号]?"
        rf"\s*{conn}\s*"
        rf"(\d{{1,2}})\s*[日号](?!\d)",
        q, re.IGNORECASE,
    )
    if m:
        y = int(m.group(1)) if m.group(1) else today.year
        mo, d1, d2 = int(m.group(2)), int(m.group(3)), int(m.group(4))
        s = _mk_date(y, mo, d1)
        e = _mk_date(y, mo, d2)
        if s and e:
            if e < s:
                s, e = e, s
            return _iso(s), _iso(e)
    return None


# 「年 + 起月 ~ 止月」区间（如 2026年10月~12月 / 10月到12月 / 2026年10月到2027年1月）
_MONTH_SPAN_RE = re.compile(
    r"(?<!\d)(?:(20\d{2})\s*年\s*)?(\d{1,2})\s*月(?:份)?"
    r"\s*(?:到|至|~|～|—|－|－|-|between|and)\s*"
    r"(?:(20\d{2})\s*年\s*)?(\d{1,2})\s*月"
)


def _month_span(q: str, today: date) -> tuple[str, str] | None:
    """解析「年 + 起月 ~ 止月」区间，返回 (月初, 月末)；解析不了返回 None。

    结束月未写年份沿用起始年；结束月早于起始月且未写年份时视为跨年（如「11月到1月」）。
    """
    m = _MONTH_SPAN_RE.search(q)
    if not m:
        return None
    y1_s, m1_s, y2_s, m2_s = m.group(1), m.group(2), m.group(3), m.group(4)
    m1, m2 = int(m1_s), int(m2_s)
    if not (1 <= m1 <= 12 and 1 <= m2 <= 12):
        return None
    y1 = int(y1_s) if y1_s else today.year
    y2 = int(y2_s) if y2_s else (y1 + 1 if m2 < m1 else y1)
    s = date(y1, m1, 1)
    e = date(y2, m2, calendar.monthrange(y2, m2)[1])
    if e < s:
        s, e = e, s
    return _iso(s), _iso(e)


def _quarter_number(q: str) -> int | None:
    m = re.search(r"([一二三四1234])\s*季度", q)
    if m:
        return {"一": 1, "1": 1, "二": 2, "2": 2, "三": 3, "3": 3, "四": 4, "4": 4}[m.group(1)]
    m = re.search(r"Q\s*([1-4])", q, re.IGNORECASE)
    if m:
        return int(m.group(1))
    return None


def _single_anchor(q: str, today: date) -> tuple[str, str] | None:
    m = _YM_RE.search(q)
    if m:
        s, e = _month_range(int(m.group(1)), int(m.group(2)))
        return _iso(s), _iso(e)
    m = _MONTH_ONLY_RE.search(q)
    if m:
        s, e = _month_range(today.year, int(m.group(1)))
        return _iso(s), _iso(e)
    m = _YEAR_RE.search(q)
    if m:
        y = int(m.group(1))
        return _iso(date(y, 1, 1)), _iso(date(y, 12, 31))
    qn = _quarter_number(q)
    if qn:
        s, e = _quarter_range(today.year, qn)
        return _iso(s), _iso(e)
    return None


def _relative(q: str, today: date) -> tuple[str, str] | None:
    if re.search(r"上周", q):
        this_mon = today - timedelta(days=today.weekday())
        last_mon = this_mon - timedelta(days=7)
        return _iso(last_mon), _iso(last_mon + timedelta(days=6))
    if re.search(r"本周|这周", q):
        this_mon = today - timedelta(days=today.weekday())
        return _iso(this_mon), _iso(today)
    if re.search(r"昨天", q):
        d = today - timedelta(days=1)
        return _iso(d), _iso(d)
    if re.search(r"今天", q):
        return _iso(today), _iso(today)
    if re.search(r"上个月|上月", q):
        s, e = _last_month(today)
        return _iso(s), _iso(e)
    if re.search(r"这个月|本月", q):
        return _iso(date(today.year, today.month, 1)), _iso(today)
    if re.search(r"去年", q):
        return _iso(date(today.year - 1, 1, 1)), _iso(date(today.year - 1, 12, 31))
    if re.search(r"今年以来|今年|年初至今|YTD", q, re.IGNORECASE):
        return _iso(date(today.year, 1, 1)), _iso(today)
    if re.search(r"上季度|上个季度", q):
        cur = (today.month - 1) // 3 + 1
        qn = cur - 1
        if qn == 0:
            s, e = _quarter_range(today.year - 1, 4)
        else:
            s, e = _quarter_range(today.year, qn)
        return _iso(s), _iso(e)
    m = _REL_NEAR_DAY.search(q)
    if m:
        n = _cn_num(m.group(1))
        if n:
            return _iso(today - timedelta(days=n)), _iso(today - timedelta(days=1))
    m = _REL_NEAR_WEEK.search(q)
    if m:
        n = _cn_num(m.group(1))
        if n:
            return _iso(today - timedelta(weeks=n)), _iso(today - timedelta(days=1))
    m = _REL_NEAR_MONTH.search(q)
    if m:
        n = _cn_num(m.group(1))
        if n:
            return _iso(_add_months(today, -n)), _iso(today - timedelta(days=1))
    return None


def parse_time_range(question: str, today: date | None = None) -> tuple[str | None, str | None]:
    """把问题里的时间意图解析成 (start, end)（YYYY-MM-DD）；解析不了返回 (None, None)。"""
    q = (question or "").strip()
    if not q:
        return None, None
    today = today or date.today()

    r = _monthday_range(q, today)
    if r:
        return r
    r = _explicit_range(q)
    if r:
        return r
    r = _month_span(q, today)
    if r:
        return r
    r = _single_anchor(q, today)
    if r:
        return r
    if re.search(r"明天|后天|下周|下个月|下月|明年", q):
        return None, None
    r = _relative(q, today)
    if r:
        return r
    return None, None


def apply_date_range(sql: str, start: str | None, end: str | None) -> str:
    """把相对时间表达式替换成起止日期区间。

    - date_sub(current_date(), interval N day/week/month) / current_date() - interval N day/week/month → '{start}'
    - date_trunc('week', current_date()) - interval N day/week/month（周界起始）→ '{start}'
    - date_trunc('week', current_date())（周界结束，不后随 - interval）→ '{end}'
    - current_date() / now() → '{end}'
    顺序先处理带 interval 的表达式，再处理周界结束与裸 current_date()/now()。
    只传 start 或 end 时只替换对应一侧；start/end 必须为 YYYY-MM-DD，否则抛 ValueError。
    """
    if not sql:
        return sql
    if start and not _DATE_RE.match(start):
        raise ValueError(f"start_date 格式非法：{start!r}，必须是 YYYY-MM-DD（如 2026-09-18）")
    if end and not _DATE_RE.match(end):
        raise ValueError(f"end_date 格式非法：{end!r}，必须是 YYYY-MM-DD（如 2026-09-18）")

    interval_unit = r"(?:day|week|month)"
    week_cdate = r"(?:current_date\s*\(\s*\)|now\s*\(\s*\))"

    if start:
        sql = re.sub(
            rf"date_sub\s*\(\s*current_date\s*\(\s*\)\s*,\s*interval\s+\d+\s+{interval_unit}\s*\)",
            f"'{start}'",
            sql,
            flags=re.IGNORECASE,
        )
        sql = re.sub(
            rf"current_date\s*\(\s*\)\s*-\s*interval\s+\d+\s+{interval_unit}\b",
            f"'{start}'",
            sql,
            flags=re.IGNORECASE,
        )
        sql = re.sub(
            rf"date_trunc\s*\(\s*['\"]week['\"]\s*,\s*{week_cdate}\s*\)\s*-\s*interval\s+\d+\s+{interval_unit}\b",
            f"'{start}'",
            sql,
            flags=re.IGNORECASE,
        )
    if end:
        # end 为含当天的上界。原 SQL 里 `date < current_date()`（早于今天 = 截止到昨天）
        # 应等价替换成 `date < end+1`，否则会少算 end 当天（off-by-one）。
        end_next = (date.fromisoformat(end) + timedelta(days=1)).isoformat()
        sql = re.sub(
            rf"date_trunc\s*\(\s*['\"]week['\"]\s*,\s*{week_cdate}\s*\)(?!\s*-\s*interval)",
            f"'{end}'",
            sql,
            flags=re.IGNORECASE,
        )
        bound_cdate = r"(?:current_date\s*\(\s*\)|\bnow\s*\(\s*\))"
        # 含上界 <= current_date()/now() → <= end（end 已含当天，无需 +1）
        sql = re.sub(rf"(<=\s*){bound_cdate}", rf"\1'{end}'", sql, flags=re.IGNORECASE)
        # 排他上界 < current_date()/now() → < end+1
        sql = re.sub(rf"(<\s*){bound_cdate}", rf"\1'{end_next}'", sql, flags=re.IGNORECASE)
        # 其余裸 current_date()/now()（between 上界、date_trunc 参数等）→ end。
        # 但区间起点形态（current_date() - interval N、date_sub(...)、
        # date_trunc('week', ...) - interval N）属于 start 侧：只传 end（start 为空）时
        # 若被兜底替换成 end 会算错区间，先整体冻结、替换后再原样还原。
        _start_bound = (
            rf"date_sub\s*\(\s*current_date\s*\(\s*\)\s*,\s*interval\s+\d+\s+{interval_unit}\s*\)"
            rf"|current_date\s*\(\s*\)\s*-\s*interval\s+\d+\s+{interval_unit}\b"
            rf"|date_trunc\s*\(\s*['\"]week['\"]\s*,\s*{week_cdate}\s*\)\s*-\s*interval\s+\d+\s+{interval_unit}\b"
        )
        frozen: list[str] = []
        def _freeze(m):
            frozen.append(m.group(0))
            return f"\x00{len(frozen) - 1}\x00"
        sql = re.sub(_start_bound, _freeze, sql, flags=re.IGNORECASE)
        sql = re.sub(r"current_date\s*\(\s*\)", f"'{end}'", sql, flags=re.IGNORECASE)
        sql = re.sub(r"\bnow\s*\(\s*\)", f"'{end}'", sql, flags=re.IGNORECASE)
        for i, orig in enumerate(frozen):
            sql = sql.replace(f"\x00{i}\x00", orig)
    return sql
