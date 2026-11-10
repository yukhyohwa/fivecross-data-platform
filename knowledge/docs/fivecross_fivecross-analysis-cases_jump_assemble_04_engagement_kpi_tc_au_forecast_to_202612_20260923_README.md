# JUMP TC daily active-user forecasting methodology

Reusable-model execution is configured in [forecast/case.json](forecast/case.json); see [forecast/README.md](forecast/README.md) for the common engine commands. Game-specific SQL and metric definitions remain in this case.

This case implements an acquisition–retention cohort-convolution model for JUMP Assemble TC, with an empirical calendar-time decay correction. This README documents the method, assumptions, implementation and reproduction workflow; it is not a business-results report.

**Status:** retrospective scenario modelling. Parameter selection and reported historical errors use overlapping observations. The model has not passed independent long-horizon validation.

## 1. Scope and metric definitions

| Item | Definition |
|---|---|
| Product | JUMP Assemble TC |
| Source | ThinkingData / Trino: `ta.v_event_23`, `user_result_cluster_23` |
| Calendar | Asia/Shanghai natural days |
| Observed interval in this snapshot | 2026-06-24 through 2026-09-22 |
| Forecast interval in this snapshot | 2026-09-23 through 2026-12-31 |
| Identity | `fixed_deviceid`; missing values fall back to `unknown_<account_id>` |
| Daily AU / DAU | Distinct eligible devices with `NUU`, `LOGIN_SUCCESS` or `PURCHASE` on that day |
| NUU | Distinct eligible new devices based on `fixed_regdate` |
| Exact-day retention activity | `NUU` or `LOGIN_SUCCESS` on registration date plus the specified natural-day age |
| Exclusions | `internal_users`, `is_water` |

AU in this project means **daily** active users and is labelled DAU in the simplified workbook. Counts use the device identity above rather than a guaranteed person-level identity. Retention and DAU have different activity-event sets; their discrepancy is not separately modelled.

## 2. Mathematical model

Let:

- `T` be the last observed day;
- `t = T + h` be a forecast day, with `h >= 1`;
- `N(c)` be actual NUU for observed registration dates and predicted NUU for future dates;
- `R(a)` be the estimated exact-day retention rate at lifecycle age `a`;
- `k` be the boundary calibration factor;
- `g(h)` be the additional calendar-time contribution factor.

The revised model is:

```text
DAU_hat(t) = N_hat(t) + k × g(h) × sum[N(c) × R(t-c), c < t]

g(h) = f + (1-f) × exp(-lambda × h)

k = [DAU(T) - N(T)] / sum[N(c) × R(T-c), c < T]
```

The first term is same-day acquisition. The sum represents activity contributed by all earlier registration cohorts. Exact-day retention permits intermittent activity and return; it is not a continuous-survival probability.

`k` aligns the model with observed DAU at the boundary. Boundary agreement is not evidence that the subsequent slope is correct. `g(0)=1`; the correction approaches `f` over time, at a speed controlled by `lambda`.

**Implementation detail:** `g(h)` multiplies every D1+ contribution, including contributions from cohorts acquired after `T`. It does not apply only to users already acquired at the forecast origin. The same-day acquisition term is not multiplied by `k` or `g(h)`.

The original comparator sets `g(h)=1` and assumes constant future NUU at the latest seven-day mean. It remains reproducible through `build_forecast.py`; the current revision is produced by `build_revision.py`.

## 3. Estimating lifecycle retention

### 3.1 Mature-cohort selection

For each age `a`, select the latest 28 registration-day cohorts that have reached age `a` by the observation cutoff. If fewer exist, use the available mature cohorts only. Immature cohorts are excluded, not treated as zero retention.

```text
R_raw(a) = sum(retained devices at exact age a)
           / sum(registered devices in eligible cohorts)
```

This is a ratio of summed counts, not an unweighted average of cohort percentages. Different ages can use different cohort sets, so the result is a synthetic age curve rather than one cohort's complete history.

### 3.2 Smoothing

Apply weighted non-increasing isotonic regression using cohort-device counts as weights. The implementation uses the pool-adjacent-violators algorithm in `build_forecast.decreasing_pava`. D0 is set to 1.

The monotonic constraint suppresses observed age-related increases caused by sampling, calendar effects or cohort composition. It is a modelling assumption; exact-day retention in real data need not be monotonic.

### 3.3 Unobserved retention tail

For the current snapshot, D0–D90 are observed. Fit a log-log line to the adjusted D30–D90 rates using NumPy polynomial fitting with weights equal to the square root of the mature-cohort count. Cap the fitted slope at `-0.02` or lower:

```text
beta = min(-0.02, fitted log-log slope)
R(a) = R(90) × (a/90)^beta, for a > 90
```

Historical-origin curves use their own maximum observed age `A`, fit from `max(30, A-60)` through `A`, and extrapolate from `R(A)`. They do not reuse later retention observations.

Long-age estimates have fewer mature cohorts. A single mature registration day at the longest horizon must not be interpreted as a stable population retention rate.

## 4. Forecasting daily NUU

### 4.1 Starting level

Let `B` be mean actual NUU over the last seven complete days through `T`.

### 4.2 Recent trend

Split the last 21 days into three consecutive seven-day blocks, ordered oldest to newest. Let their means be `W0`, `W1`, `W2`. Fit:

```text
log(Wj) = intercept + s_raw × j
s = d × clip(s_raw, log(0.80), 0)
```

`d` attenuates the fitted log trend. Candidates are `0, 0.25, 0.5, 0.75, 1`.

- `d=0` means no trend decline.
- `d=1` retains the full clipped decline.
- Positive fitted growth is capped at zero.
- Before attenuation, the decline is capped at 20% per week.

This intentionally restricts projections to flat or declining baseline acquisition. It does not freely extrapolate an observed growth trend.

### 4.3 Weekday factors

Use the last 28 actual days. Divide each day's NUU by the mean of its containing seven-day block. Average these normalized ratios by weekday, then normalize the seven weekday factors to have an unweighted mean of 1.

Call the resulting factor `w(weekday)`. This removes block-level shifts before estimating the weekday pattern, but it does not model holidays or future changes in that pattern.

### 4.4 Projection and floor

```text
N_hat(T+h) = B × max(q, exp(s × h/7)) × w(weekday(T+h))
```

The revised deliverable fixes `q=0.5`. This is a scenario assumption, not an empirically established acquisition floor. It applies before weekday adjustment; individual daily values can be below `0.5 × B`.

### 4.5 Worked example from the observed snapshot

Actual NUU from September 16–22 is `292, 232, 376, 611, 514, 331, 277`, giving `B=376.142857`.

The three preceding seven-day means are `444.428571`, `392.857143` and `376.142857`. Their fitted log slope is approximately `-0.08341017`. For the illustrative candidate `d=0.25`, the effective slope is `-0.02085254`.

For September 23 (`h=1`), the trend-adjusted level is approximately `375.024019`. The Wednesday factor is `0.84009869`, yielding predicted NUU of approximately `315.057187`.

This illustrates one candidate, not the ensemble median. The observed counts and estimated weekday pattern come from data; trend attenuation and the floor remain assumptions. The current revision does not apply an extra ±25% acquisition multiplier.

## 5. Calendar-time decay correction

The correction `g(h)=f+(1-f)exp(-lambda h)` addresses persistent deterioration in observed activity relative to a fixed cohort-retention convolution.

The grid explores:

| Parameter | Candidates | Role |
|---|---|---|
| `damp` (`d`) | 0, 0.25, 0.5, 0.75, 1 | Attenuates acquisition decline |
| `floor_ratio` (`q`) | 0.25, 0.5, 0.75 in exploration; 0.5 in the revision | Minimum acquisition baseline ratio |
| `calendar_decay` (`lambda`) | 0.01, 0.015, 0.02, 0.025, 0.03, 0.04 | Decay speed per forecast day |
| `scale_floor` (`f`) | 0.3, 0.4, 0.5, 0.6 | Asymptotic retained-contribution factor |

**Main structural risk:** lifecycle retention already includes attrition. Multiplying it by another decline can double-count deterioration. Short-term residual patterns motivate testing this correction but do not prove that it should persist for months, or identify the eventual floor. It is an empirical adjustment, not a causal mechanism.

## 6. Historical evaluation and parameter selection

### 6.1 Origin-specific inputs

The snapshot uses origins August 31, September 7 and September 14, predicting each subsequent day through September 22. Each origin uses only earlier AU/NUU and retention mature at that origin. `03_backtest_retention_curves.sql` extracts the origin-specific curves.

Device mappings and exclusion labels still come from current profile snapshots. Historical changes to these labels cannot be reconstructed by this query.

### 6.2 Metrics

For prediction `p_i`, observed value `y_i` and `n` origin-day observations:

```text
Signed error_i = p_i - y_i
Relative error_i = p_i/y_i - 1
MAE = sum(abs(p_i-y_i)) / n
MAPE = sum(abs(p_i/y_i-1)) / n
WAPE = sum(abs(p_i-y_i)) / sum(y_i)
Mean relative bias = sum(p_i/y_i-1) / n
```

Positive signed or relative error means overprediction. Pooled screening gives each origin-day row equal weight; overlapping calendar days consequently appear more than once, and longer windows contribute more rows.

### 6.3 Screening rule

The revision keeps combinations with:

- pooled MAPE at most 4.2%;
- absolute pooled mean relative bias at most 2.5%;
- acquisition floor ratio fixed to 0.5.

Duplicate `(damp, calendar_decay, scale_floor)` combinations are removed. The snapshot retains 28 combinations. Each retained combination has equal ensemble weight; acquisition trends are not equally weighted if different numbers of retained combinations share them.

The grid, thresholds and errors are retrospective. The same windows participate in selection and assessment, and the three windows overlap. These scores are calibration diagnostics, not independent out-of-sample performance. The maximum evaluation horizon is 22 days, compared with a 100-day final forecast horizon.

## 7. Parameter-only forecast summaries (v3)

For every retained parameter combination, generate a *paired* daily NUU and DAU path. The current revision does **not** apply the old additional future-NUU ×75% / ×125% multipliers. For each date, take the median and P10/P90 of the 28 candidate paths **separately for DAU and NUU**. These are parameter sensitivity summaries, **not confidence bounds**. Pointwise medians or quantiles need not belong to the same fixed parameter path, so the displayed DAU and NUU medians are adjacent business metrics, not one candidate's exact decomposition.

The original v2 downside/upside multiplied future acquisition by ±25% on top of the parameter spread; those output files have been retired. The DAU reference center is unchanged by removal of that extra multiplier. The fixed-future-NUU, no-additional-decay model remains available as an explicitly labelled historical comparator.

The current `outputs/jump_tc_au_forecast_v3_20260923.xlsx` opens with the **`每日DAU与NUU`** sheet: date, DAU center, same-day NUU median, each metric's parameter P10/P90, and old-model DAU comparator. It then provides month-end checkpoints, historical error and source-audit sheets. The separate simplified daily workbook and its export script were removed as redundant.

## 8. Repository structure and responsibilities

```text
sql/
  01_daily_au_nuu.sql                 Actual daily device AU and NUU
  02_mature_retention_curve.sql       Current mature curves and vintage anchors
  03_backtest_retention_curves.sql    Origin-specific mature retention
scripts/
  run_queries.py                     Run existing data client; copy verified exports
  build_forecast.py                  Retention helpers and original comparator
  evaluate_model.py                  Historical parameter-grid evaluation
  build_revision.py                  Revised ensemble, audit workbook and chart
  build_presentation.py              Verified six-slide business presentation
tasks/                               Generated data-client task configurations
outputs/raw/                         Source CSV snapshots
outputs/                             Generated forecasts, diagnostics and deliverables
```

No weekly-report pipeline is modified by this case.

## 9. Environment and reproduction

Use the existing `fivecross-data-client` virtual environment and its configured ThinkingData access. Do not embed credentials in this case. Modelling requires Python with NumPy, pandas, matplotlib, openpyxl and python-pptx; package installation and client authentication remain responsibilities of the shared client environment.

From PowerShell:

```powershell
Set-Location C:\Users\5xgames\Desktop\github\fivecross-analysis-cases\jump_assemble\04_engagement_kpi\tc_au_forecast_to_202612_20260923
$python = "C:\Users\5xgames\Desktop\github\fivecross-data-client\venv\Scripts\python.exe"

# Refresh source inputs only when intentionally rerunning the queries.
& $python .\scripts\run_queries.py

# Historical grid, current forecast and presentation.
& $python .\scripts\evaluate_model.py
& $python .\scripts\build_revision.py
& $python .\scripts\build_presentation.py
```

To reproduce modelling from the existing source snapshots, skip `run_queries.py`. That runner creates task JSON files, invokes the shared data client, checks newly generated non-empty exports and copies them into `outputs/raw/`. No scheduler or automatic refresh is installed.

## 10. Date configuration and reuse

The implementation is a fixed-date case, not yet a single-config general-purpose forecasting tool. Changing one date is insufficient.

| Location | Settings requiring coordination |
|---|---|
| `01_daily_au_nuu.sql` | `start_date`, `observation_end` |
| `02_mature_retention_curve.sql` | `cohort_start`, `observation_end`, mature-cohort window |
| `03_backtest_retention_curves.sql` | Historical origins and source-scan limits |
| `build_forecast.py` | `FORECAST_END`, observed-date checks, chart boundaries, labels and checkpoints |
| `evaluate_model.py` | Historical origins and output labels |
| `build_revision.py` | Observed cutoff assertion, forecast date range, checkpoints, chart labels and row-count checks |
| `build_presentation.py` | Chart annotations, reporting period and slide narrative |
| Output paths and README | Snapshot identifiers and metadata |

Preserve historical acquisition from launch when updating the observation cutoff; moving the history start forward discards older cohort contributions. Extend the retention-curve age coverage as necessary: revision and evaluation helpers currently generate through age 240, which may be insufficient for a longer forecast.

A later generalization should centralize the observed cutoff, forecast end, origins and historical start, and derive forecast start, row counts and labels from those values. This generalization is not implemented here.

## 11. Output map

| Artifact | Purpose |
|---|---|
| `jump_tc_au_forecast_v3_20260923.csv` | Daily DAU and NUU center/parameter sensitivities, old DAU baseline |
| `jump_tc_au_forecast_v3_20260923.xlsx` | Daily-first workbook, retrospective diagnostics, parameters, source evidence and limitations |
| `jump_tc_au_forecast_v3_20260923.png` | Actual solid line, forecast dashed lines, full-period and recent-period views |
| `jump_tc_au_forecast_v3_20260923_backtest.csv` | Origin-day comparisons of original and revised forecasts |
| `model_backtest_grid_20260923.csv` | Exploratory parameter-grid scores |
| `JUMP_TC_DAU预估报告_20260923.pptx` | Six-slide operational report from the v3 exports |

All artifacts above are under `outputs/`. The original comparator **script** is retained for audit and shared retention helpers, but obsolete generated workbooks, CSVs and charts have been removed. Raw SQL extracts are retained.

## 12. Validation, troubleshooting and limitations

### Checks implemented

- Continuous observed dates ending on the declared cutoff.
- Continuous retention ages through the observed horizon.
- Finite values and ordered parameter P10/center/P90 for both DAU and NUU.
- Exactly the expected forecast dates and rows.
- Workbook sheet inventory and numeric read-back comparisons.
- Final-date center value reconciliation.
- Current workbook starts with daily DAU and NUU, and reads back final-date values.
- Generated PPT opens with six slides; text and embedded chart images are verified structurally. Rendering to slide images was unavailable in the original runtime, so visual PowerPoint review remains recommended.
- Chart inspection for readable labels, solid actuals, dashed forecasts and the requested end boundary.

### Common failures

- **Observed-date assertion fails:** inspect the input CSV and coordinated date settings; do not remove the check to conceal a mismatch.
- **Missing backtest CSV or origin:** run the origin-retention query and align the SQL origins with `evaluate_model.py`.
- **Missing age in a curve:** verify cohort maturity and query coverage; do not replace missing mature evidence with zero.
- **Age lookup fails after extending dates:** expand curve generation beyond the oldest cohort age at the new forecast end.
- **Workbook permission error:** close the output in Excel before regeneration.
- **Client authentication failure:** use and verify the shared client's existing session-recovery path; inspect the final export rather than assuming login messages imply success.

### Interpretation limits

- Acquisition floors, attenuation and calendar decay are assumptions with weak long-horizon identification.
- NUU parameters are screened jointly through DAU errors, not independently validated as acquisition forecasts.
- Retention is synthetic across registration vintages and its tail is extrapolated.
- Current identity/exclusion snapshots prevent fully historical reconstruction of labels.
- Weekday patterns are held fixed; holidays, planned acquisition, product updates and reactivation campaigns are not explicitly modelled.
- Additional decay can duplicate attrition already represented in retention.
- Overlapping, reused calibration windows understate uncertainty if treated as independent validation.
- Model-grid quantiles are sensitivity summaries, not calibrated probability bounds.

A stronger validation design would reserve untouched future windows, assess acquisition separately, compare simpler no-extra-decay baselines and report horizon-specific errors before using long-run centers for planning.
