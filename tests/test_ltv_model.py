"""LTV 预测模型（code/ltv.py）单元测试。

口径：分日留存 × 留存ARPU 递推累计 LTV（code/ltv.sql 取数，买量投放KPI 改写）。
覆盖：
- 沙箱预检通过 + 能力注册为 input=sql；
- 单 cohort 拟合：day0 留存 100%、ARPU 正确、累计 LTV 单调收敛、里程碑实测 LTV 精确；
- 多 cohort 加权池化（非简单平均）；
- 无付费数据 → LTV=0 并注明；
- 实测点不足 → 保守口径回退；
- 百分数留存率自动归一；
- 空数据报错。
"""
import numpy as np
import pandas as pd
import pytest

from analysis import code_store
from backend.services import forecast


def _load_ltv_func():
    func = forecast.load_func_from_code("ltv", code_store.read_code("ltv"))
    assert func is not None, "ltv 模型应能通过预检并加载 run 函数"
    return func


def _cohort_df(rows):
    """构造分日 cohort 长表（列名与 code/ltv.sql 输出一致，含 (USD) 后缀以验证子串匹配）。"""
    return pd.DataFrame(rows)


def _single_cohort(reg=1000, arpu=2.0, days=30, retain=lambda d: 0.6 ** d):
    """单 cohort：留存率 retain(d)，留存ARPU 恒为 arpu，d=0 留存=1。"""
    rows = []
    for d in range(days + 1):
        retained = float(reg) if d == 0 else reg * retain(d)
        rev = retained * arpu
        rows.append({
            "注册日期": "2026-01-01",
            "留存天数": d,
            "注册人数": reg,
            "留存人数": retained,
            "留存率": retained / reg,
            "分日LTV增长金额(USD)": rev,
            "留存ARPU(USD)": arpu,
        })
    return _cohort_df(rows)


def test_ltv_precheck_passes():
    from analysis.model_gen import precheck_code

    assert not precheck_code(code_store.read_code("ltv"))


def test_ltv_registered_as_sql_capability():
    cap = forecast.PREDICTION_CAPABILITIES.get("ltv")
    assert cap is not None
    assert cap.get("input") == "sql"
    assert cap.get("sql")
    assert callable(cap.get("func"))


def test_ltv_single_cohort_basic():
    func = _load_ltv_func()
    df = _single_cohort()
    result = func(df, pd.Timestamp("2026-01-01"), days=360)

    tables = {t["name"]: t["df"] for t in result["tables"]}
    assert set(tables) == {"LTV预测曲线", "LTV关键里程碑"}

    curve = tables["LTV预测曲线"]
    assert list(curve.columns) == ["留存天数", "留存率(%)", "留存ARPU(USD)", "分日LTV增长金额(USD)", "累计LTV(USD)"]
    assert len(curve) == 361

    # day0：留存率 100%，留存ARPU = 当日付费/注册
    assert curve.loc[0, "留存率(%)"] == 100.0
    assert abs(curve.loc[0, "留存ARPU(USD)"] - 2.0) < 0.01

    # 累计 LTV 单调不减、有限、为正向且长期收敛（0.6^d 衰减快，30 天后几乎不再增长）
    cum = curve["累计LTV(USD)"].to_numpy(dtype=float)
    assert np.all(np.diff(cum) >= -1e-9)
    assert np.all(np.isfinite(cum))
    assert cum[30] > cum[0] > 0
    assert cum[-1] >= cum[30]

    # 里程碑：0日实测 = 2.0，30日实测 = 2 × Σ0.6^d ≈ 5.0（实测口径用原始付费/注册，不受拟合影响）
    mile = {r["里程碑"]: r for r in tables["LTV关键里程碑"].to_dict("records")}
    assert abs(mile["0日LTV"]["实测LTV(USD)"] - 2.0) < 0.01
    expected_30 = 2.0 * (1 - 0.6 ** 31) / (1 - 0.6)
    assert abs(mile["30日LTV"]["实测LTV(USD)"] - expected_30) < 0.05

    meta = result["meta"]
    assert meta["method"] == "ltv_retention_arpu"
    assert meta["retention_model"] == "exp2"
    assert meta["arpu_model"] == "指数衰减"
    assert meta["max_obs_days"] == 30
    assert meta["retention_r2"] is not None
    assert meta["arpu_r2"] is not None


def test_ltv_multi_cohort_weighted_pooling():
    func = _load_ltv_func()
    rows = []
    # cohort A: reg=1000, day1留存500, 付费 1000/500；cohort B: reg=500, day1留存100, 付费 500/100
    for date, reg, d1ret, rev0, rev1 in [
        ("2026-01-01", 1000, 500, 1000, 500),
        ("2026-01-02", 500, 100, 500, 100),
    ]:
        rows.append({"注册日期": date, "留存天数": 0, "注册人数": reg, "留存人数": reg,
                     "留存率": 1.0, "分日LTV增长金额(USD)": rev0, "留存ARPU(USD)": rev0 / reg})
        rows.append({"注册日期": date, "留存天数": 1, "注册人数": reg, "留存人数": d1ret,
                     "留存率": d1ret / reg, "分日LTV增长金额(USD)": rev1, "留存ARPU(USD)": rev1 / d1ret})
    result = func(_cohort_df(rows), pd.Timestamp("2026-01-03"), days=90)
    mile = {r["里程碑"]: r for r in result["tables"][1]["df"].to_dict("records")}
    # 加权池化：1日实测 LTV = Σ付费(0..1)/Σ注册 = (1500+600)/1500 = 1.4（简单平均会算错）
    assert abs(mile["1日LTV"]["实测LTV(USD)"] - 1.4) < 0.01


def test_ltv_no_revenue_zero():
    func = _load_ltv_func()
    df = _single_cohort(arpu=0.0)
    result = func(df, pd.Timestamp("2026-01-01"), days=30)
    meta = result["meta"]
    assert meta["arpu_model"] == "无付费数据"
    assert meta.get("arpu_fallback")
    curve = result["tables"][0]["df"]
    assert (curve["累计LTV(USD)"] == 0).all()


def test_ltv_few_points_fallback():
    func = _load_ltv_func()
    # 只有 2 个实测天 → 留存/ARPU 均走保守口径（不硬报错）
    df = _single_cohort(days=1, arpu=2.0)
    result = func(df, pd.Timestamp("2026-01-01"), days=30)
    meta = result["meta"]
    assert meta["retention_model"] == "保守口径"
    assert meta["arpu_model"] == "保守口径"
    assert meta.get("fallback")
    assert meta.get("arpu_fallback")
    curve = result["tables"][0]["df"]
    # 保守口径：day0 留存 100%，此后水平外推为 day1 的留存率
    assert curve.loc[0, "留存率(%)"] == 100.0
    assert curve.loc[1, "留存率(%)"] == curve.loc[2, "留存率(%)"] == curve.loc[30, "留存率(%)"]


def test_ltv_percent_retention_normalized():
    func = _load_ltv_func()
    # 离线上传口径：只给「留存率(百分数) + 留存ARPU」、无计数列 → 走均值池化并自动识别百分数
    rows = []
    for d in range(10):
        rows.append({
            "留存天数": d,
            "留存率": 60.0 * (0.6 ** d),  # 百分数：60、36、21.6 …
            "留存ARPU": 2.0,
        })
    result = func(_cohort_df(rows), pd.Timestamp("2026-01-01"), days=30)
    assert result["meta"]["value_scale"] == "percent"
    curve = result["tables"][0]["df"]
    assert curve.loc[0, "留存率(%)"] == 100.0  # 第 0 天强制 100%（注册日全员在档）
    assert 0 < curve.loc[9, "留存率(%)"] < 100


def test_ltv_empty_raises():
    func = _load_ltv_func()
    with pytest.raises(ValueError):
        func(pd.DataFrame(), pd.Timestamp("2026-01-01"), days=30)
    with pytest.raises(ValueError):
        func(_cohort_df([]), pd.Timestamp("2026-01-01"), days=30)
    # 缺「留存天数」列
    with pytest.raises(ValueError):
        func(pd.DataFrame({"a": [1, 2]}), pd.Timestamp("2026-01-01"), days=30)
