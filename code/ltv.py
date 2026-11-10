"""LTV 预测：分日留存 × 留存ARPU 递推累计 LTV。

口径（2026-10-30 用户拍板）：
- 取数由「买量投放KPI」改写为分日长表（code/ltv.sql），每行一个 cohort×留存天数：
  注册日期 / 留存天数 / 注册人数 / 留存人数 / 留存率 / 分日LTV增长金额(USD) / 留存ARPU(USD)。
- 留存ARPU = 分日 LTV 增长金额 ÷ 当日留存用户（d=0 时留存用户=注册用户，留存率恒 1）。
- LTV = Σ_d 留存率_d × 留存ARPU_d（等价 累计付费金额 ÷ 注册用户）。

拟合口径（与 JoyTools 留存模型一致）：
- 留存率：exp2 双指数 c + a1·e^(-b1·t) + a2·e^(-b2·t)，b1/b2 对数网格 + 线性最小二乘；
  实测点 < 3 个回退相邻实测点水平外推（保守）。
- 留存ARPU：指数衰减 A·e^(-b·d) + C（A,C≥0），b 对数网格 + 线性最小二乘；实测点 < 3 个
  回退「末个有效 ARPU 水平外推」；无任何付费数据则 ARPU 全 0、LTV=0 并注明。
- 多 cohort 按全量加权池化：留存率 = Σ留存人数/Σ注册人数，留存ARPU = Σ付费金额/Σ留存人数。

沙箱说明：chat_bi 模型沙箱只放行 numpy/pandas/math/datetime/json/re/time，故拟合用
纯 numpy 网格搜索 + 线性最小二乘等价实现（不 import scipy/warnings）。
固定签名：def run(df_hist, pred_end, **params) -> {"tables": [...], "meta": {...}}
"""
import numpy as np
import pandas as pd

# LTV 里程碑观察点（0日/1日/3日/7日/14日/30日/60日/90日/180日/360日）
MILESTONES = [0, 1, 3, 7, 14, 30, 60, 90, 180, 360]
MIN_DAYS, MAX_DAYS = 2, 1800
DEFAULT_DAYS = 360


def exp2_model(t, a1, b1, a2, b2, c):
    """双指数留存模型：c + a1·e^(-b1·t) + a2·e^(-b2·t)。"""
    t_arr = np.asarray(t, dtype=float)
    return c + a1 * np.exp(-b1 * t_arr) + a2 * np.exp(-b2 * t_arr)


def fit_exp2(x, y):
    """双指数留存拟合（纯 numpy）：b1/b2 对数网格 + 线性最小二乘。

    参数界限与 JoyTools exp2_fix 一致：a1/a2/c∈[0,1]；b1/b2 取对数网格（1e-5~1）。
    网格全局取 SSE 最小，返回 (params, sse)：params=[a1,b1,a2,b2,c]。
    """
    x_arr = np.asarray(x, dtype=float)
    y_arr = np.asarray(y, dtype=float)
    grid_b = np.logspace(-5.0, 0.0, 25)
    best = None  # (sse, a1, b1, a2, b2, c)
    with np.errstate(all="ignore"):
        for b1 in grid_b:
            e1 = np.exp(-b1 * x_arr)
            for b2 in grid_b:
                if b2 >= b1:
                    continue  # (b1,b2) 与 (b2,b1) 对称，只算 b1>b2
                design = np.column_stack([e1, np.exp(-b2 * x_arr), np.ones_like(x_arr)])
                coef, _, _, _ = np.linalg.lstsq(design, y_arr, rcond=None)
                a1v = min(max(float(coef[0]), 0.0), 1.0)
                a2v = min(max(float(coef[1]), 0.0), 1.0)
                cv = min(max(float(coef[2]), 0.0), 1.0)
                sse = float(np.sum((y_arr - exp2_model(x_arr, a1v, b1, a2v, b2, cv)) ** 2))
                if best is None or sse < best[0]:
                    best = (sse, a1v, float(b1), a2v, float(b2), cv)
    if best is None:  # 理论不可达，保守回退
        return [float(np.max(y_arr)), 1.0, 0.0, 0.0, 0.0], float("inf")
    return [best[1], best[2], best[3], best[4], best[5]], best[0]


def arpu_decay_model(d, A, b, C):
    """留存ARPU 指数衰减模型：A·e^(-b·d) + C（A=衰减幅度、C=长期稳态 ARPU）。"""
    d_arr = np.asarray(d, dtype=float)
    return A * np.exp(-b * d_arr) + C


def fit_arpu_decay(x, y):
    """留存ARPU 指数衰减拟合：A·e^(-b·d)+C，b 对数网格 + 线性最小二乘（A,C≥0）。

    b 网格覆盖 1e-4~1；返回 (params, sse)：params=[A,b,C]。
    """
    x_arr = np.asarray(x, dtype=float)
    y_arr = np.asarray(y, dtype=float)
    grid_b = np.logspace(-4.0, 0.0, 30)
    best = None  # (sse, A, b, C)
    with np.errstate(all="ignore"):
        for b in grid_b:
            e = np.exp(-b * x_arr)
            design = np.column_stack([e, np.ones_like(x_arr)])
            coef, _, _, _ = np.linalg.lstsq(design, y_arr, rcond=None)
            A = max(float(coef[0]), 0.0)
            C = max(float(coef[1]), 0.0)
            sse = float(np.sum((y_arr - arpu_decay_model(x_arr, A, b, C)) ** 2))
            if best is None or sse < best[0]:
                best = (sse, A, float(b), C)
    if best is None:  # 理论不可达，回退恒定均值
        return [0.0, 0.0, float(np.mean(y_arr))], float("inf")
    return [best[1], best[2], best[3]], best[0]


def r2_from_sse(x, y, sse):
    """由残差平方和算决定系数 R²（拟合优度）。"""
    y_arr = np.asarray(y, dtype=float)
    sst = float(np.sum((y_arr - np.mean(y_arr)) ** 2))
    if sst < 1e-15:
        return 1.0
    return min(1.0 - sse / sst, 1.0)


def _rate_scale(vals):
    """留存率数值口径：任一值 >1.5 视为百分数，否则视为 0~1 比例。"""
    vals = [float(v) for v in vals if v is not None]
    return "percent" if any(abs(v) > 1.5 for v in vals) else "ratio"


def _norm_rate(v, scale):
    """按口径把留存率归一成 0~1 比例。"""
    if scale == "percent":
        return min(max(v / 100.0, 0.0), 1.0)
    return min(max(v, 0.0), 1.0)


def _find_col(df, *tokens):
    """按子串（含中文/英文）匹配第一个列名；找不到返回 None。"""
    for c in df.columns:
        s = str(c)
        for t in tokens:
            if t in s:
                return c
    return None


def _parse_series(df_hist):
    """把 df_hist 解析成 per-cohort×留存天数 记录列表。

    自动识别列（中文优先，兼容离线上传模板与 currency 后缀剥离后的列名）：
      留存天数 / 注册人数 / 留存人数 / 留存率 / 分日LTV增长金额 / 留存ARPU / 注册日期(可选)。
    返回 (records, meta)：records 为 dict 列表；meta 含列识别说明。
    """
    day_col = _find_col(df_hist, "留存天数", "天数", "天", "day")
    reg_col = _find_col(df_hist, "注册人数", "新增人数", "新增用户", "注册用户")
    ret_col = _find_col(df_hist, "留存人数", "留存用户")
    rev_col = _find_col(df_hist, "分日LTV增长金额", "LTV增长金额", "增长金额", "付费金额", "收入", "revenue")
    rate_col = _find_col(df_hist, "留存率", "retention")
    arpu_col = _find_col(df_hist, "留存ARPU", "ARPU")
    cohort_col = _find_col(df_hist, "注册日期", "队列", "cohort", "锚点")

    if day_col is None:
        raise ValueError("df_hist 未识别「留存天数」列（需 留存天数/天数/day 之一）")
    if rate_col is None and ret_col is None:
        raise ValueError("df_hist 未识别留存列（需 留存率 或 留存人数）")
    if rev_col is None and arpu_col is None:
        raise ValueError("df_hist 未识别付费列（需 分日LTV增长金额 或 留存ARPU）")

    day_series = pd.to_numeric(df_hist[day_col], errors="coerce")
    records = []
    for idx in range(len(df_hist)):
        d = day_series.iloc[idx]
        if pd.isna(d) or float(d) < 0:
            continue
        rec = {"day": int(float(d))}
        if cohort_col is not None:
            v = df_hist[cohort_col].iloc[idx]
            if v is not None and not pd.isna(v):
                rec["cohort"] = str(v)
        if reg_col is not None:
            v = pd.to_numeric(df_hist[reg_col].iloc[idx], errors="coerce")
            if not pd.isna(v):
                rec["reg"] = float(v)
        if ret_col is not None:
            v = pd.to_numeric(df_hist[ret_col].iloc[idx], errors="coerce")
            if not pd.isna(v):
                rec["ret"] = float(v)
        if rev_col is not None:
            v = pd.to_numeric(df_hist[rev_col].iloc[idx], errors="coerce")
            if not pd.isna(v):
                rec["rev"] = float(v)
        if rate_col is not None:
            v = pd.to_numeric(df_hist[rate_col].iloc[idx], errors="coerce")
            if not pd.isna(v):
                rec["rate"] = float(v)
        if arpu_col is not None:
            v = pd.to_numeric(df_hist[arpu_col].iloc[idx], errors="coerce")
            if not pd.isna(v):
                rec["arpu"] = float(v)
        records.append(rec)
    if not records:
        raise ValueError("df_hist 解析后无任何有效分日记录，无法预测")
    return records, (day_col, reg_col, ret_col, rev_col, rate_col, arpu_col, cohort_col)


def _pool(records):
    """按留存天数 d 池化多 cohort：计数口径（reg/ret/rev 求和）优先，否则按 rate/arpu 均值。

    返回 {d: {"reg","ret","rev","rate","arpu"}}，arpu 在留存人数为 0 时为 None。
    """
    has_counts = (
        any(r.get("reg") is not None for r in records)
        and any(r.get("ret") is not None for r in records)
        and any(r.get("rev") is not None for r in records)
    )
    agg = {}
    for rec in records:
        d = rec["day"]
        a = agg.setdefault(d, {"reg": 0.0, "ret": 0.0, "rev": 0.0, "rate": [], "arpu": []})
        if has_counts:
            a["reg"] += rec.get("reg") or 0.0
            a["ret"] += rec.get("ret") or 0.0
            a["rev"] += rec.get("rev") or 0.0
        else:
            if rec.get("rate") is not None:
                a["rate"].append(rec["rate"])
            if rec.get("arpu") is not None:
                a["arpu"].append(rec["arpu"])
    out = {}
    for d in sorted(agg):
        a = agg[d]
        if has_counts:
            reg = a["reg"]
            if reg <= 0:
                continue
            ret = a["ret"]
            rev = a["rev"]
            out[d] = {
                "reg": reg, "ret": ret, "rev": rev,
                "rate": ret / reg,
                "arpu": rev / ret if ret > 0 else None,
            }
        else:
            rates = [v for v in a["rate"] if v is not None]
            arpus = [v for v in a["arpu"] if v is not None]
            if not rates:
                continue
            out[d] = {
                "reg": 0.0, "ret": 0.0, "rev": 0.0,
                "rate": float(np.mean(rates)),
                "arpu": float(np.mean(arpus)) if arpus else None,
            }
    return out


def _retention_curve(obs_days, rate_obs, days):
    """拟合/外推留存率曲线（0..days）。返回 (curve, params, r2, model)。"""
    xs = np.array(obs_days, dtype=float)
    ys = np.array([rate_obs[d] for d in obs_days], dtype=float)
    if len(xs) >= 3:
        params, sse = fit_exp2(xs, ys)
        r2 = r2_from_sse(xs, ys, sse)
        t = np.arange(days + 1, dtype=float)
        curve = np.clip(exp2_model(t, *params), 0.0, 1.0)
        if 0 in obs_days:
            curve[0] = 1.0  # 第 0 天留存恒为 1（注册日全员在档）
        return curve, params, r2, "exp2"
    # 实测点不足：相邻实测点水平外推（保守）
    curve = np.empty(days + 1)
    curve[0] = 1.0
    for d in range(1, days + 1):
        below = [kd for kd in obs_days if kd <= d]
        curve[d] = rate_obs[below[-1]] if below else rate_obs[obs_days[0]]
    return curve, None, None, "保守口径"


def _arpu_curve(obs_days, arpu_obs, days):
    """拟合/外推留存ARPU 曲线（0..days）。返回 (curve, params, r2, model)。"""
    pts = [(d, arpu_obs[d]) for d in obs_days if arpu_obs[d] is not None]
    if not pts or float(np.max([p[1] for p in pts])) <= 0:
        return np.zeros(days + 1), None, None, "无付费数据"
    xs = np.array([p[0] for p in pts], dtype=float)
    ys = np.array([p[1] for p in pts], dtype=float)
    if len(pts) >= 3:
        params, sse = fit_arpu_decay(xs, ys)
        r2 = r2_from_sse(xs, ys, sse)
        t = np.arange(days + 1, dtype=float)
        curve = np.clip(arpu_decay_model(t, *params), 0.0, None)
        return curve, params, r2, "指数衰减"
    # 实测点不足（但确有付费）：末个有效 ARPU 水平外推（保守，不放大）
    last = float(ys[-1])
    return np.full(days + 1, last), None, None, "保守口径"


def _observed_cum_ltv(pooled, D):
    """实测累计 LTV 到第 D 天：Σ_{d≤D} 分日增长金额 ÷ 跑满 D 天的 cohort 总注册数。"""
    if D not in pooled or pooled[D]["reg"] <= 0:
        return None
    rev_sum = sum(pooled[d]["rev"] for d in pooled if d <= D)
    return rev_sum / pooled[D]["reg"]


def run(df_hist, pred_end, **params):
    """LTV 预测：分日留存 × 留存ARPU 递推累计 LTV。

    df_hist 为分日 cohort 长表（列见模块 docstring）；params 透传：
      days=360（LTV 展望期，2~1800）、value_scale=auto（留存率百分数/比例自动识别）。
    """
    if df_hist is None or not isinstance(df_hist, pd.DataFrame) or df_hist.empty:
        raise ValueError("历史 cohort 数据为空，无法预测 LTV")
    days = int(params.get("days", DEFAULT_DAYS) or DEFAULT_DAYS)
    days = min(max(days, MIN_DAYS), MAX_DAYS)
    value_scale = str(params.get("value_scale", "auto") or "auto").strip().lower()

    records, _ = _parse_series(df_hist)
    pooled = _pool(records)
    if not pooled:
        raise ValueError("分日 cohort 数据解析后无有效留存天数，无法预测 LTV")

    obs_days = sorted(pooled)
    max_obs = obs_days[-1]
    n_cohorts = len({r["cohort"] for r in records if r.get("cohort") is not None}) or 1

    # 留存率口径归一
    scale = value_scale if value_scale in ("percent", "ratio") else _rate_scale(
        [pooled[d]["rate"] for d in obs_days]
    )
    rate_obs = {d: _norm_rate(pooled[d]["rate"], scale) for d in obs_days}
    arpu_obs = {d: pooled[d]["arpu"] for d in obs_days}

    ret_curve, _, ret_r2, ret_model = _retention_curve(obs_days, rate_obs, days)
    arpu_curve, _, arpu_r2, arpu_model = _arpu_curve(obs_days, arpu_obs, days)

    # LTV 递推：分日 LTV 增长金额 = 留存率 × 留存ARPU，累计即 LTV
    ltv_inc = ret_curve * arpu_curve
    ltv_cum = np.cumsum(ltv_inc)

    curve_rows = []
    for d in range(days + 1):
        curve_rows.append({
            "留存天数": str(d),  # 字符串：作折线图 x 轴（数值列会被当序列，见 chart.build_chart_spec）
            "留存率(%)": round(float(ret_curve[d]) * 100.0, 2),
            "留存ARPU(USD)": round(float(arpu_curve[d]), 2),
            "分日LTV增长金额(USD)": round(float(ltv_inc[d]), 2),
            "累计LTV(USD)": round(float(ltv_cum[d]), 2),
        })
    curve_df = pd.DataFrame(curve_rows)

    mile_rows = []
    for m in MILESTONES:
        if m <= days:
            obs = _observed_cum_ltv(pooled, m)
            mile_rows.append({
                "里程碑": "%d日LTV" % m,
                "预测LTV(USD)": round(float(ltv_cum[m]), 2),
                "实测LTV(USD)": round(float(obs), 2) if obs is not None else None,
            })
    if max_obs not in MILESTONES:
        obs = _observed_cum_ltv(pooled, max_obs)
        mile_rows.append({
            "里程碑": "%d日LTV(实测窗口)" % max_obs,
            "预测LTV(USD)": round(float(ltv_cum[max_obs]), 2),
            "实测LTV(USD)": round(float(obs), 2) if obs is not None else None,
        })
    mile_df = pd.DataFrame(mile_rows)

    meta = {
        "method": "ltv_retention_arpu",
        "formula": "LTV = Σ_d 留存率_d × 留存ARPU_d（留存ARPU = 分日LTV增长金额/当日留存用户）",
        "days": days,
        "max_obs_days": max_obs,
        "n_cohorts": n_cohorts,
        "retention_model": ret_model,
        "arpu_model": arpu_model,
        "retention_r2": round(ret_r2, 3) if ret_r2 is not None else None,
        "arpu_r2": round(arpu_r2, 3) if arpu_r2 is not None else None,
        "value_scale": scale,
        "pred_end": str(pred_end),
        "engine": "numpy网格搜索+线性最小二乘（沙箱禁scipy，等价curve_fit口径）",
    }
    if ret_model == "保守口径":
        meta["fallback"] = "留存实测点不足3个，采用相邻实测点水平外推（保守口径）"
    if arpu_model == "保守口径":
        meta["arpu_fallback"] = "留存ARPU 有效实测点不足3个，采用末个有效 ARPU 水平外推"
    elif arpu_model == "无付费数据":
        meta["arpu_fallback"] = "历史无任何付费数据，留存ARPU 置 0、LTV=0"
    if max_obs < days:
        meta["extrapolation"] = "展望期 %d 天，实测仅 %d 天，%d 天之后为模型外推" % (days, max_obs, max_obs)

    return {
        "tables": [
            {"name": "LTV预测曲线", "df": curve_df, "display": True},
            {"name": "LTV关键里程碑", "df": mile_df, "display": True},
        ],
        "meta": meta,
    }
