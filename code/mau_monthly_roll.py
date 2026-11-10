"""分月流水预测：NUU/RUU 对数线性拟合 + OUU 留存递推的月粒度 MAU/流水/ARPU 预测。

源自内置能力 mau_monthly_roll（12_线上游戏分月流水预测），已外部化为可修改模型。
固定签名：def run(df_hist, pred_end, **params) -> {"tables": [...], "meta": {...}}
"""
import numpy as np
import pandas as pd

MONTHLY_QTY = ["NUU", "OUU", "RUU"]
MONTHLY_RATE = ["NUU次月留存率", "OUU次月留存率", "RUU次月留存率"]
MONTHLY_ARPU = ["NUU_ARPU", "OUU_ARPU", "RUU_ARPU"]

# 对数线性外推的月增速天花板：月环比最多翻倍（log 2）。
# 新游起步期 RUU/回流 等序列呈「结构爬坡」，若不封顶会被指数外推成天文数字（如 1234 → 40 万）。
_MAX_LOG_SLOPE = float(np.log(2.0))


def _linfit_monthly(train, col, n_months):
    y_tr = train[col]
    mask = y_tr.notna() & (y_tr >= 0)
    n = int(mask.sum())
    t_pred = np.arange(1, n_months + 1, dtype=float)
    if n >= 2:
        t_fit = np.arange(n, dtype=float)
        y_log = np.log(y_tr[mask].values + 1.0)
        try:
            a, b = np.polyfit(t_fit, y_log, 1)
            # 月增速封顶（防指数爆炸），并以最近一期实际值重新锚定截距，使预测从近期水平出发
            a = float(np.clip(a, -_MAX_LOG_SLOPE, _MAX_LOG_SLOPE))
            b = float(y_log[-1] - a * t_fit[-1])
            y_pred = np.exp(a * (t_fit[-1] + t_pred) + b) - 1.0
        except Exception:
            y_pred = np.full(n_months, float(y_tr[mask].mean() or 0.0))
    else:
        y_pred = np.full(n_months, float(y_tr[mask].mean() if n else 0.0))

    if n:
        tail = y_tr[mask].tail(min(3, n)).values
        floor_tail = 0.7 * float(np.min(tail))
        floor_pct10 = float(np.percentile(y_tr[mask].values, 10))
        y_floor = max(0.0, floor_tail, floor_pct10)
        y_raw = y_pred.copy()
        below = np.where(y_raw < y_floor)[0]
        if below.size:
            i0 = int(below[0])
            y_pred[i0] = max(float(y_raw[i0]), y_floor)
            for k in range(i0 + 1, y_pred.shape[0]):
                y_pred[k] = max(float(y_pred[k - 1]) * 0.95, 0.0)
        else:
            y_pred = np.maximum(y_raw, y_floor)
    return np.maximum(y_pred, 0.0)


def run(df_hist, pred_end, **params):
    window = int(params.get("window", 6))
    cur = "USD" if str(params.get("currency", "CNY")).upper() == "USD" else "CNY"

    missing = [c for c in ["月份"] + MONTHLY_QTY + MONTHLY_RATE + MONTHLY_ARPU if c not in df_hist.columns]
    if missing:
        raise ValueError("月度群组数据缺少列：" + "、".join(missing))

    df = df_hist.copy()
    df["月份"] = pd.to_datetime(df["月份"])
    for c in MONTHLY_QTY + MONTHLY_RATE + MONTHLY_ARPU:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.sort_values("月份").reset_index(drop=True)

    last_hist = df["月份"].max()
    pred_end = pd.Timestamp(pred_end)
    months = pd.date_range(last_hist + pd.DateOffset(months=1), pred_end, freq="MS")
    if len(months) == 0:
        raise ValueError("预测截止月份不晚于历史末月，无未来月份可预测")

    train = df.tail(window)
    if len(train) < 2:
        train = df

    rate_mean = {c: float(train[c].mean()) for c in MONTHLY_RATE}
    arpu_mean = {c: float(train[c].mean()) for c in MONTHLY_ARPU}

    nuu_pred = _linfit_monthly(train, "NUU", len(months))
    ruu_pred = _linfit_monthly(train, "RUU", len(months))

    rows = []
    prev_nuu, prev_ouu, prev_ruu = (
        float(df["NUU"].iloc[-1]),
        float(df["OUU"].iloc[-1]),
        float(df["RUU"].iloc[-1]),
    )
    for i, m in enumerate(months):
        nuu = float(nuu_pred[i])
        ruu = float(ruu_pred[i])
        ouu = (
            prev_nuu * rate_mean["NUU次月留存率"]
            + prev_ouu * rate_mean["OUU次月留存率"]
            + prev_ruu * rate_mean["RUU次月留存率"]
        )
        ouu = max(ouu, 0.0)
        rows.append({"月份": m, "预测NUU": nuu, "预测OUU": ouu, "预测RUU": ruu})
        prev_nuu, prev_ouu, prev_ruu = nuu, ouu, ruu

    detail = pd.DataFrame(rows)
    for c in ["预测NUU", "预测OUU", "预测RUU"]:
        detail[c] = detail[c].round(0).astype("Int64")
    detail["预测MAU"] = (detail["预测NUU"] + detail["预测OUU"] + detail["预测RUU"]).astype("Int64")
    detail[f"预测流水({cur})"] = (
        detail["预测NUU"] * arpu_mean["NUU_ARPU"]
        + detail["预测OUU"] * arpu_mean["OUU_ARPU"]
        + detail["预测RUU"] * arpu_mean["RUU_ARPU"]
    ).round(2)
    detail[f"预测ARPU({cur})"] = (detail[f"预测流水({cur})"] / detail["预测MAU"].replace(0, pd.NA)).round(2)

    summary = detail[["月份", "预测MAU", f"预测流水({cur})", f"预测ARPU({cur})"]].copy()
    summary["月份"] = summary["月份"].dt.strftime("%Y-%m")

    return {
        "tables": [
            {"name": "流水预测(分月)", "df": summary, "display": True},
            {"name": "流水预测(分月明细)", "df": detail, "display": False},
        ],
        "meta": {"method": "mau_monthly_roll", "window": window, "pred_end": str(pred_end)},
    }
