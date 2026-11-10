"""分日流水预测：留存递推 + 滚动平均的日粒度 DAU/流水/ARPU 预测。

收入 = 分类 DAU × 分类 ARPU。
数量：新/间隙/回流 取历史滚动平均；老账号用留存递推（源自 22_线上游戏分日流水预测）：
  老账号(明天) = 新(今天)×新留存 + 老(今天)×老留存 + 间隙(今天)×间隙留存 + 回流(今天)×回流留存。
留存来源：首个预测日用「完整日期」的留存（预测日未过完时用前一日留存），之后用上一预测行。
ARPU 预测：按同星期几历史值均值 + 平均周变化趋势；不足时回退滚动平均。
固定签名：def run(df_hist, pred_end, **params) -> {"tables": [...], "meta": {...}}
"""
from datetime import date, timedelta

import numpy as np
import pandas as pd

QTY_COLS = ["新账号数量", "老账号数量", "间隙账号数量", "回流账号数量"]
RET_COLS = ["新账号留存", "老账号留存", "间隙账号留存", "回流账号留存"]
ARPU_COLS = ["新账号ARPU", "老账号ARPU", "间隙账号ARPU", "回流账号ARPU"]
INCOME_COLS = ["新账号收入", "老账号收入", "间隙账号收入", "回流账号收入"]


def _moving_avg(series, window):
    """简单滚动平均，返回标量。"""
    return float(series.tail(window).mean())


def _predict_arpu_weekly(hist_df, col, target_date, min_samples=3, window=30):
    """按同星期几历史值预测 ARPU：均值 + 平均周变化趋势。

    Parameters
    ----------
    hist_df : pd.DataFrame
        真实历史数据，需含日期列且已按日期升序。
    col : str
        某一分类 ARPU 列名。
    target_date : pd.Timestamp
        预测日期。
    min_samples : int
        同星期几历史样本最少条数，不足则回退滚动平均。
    window : int
        回退滚动平均窗口。
    """
    # 取历史同星期几的最近7条
    vals = hist_df.loc[hist_df["日期"].dt.weekday == target_date.weekday(), col].dropna().tail(7)
    if len(vals) >= min_samples:
        avg = float(vals.mean())
        # 平均周变化趋势：首尾差值 / 间隔（间隔 = 条数 - 1）
        trend = float((vals.iloc[-1] - vals.iloc[0]) / max(len(vals) - 1, 1))
        return avg + trend
    # 回退：使用历史滚动平均
    return _moving_avg(hist_df[col], window)


def run(df_hist, pred_end, **params):
    window = int(params.get("window", 30))
    display_granularity = params.get("display_granularity", "week")
    arpu_min_samples = int(params.get("arpu_min_samples", 3))
    cur = "USD" if str(params.get("currency", "CNY")).upper() == "USD" else "CNY"
    # 未来 4 周目标表（列：日期 / 目标(CNY)），由 _run_forecast 取数后传入；缺省则不算预测达成率
    df_target = params.get("df_target")

    if df_hist is None or df_hist.empty:
        raise ValueError("历史群组数据为空，无法预测")

    missing = [c for c in QTY_COLS + RET_COLS + ARPU_COLS if c not in df_hist.columns]
    if missing:
        raise ValueError("历史群组数据缺少列：" + "、".join(missing))

    df = df_hist.copy()
    df["日期"] = pd.to_datetime(df["日期"])
    df = df.sort_values("日期").reset_index(drop=True)

    # 仅对这些列进行数值转换
    numeric_cols = QTY_COLS + RET_COLS + ARPU_COLS
    df[numeric_cols] = df[numeric_cols].apply(pd.to_numeric, errors="coerce")

    # 保留真实历史数据，用于留存递推首日取完整日留存 + ARPU 周环比预测（不使用预测值）
    hist_df = df.copy()

    # 置信区间：历史日「总收入」波动 σ，预测随展望期按 √t 放大（累计不确定性）
    _hist_rev = pd.to_numeric(hist_df["总收入"], errors="coerce").dropna()
    sigma = float(_hist_rev.std()) if len(_hist_rev) >= 2 else 0.0

    last_date = df["日期"].iloc[-1]
    pred_end = pd.Timestamp(pred_end)
    today = pd.Timestamp(date.today())

    preds = []
    step = 0
    while last_date < pred_end:
        step += 1
        d = last_date + timedelta(days=1)
        row = {"日期": d, "_step": step}

        # 数量：各分类取历史滚动平均（老账号随后用留存递推覆盖）
        for col in QTY_COLS:
            row[col] = _moving_avg(df[col], window)
        # 留存：历史滚动平均（供后续递推使用）
        for col in RET_COLS:
            row[col] = _moving_avg(df[col], window)

        # ARPU 按同星期几均值 + 趋势预测，仅基于真实历史 hist_df
        for col in ARPU_COLS:
            row[col] = _predict_arpu_weekly(
                hist_df=hist_df,
                col=col,
                target_date=d,
                min_samples=arpu_min_samples,
                window=window,
            )

        # 老账号数量：留存递推（数量取自上一行；留存首日取完整日，之后取上一预测行）
        if last_date == hist_df["日期"].iloc[-1]:
            qty_src = hist_df.iloc[-1]
            if d >= today:
                # 预测日未过完 → 用前一日留存（完整日数据）
                prev = hist_df[hist_df["日期"] == last_date - timedelta(days=1)]
                ret_src = prev.iloc[0] if len(prev) else hist_df.iloc[-1]
            else:
                ret_src = hist_df.iloc[-1]
        else:
            qty_src = df.iloc[-1]
            ret_src = df.iloc[-1]

        row["老账号数量"] = (
            qty_src["新账号数量"] * ret_src["新账号留存"]
            + qty_src["老账号数量"] * ret_src["老账号留存"]
            + qty_src["间隙账号数量"] * ret_src["间隙账号留存"]
            + qty_src["回流账号数量"] * ret_src["回流账号留存"]
        )

        # 收入 = 分类 DAU × 分类 ARPU
        row["新账号收入"] = row["新账号数量"] * row["新账号ARPU"]
        row["老账号收入"] = row["老账号数量"] * row["老账号ARPU"]
        row["间隙账号收入"] = row["间隙账号数量"] * row["间隙账号ARPU"]
        row["回流账号收入"] = row["回流账号数量"] * row["回流账号ARPU"]

        row["DAU"] = sum(row[c] for c in QTY_COLS)
        row["总收入"] = sum(row[c] for c in INCOME_COLS)

        preds.append(row)

        # 将预测行追加到 df，供后续递推使用
        df = pd.concat(
            [df, pd.DataFrame([{c: row.get(c, float("nan")) for c in df.columns}])],
            ignore_index=True,
        )
        last_date = d

    pred = pd.DataFrame(preds)
    pred["日期"] = pd.to_datetime(pred["日期"])
    pred["DAU"] = pd.to_numeric(pred["DAU"], errors="coerce")
    pred["总收入"] = pd.to_numeric(pred["总收入"], errors="coerce")

    daily = pd.DataFrame(
        {
            "日期": pred["日期"],
            "预测DAU": pred["DAU"].round(0).astype("Int64"),
            f"预测流水({cur})": pred["总收入"].round(2),
            f"预测ARPU({cur})": (pred["总收入"] / pred["DAU"].replace(0, pd.NA)).round(2),
        }
    )

    # 生成未来完整周汇总（仅保留正好7天的自然周）
    pred["_wk"] = pred["日期"].dt.to_period("W-SUN").dt.start_time
    pred["_days"] = 1
    weekly = (
        pred.groupby("_wk", as_index=False)
        .agg(
            日均预测DAU=("DAU", "mean"),
            周预测流水=("总收入", "sum"),
            _dau_sum=("DAU", "sum"),
            _days=("_days", "count"),
            _tmid=("_step", "mean"),
        )
    )
    weekly["周均预测ARPU"] = (
        weekly["周预测流水"] / weekly["_dau_sum"].replace(0, pd.NA)
    ).round(2)
    weekly = weekly[weekly["_days"] == 7].reset_index(drop=True).head(4)

    # 周置信区间：按该周平均展望天数 _tmid 计算 95% 近似区间（1.96 × σ × √_tmid）
    if sigma > 0:
        half_w = 1.96 * sigma * (weekly["_tmid"].astype(float) ** 0.5)
    else:
        half_w = 0.0
    weekly["_lo"] = (weekly["周预测流水"] - half_w).clip(lower=0).round(2)
    weekly["_hi"] = (weekly["周预测流水"] + half_w).round(2)

    # 未来 4 周目标：目标表（日期 / 目标(CNY)）按自然周聚合，对齐预测周（周一~周日），算预测达成率
    has_target = (
        cur == "CNY"
        and isinstance(df_target, pd.DataFrame) and not df_target.empty
        and "日期" in df_target.columns and "目标(CNY)" in df_target.columns
    )
    if has_target:
        tgt = df_target[["日期", "目标(CNY)"]].copy()
        tgt["日期"] = pd.to_datetime(tgt["日期"])
        tgt["_wk"] = tgt["日期"].dt.to_period("W-SUN").dt.start_time
        tgt_weekly = tgt.groupby("_wk", as_index=False)["目标(CNY)"].sum()
        weekly = weekly.merge(tgt_weekly, on="_wk", how="left")
        weekly["目标(CNY)"] = weekly["目标(CNY)"].round(2)
        weekly["预测达成率(%)"] = (
            weekly["周预测流水"] / weekly["目标(CNY)"].replace(0, pd.NA) * 100
        ).round(2)

    weekly["周"] = (
        weekly["_wk"].dt.strftime("%Y-%m-%d")
        + " ~ "
        + (weekly["_wk"] + pd.Timedelta(days=6)).dt.strftime("%Y-%m-%d")
    )
    weekly["_lo"] = weekly["_lo"].round(2)
    weekly["_hi"] = weekly["_hi"].round(2)
    cols = ["周", "日均预测DAU", "周预测流水", "_lo", "_hi", "周均预测ARPU"]
    if has_target:
        cols += ["目标(CNY)", "预测达成率(%)"]
    weekly = weekly[cols]
    weekly["日均预测DAU"] = weekly["日均预测DAU"].round(0).astype("Int64")
    weekly["周预测流水"] = weekly["周预测流水"].round(2)
    weekly = weekly.rename(
        columns={
            "周预测流水": f"周预测流水({cur})",
            "_lo": f"周预测流水下限({cur})",
            "_hi": f"周预测流水上限({cur})",
            "周均预测ARPU": f"周均预测ARPU({cur})",
        }
    )

    return {
        "tables": [
            {"name": "流水预测(未来4周)", "df": weekly, "display": display_granularity != "day"},
            {"name": "流水预测(分日)", "df": daily, "display": True},
        ],
        "meta": {
            "method": "dau_arpu_roll",
            "window": window,
            "qty_method": "retention_recursion_for_old_accounts",
            "arpu_method": "same_weekday_mean_plus_trend",
            "arpu_min_samples": arpu_min_samples,
            "income_method": "category_dau_x_category_arpu",
            "ci_method": "approx_95pct = 1.96 * hist_daily_revenue_std * sqrt(days_ahead)",
            "pred_end": str(pred_end),
        },
    }
