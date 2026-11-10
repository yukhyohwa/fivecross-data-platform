"""结果 DataFrame → ECharts 图表 spec（启发式推断）。

返回的 spec 结构：{chart_type, x, x_data, series[]}，前端据此渲染，
并支持用户在折线/柱状/饼图/表格间切换（切换只在客户端改 chart_type，无需重新取数）。
"""
import math
import re

import pandas as pd

_MAX_POINTS = 2000

_DATE_STR = re.compile(r"^\d{4}[-/]\d{2}([-/]\d{2})?$")
_TIME_NAME = re.compile(r"^(date|day|dt|time|month|week|year|ds)", re.IGNORECASE)

VALID_TYPES = ("line", "bar", "pie", "stack_bar")

# SQL 头部注释里的图表提示标记（专项可按需声明，驱动各图默认形态，保证不同专项多样性）
_HINT_CHART = {"饼图": "pie", "折线": "line", "折线图": "line", "柱状": "bar", "柱状图": "bar", "堆叠柱状": "stack_bar", "堆叠柱状图": "stack_bar", "表格": "table"}


def parse_chart_hint(sql_text: str) -> dict:
    """从 SQL 头部注释解析图表提示：`-- 【图表】饼图|折线|柱状|表格`、`-- 【右轴】列A,列B`。

    返回 {"chart_type": ..., "right_axis": [...]}；无标记返回 {}。只扫描文件头部的注释块，
    遇到第一行非注释即停止，避免误读正文里的 `--` 行内注释。
    """
    hint: dict = {}
    if not sql_text:
        return hint
    for ln in sql_text.splitlines():
        s = ln.strip()
        if not s.startswith("--"):
            break
        body = s.lstrip("-").strip()
        if body.startswith("【图表】"):
            val = body[len("【图表】"):].strip()
            if val in _HINT_CHART:
                hint["chart_type"] = _HINT_CHART[val]
        elif body.startswith("【右轴】"):
            cols = body[len("【右轴】"):].strip()
            if cols:
                hint["right_axis"] = [c.strip() for c in cols.split(",") if c.strip()]
    return hint


def _numeric_cols(df: pd.DataFrame) -> list[str]:
    return [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])]


def _is_time_like(col_name: str, series: pd.Series) -> bool:
    if _TIME_NAME.match(str(col_name)):
        return True
    if pd.api.types.is_datetime64_any_dtype(series):
        return True
    if series.dtype == object:
        non_null = series.dropna().astype(str)
        if len(non_null) and (
            non_null.head(20).map(lambda v: bool(_DATE_STR.match(v.strip()))).mean() > 0.8
        ):
            return True
    return False


def _safe_num(v):
    """数值安全化：None/NaN/±inf → None；布尔 → 0/1 浮点；整数原样保留（防 2^53 以上流水号/金额分被 float64 舍入）；其余转 float。"""
    if v is None or (isinstance(v, float) and (math.isnan(v) or math.isinf(v))):
        # ±inf 一并归 None：json.dumps 默认 allow_nan 会输出非法的 Infinity 字面量，前端 JSON.parse 抛错会整条丢弃图表事件
        return None
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, int):
        return v
    if pd.isna(v):  # 兜底 pd.NA / pd.NaT 等（numpy 2 下 float64 的 NaN 已被上方分支覆盖）
        return None
    return float(v)


# 成对「上一/最近（或上周/本周、prev/cur）」同指标列的周期前缀，用于把周对比表转置为
# 「2 根周期柱 × 分类堆叠」的堆叠柱状图（段内标注数值 + 占比）。
_PERIOD_PREFIXES = (
    ("上一", "prev"), ("最近", "cur"),
    ("上周", "prev"), ("本周", "cur"),
    ("previous", "prev"), ("current", "cur"),
    ("prev", "prev"), ("last", "prev"), ("cur", "cur"),
)
_PERIOD_LABEL = {"prev": "上周", "cur": "本周"}


def _split_period_col(name: str):
    """把「上一完整周流水(CNY)」拆成 (period, metric)；识别不到返回 None。period ∈ {'prev','cur'}。"""
    low = str(name).strip().lower()
    for prefix, period in _PERIOD_PREFIXES:
        if low.startswith(prefix):
            metric = str(name)[len(prefix):].strip().lstrip("_- ")
            # 「完整周/自然周」是周期修饰，归到周期侧，不在指标名里重复（如「完整周流水(CNY)」→「流水(CNY)」）
            for mod in ("完整自然周", "完整周", "自然周", "整周"):
                if metric.startswith(mod):
                    metric = metric[len(mod):].strip().lstrip("_- ")
                    break
            if metric:
                return period, metric
            return None
    return None


def _try_period_compare(df: pd.DataFrame, chart_type: str) -> dict | None:
    """识别「1 个分类列 + 成对的上一/最近同指标数值列」的周对比表，
    转置为「2 根周期柱（上周/本周）× 分类堆叠」的堆叠柱状 spec（段内标注数值 + 占比）。

    数据形态（宽表，一行一分类）：
        国家 | 上一完整周流水(CNY) | 最近完整周流水(CNY)
    转置后 spec：
        x_data=[上周, 本周]，series=每个分类一根（data=[上一值, 最近值]）。
    不匹配（非堆叠柱状 / 多分类列 / 非成对周期列）返回 None，走通用推断。
    """
    if chart_type != "stack_bar":
        return None
    num_cols = _numeric_cols(df)
    cat_cols = [c for c in df.columns if c not in num_cols]
    if len(cat_cols) != 1:
        return None
    cat_col = cat_cols[0]

    groups: dict[str, dict[str, str]] = {}
    for c in num_cols:
        parsed = _split_period_col(c)
        if not parsed:
            return None
        side, metric = parsed
        slot = groups.setdefault(metric, {})
        if side in slot:
            return None  # 同一指标出现重复周期列，无法唯一映射
        slot[side] = c

    # 只支持「恰好一个指标，且该指标同时有上一 + 最近」的对比表
    if len(groups) != 1:
        return None
    metric, sides = next(iter(groups.items()))
    if "prev" not in sides or "cur" not in sides:
        return None

    prev_col, cur_col = sides["prev"], sides["cur"]
    cats = df[cat_col].astype(str).tolist()
    prev_data = [_safe_num(v) for v in df[prev_col].tolist()]
    cur_data = [_safe_num(v) for v in df[cur_col].tolist()]
    series = [
        {"name": str(c), "data": [p, q]}
        for c, p, q in zip(cats, prev_data, cur_data)
    ]
    return {
        "chart_type": "stack_bar",
        "x": "周期",
        "x_data": [_PERIOD_LABEL["prev"], _PERIOD_LABEL["cur"]],
        "series": series,
        "stack_pct_label": True,  # 前端据此在堆叠段内标注「数值 + 占比」
        "stack_metric": metric,   # 前端标题展示用（如「流水(CNY)」「消耗喵果」）
    }


def build_chart_spec(df: pd.DataFrame, override: str = "auto", hint: dict | None = None) -> dict:
    df = df.dropna(how="all").head(_MAX_POINTS)
    if df.empty:
        return {"chart_type": "table", "x": None, "x_data": [], "series": []}

    num_cols = _numeric_cols(df)
    hint = hint or {}

    # 图表类型：用户手动切换 > 专项声明的「图表」提示；两者都没有时先记 None，稍后启发式推断
    if override in VALID_TYPES:
        chart_type = override
    elif hint.get("chart_type"):
        chart_type = hint["chart_type"]
    else:
        chart_type = None

    # 选择 x 轴：优先时间列，其次第一个非数值列；没有任何非数值列时不设 x，改用行号。
    # 饼图例外：饼图的分片是「分类维度」（国家 / 商品），不是时间轴，只取第一个非数值列，
    # 避免 SQL 同时带了周期 / 日期列时饼图错把时间当分片（此前付费国家构成 / 喵果消耗曾因此错展成时间）。
    x_col = None
    if chart_type == "pie":
        # 饼图分片是「分类维度」（国家 / 商品），排除时间列；全为时间列时兜底用第一个非数值列。
        cat_cols = [c for c in df.columns if c not in num_cols]
        dim_cols = [c for c in cat_cols if not _is_time_like(c, df[c])]
        if dim_cols:
            x_col = dim_cols[0]
        elif cat_cols:
            x_col = cat_cols[0]
    else:
        for c in df.columns:
            if c in num_cols:
                continue
            if _is_time_like(c, df[c]):
                x_col = c
                break
        if x_col is None:
            cat_cols = [c for c in df.columns if c not in num_cols]
            if cat_cols:
                x_col = cat_cols[0]

    if x_col is None:
        # 无任何非数值列：用行号做 x，避免把数值列既当 x 又当 series 重复计数
        x_data = [str(i) for i in range(1, len(df) + 1)]
    else:
        x_data = df[x_col].astype(str).tolist()

    series = [
        {"name": str(c), "data": [_safe_num(v) for v in df[c].tolist()]}
        for c in num_cols
    ]

    # 图表类型启发式推断（仅当没有手动切换 / 专项「图表」提示时）
    if chart_type is None:
        if x_col is not None and _is_time_like(x_col, df[x_col]) and num_cols:
            chart_type = "line"
        else:
            chart_type = "bar"

    # 饼图需要至少一个数值序列（前端取 series[0] 作数值、x 作分类）
    if chart_type == "pie" and not series:
        chart_type = "bar"

    # 堆叠柱状至少要有两个数值序列才有「堆叠」意义，否则退化为普通柱状
    if chart_type == "stack_bar" and len(series) < 2:
        chart_type = "bar"

    # 周对比表（「上一/最近」成对同指标列）转置为「2 根周期柱 × 分类堆叠」，段内标注数值 + 占比
    cmp_spec = _try_period_compare(df, chart_type)
    if cmp_spec is not None:
        return cmp_spec

    spec = {
        "chart_type": chart_type,
        "x": None if x_col is None else str(x_col),
        "x_data": x_data,
        "series": series,
    }
    # x 轴存在重复值，前端可据此提示
    if x_col and len(set(x_data)) != len(x_data):
        spec["x_duplicates"] = True
    # 双轴：右轴列（如 ARPU/达成率 等小数值指标），只保留真实存在的列名
    right_axis = [c for c in (hint.get("right_axis") or []) if any(s["name"] == c for s in series)]
    if right_axis:
        spec["y_axes"] = {"right": right_axis}
    return spec


def _format_value(v) -> str:
    """整数→千分位无小数；小数→千分位保留 2 位；None→占位符。"""
    if v is None:
        return "—"
    v = float(v)
    if abs(v - round(v)) < 1e-9:
        return f"{int(round(v)):,}"
    return f"{v:,.2f}"


def _kpi(label: str, value, delta, hint: str) -> dict:
    if delta is None:
        delta_dir = None
    elif delta > 0:
        delta_dir = "up"
    elif delta < 0:
        delta_dir = "down"
    else:
        delta_dir = "flat"
    return {
        "label": str(label),
        "value": value,
        "value_str": _format_value(value),
        "delta_pct": delta,
        "delta_dir": delta_dir,
        "hint": hint,
    }


def build_kpis(df: pd.DataFrame, max_kpis: int = 4) -> list[dict]:
    """从查询结果提炼 KPI 大数字卡片。返回 [{label, value_str, delta_pct, delta_dir, hint}]。"""
    df = df.dropna(how="all")
    if df.empty:
        return []
    num_cols = _numeric_cols(df)
    if not num_cols:
        return []
    # 有明确时间列 → 用「最近一行 vs 上一行」算环比；否则用「合计」
    x_col = None
    for c in df.columns:
        if c in num_cols:
            continue
        if _is_time_like(c, df[c]):
            x_col = c
            break
    if x_col is not None:
        # 仅用于算环比：按时间列升序，避免 SQL 里 ORDER BY date DESC 时「最新/上一期」取反
        df = df.sort_values(x_col)
    kpis = []
    for c in num_cols[:max_kpis]:
        col = df[c].dropna()
        if col.empty:
            continue
        if x_col is not None and len(col) >= 2:
            latest = _safe_num(col.iloc[-1])
            prev = _safe_num(col.iloc[-2])
            delta = None if (latest is None or prev in (None, 0)) else round((latest - prev) / abs(prev) * 100, 1)
            kpis.append(_kpi(c, latest, delta, "较上一周期"))
        else:
            kpis.append(_kpi(c, _safe_num(col.sum()), None, "合计"))
    return kpis
