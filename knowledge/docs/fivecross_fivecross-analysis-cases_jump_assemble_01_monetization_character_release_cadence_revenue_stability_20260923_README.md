# Jump Assemble TC — Character Release Cadence and Revenue Stability

## Business question and result

This case investigates the weekly-report observation: **“非角色投放周，營收難以支撐，可能透過調整販售的節奏來改善。”**

For September 14–20, 2026, whole-game effective purchase revenue was **USD 30,203.77**, down **62.8%** from USD 81,139.43 in September 7–13. Average daily active accounts declined 10.5%, the payer-account-day / active-account-day ratio declined 28.1%, and revenue per payer-account-day declined 42.2%.

This is evidence of weak monetization in the observed release-start gap, **not proof that increasing release frequency would increase total revenue**. There is only one complete natural week without a new event start in the bounded sample. Existing characters remained on sale. A same-content-volume staggering test and an acquisition-funnel review are preferable to declaring an optimal S-character launch interval.

## Scope

- Game and region: **Jump Assemble TC**, Global ThinkingData / Trino, `ta.v_event_23`. This is not Jump CN / China event4.
- Observation window: **2026-06-24 through 2026-09-20**, inclusive; intentionally fixed to the last complete week used by the original request.
- Coverage: 89 daily observations, 12 complete Monday–Sunday weeks, plus an incomplete launch week.
- Reference dictionary: 13 event entries from the weekly workbook's `关键事件节点` sheet.
- Revenue scope: whole-game purchase revenue; never attributed to an individual character or pool.
- No recurring report configuration, scheduler, database, or existing report was modified.

## Directory structure

```text
character_release_cadence_revenue_stability_20260923/
├── README.md
├── inputs/
│   ├── event_dictionary_snapshot.csv
│   └── raw/                         # Immutable timestamped query exports
├── sql/
│   └── 01_daily_cadence_kpi.sql
├── scripts/
│   ├── run_queries.py              # Existing data-client invocation
│   └── build_case.py               # Analysis, workbook, report, verification
└── outputs/
    ├── Jump_TC_角色投放节奏与收入稳定性_20260624-20260920.xlsx
    ├── 分析报告.md
    └── verification.json
```

## Sources and reference cases

1. `jumptw-weekly-report/reports/excel/jump_tc_kpi_2026-09-14_to_2026-09-20.xlsx`, sheet `关键事件节点`: start/end dates, character labels, grades, mechanism and IDs. Its dates are a report-level calendar, not intraday server availability.
2. Live ThinkingData query exported via `fivecross-data-client`; the exact selected raw file and SHA-256 are recorded in `outputs/verification.json`.
3. `../s_class_sanji_monetization_d1_d5_20260914/README.md`: existing evidence of weak Sanji pool entry rather than weak depth among entrants. Its participation and progression measures were not re-queried here and are not merged with this case's denominators.
4. `jumptw-weekly-report/sql/kpi/01_daily_kpi.sql`: inspected to document differences from the recurring report. Its device-based population and revenue treatment differ; this case is not a replacement for that report.

The original interrupted export remains in `inputs/raw` for provenance. The final export corrects decimal division precision and preserves both simultaneous August 26 events. The builder selects the latest timestamped export and tests these corrections.

## Metric definitions

- **Daily active accounts:** daily distinct resolved IDs from `LOGIN_SUCCESS`.
- **Resolved ID:** `COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id, #account_id)`.
- **Exclusions:** `internal_users`, `is_water`, `is_water_mod`, `suspicious_ip`, using the group membership at query time.
- **Revenue:** non-sandbox `PURCHASE` amount less matched wallet free amount, floored at zero and divided by daily currency exchange rate. Wallet records come from `ta.v_event_16`; free amount is collapsed by transaction ID using `MAX(ABS(freeamount))` before joining.
- **Paying accounts:** daily distinct resolved accounts with positive effective revenue. Purchasers are not explicitly intersected with that day's login cohort; the ratio is therefore an account-count ratio, not a strict conversion funnel.
- **Weekly active-account-days / payer-account-days:** sums of daily distinct counts, not weekly unique people.
- **Weekly average DAU:** active-account-days / observed calendar days.
- **Weighted payer ratio:** payer-account-days / active-account-days.
- **Revenue per payer-account-day:** revenue / payer-account-days, not weekly unique-payer ARPPU.
- **Revenue decomposition:** for complete weeks, revenue = 7 × average DAU × weighted payer ratio × revenue per payer-account-day. Log-change shares are an exact arithmetic decomposition, not causal effects.
- **D1–D5:** start date through start date + 4 natural days. Concurrent starts form one date-level event group; whole-game revenue is counted once per window.

## Interpretation and known limitations

- A week without a new start is not a week without characters on sale.
- New S characters, reruns, A characters, and resource-based independent activities are not equivalent interventions.
- August 5 item62 retains an unresolved character label. August 19 item57 and August 26 item67 are not treated as gacha-pull units.
- The sample contains only one complete no-start week; launch aging, traffic decline, character appeal, promotions, and update effects confound a simple start/no-start comparison.
- The weekly-report daily KPI is device-based and does not use exactly the same blacklists, active-event definition, or free-wallet deduction. Do not reconcile totals by assuming identical scope.
- Missing FX currently defaults to 1; purchase revenue is not deduplicated at order level; wallet matching is bounded to the observation window. Their financial impact has not been independently quantified. Results should not be called audited accounting net revenue.
- No causal lift, optimal release interval, long-run revenue forecast, or character-specific revenue attribution is claimed.

## Environment and dependencies

Reuse the existing client environment; do not install another database driver or create a parallel connection:

```text
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe
```

The builder needs `pandas` and `openpyxl`, already available in that environment. `run_queries.py` delegates authentication and export to the existing client. No credentials are stored in the case. The shared repositories are expected to remain siblings below `Desktop/github`.

## Reproduction

Run from the case directory:

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_queries.py
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/build_case.py
```

The first command creates a timestamped `engine: ta`, `region: global` task in the data client's `tasks/configs/adhoc` directory, executes the case SQL, and copies the exported CSV into `inputs/raw`. The second command reads the latest timestamped CSV and the fixed reference workbook, snapshots the event dictionary, and rebuilds the outputs.

For report-only reproduction, run only `build_case.py`; it does not issue a database query. The window is explicit in SQL and validation assertions: updating the analysis window requires updating both and selecting an appropriate event dictionary, not simply renaming the output.

## Output and validation

The workbook contains eight sheets: executive findings, natural-week performance, revenue decomposition, aligned D1–D5 windows, daily detail, source events, methodology/limitations, and test recommendations. Two line charts show weekly and daily whole-game revenue. Numerical results are materialized by Python, so no Excel formula recalculation is required.

The builder reopens the workbook and checks:

- uninterrupted daily date coverage and date uniqueness;
- valid positive activity denominators and nonnegative revenue;
- query ratio precision against numerator/denominator;
- the simultaneous August 26 labels;
- every source event's start date and name against query labels;
- event and daily row counts;
- eight worksheets and two charts;
- workbook daily revenue reconciliation to the source CSV;
- decomposition shares summing to one.

The execution passed these checks. `verification.json` records the selected CSV, input hashes, coverage and result summary. These checks establish reproducibility and internal consistency, not the absence of all upstream event-logging issues.

## Troubleshooting

- **Authentication/session failure:** inspect the data client's actual final state and allow its existing session recovery before requesting manual login.
- **Missing reference workbook:** restore the fixed weekly workbook or deliberately update `SOURCE` and re-audit the calendar. Never infer missing character assignments from neighboring IDs.
- **Ratio precision assertion:** use explicit `CAST(... AS DOUBLE)` in Trino rather than relying on decimal `* 1.0` division.
- **Date/event assertion:** inspect the exported SQL result and the source event dictionary; do not silently skip missing dates or relabel a concurrent launch.
- **Workbook regeneration:** outputs are overwritten by the builder, while timestamped raw exports are retained. There is no automatic scheduling or weekly-report integration.
