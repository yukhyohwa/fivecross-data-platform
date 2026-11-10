# Jump Assemble TC — S-class Card Pool Monetization

## Purpose

This analysis compares the early monetization performance of three S-class character pools in **Jump Assemble TC current 3v3 OBT**:

1. **Hisoka vs Minato** — both are returning/legacy characters with a `角色返回模块` (character return) mechanism.
2. **Byakuya vs Minato** — Byakuya was launched as a **new character** on 2026-08-26; the comparison contrasts a new release with Minato’s returning-character release.

The design follows the prior `card_pool_monetization` presentation: revenue, active base, payer conversion, target-pool participation, draw volume, character acquisition, return exposure, and early growth snapshot.

## Reporting maturity and equal-window rule

The data extraction occurred on **2026-08-28**. Byakuya D3 was not yet a complete calendar day, so the delivered workbook intentionally uses the same two **completed** days for every role:

| Role | Role class | Window | Included days |
|---|---|---:|---:|
| Hisoka | Returning | 2026-07-29 to 2026-07-30 | D1–D2 |
| Minato | Returning | 2026-08-12 to 2026-08-13 | D1–D2 |
| Byakuya | New | 2026-08-26 to 2026-08-27 | D1–D2 |

> **Important:** This is a preliminary D1–D2 read, explicitly labelled in the file name and workbook. Do not interpret it as a final D1–D5 result. Re-run the supplied SQL after 2026-08-30 closes to produce an equal, complete D1–D5 comparison.

## D1–D2 headline results

| Role | Revenue (USD) | Avg. DAU | Payer rate | ARPU (USD) | ARPPU (USD) | Target-pool participation | Target draws | Gacha-acquired users | Return-recipient events |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Hisoka | 74,200.07 | 14,017.0 | 8.60% | 2.65 | 30.78 | 11.74% | 50,468 | 533 | 387 |
| Minato | 85,012.90 | 11,211.5 | 8.23% | 3.79 | 46.08 | 25.68% | 95,629 | 873 | 591 |
| Byakuya | 72,481.07 | 9,257.0 | 12.61% | 3.91 | 31.05 | 13.90% | 60,031 | 698 | 0 (not applicable) |

### Reading the comparison

- **Minato vs Hisoka (both returning):** Minato has stronger two-day revenue, ARPU/ARPPU, target-pool participation, draw volume, gacha acquisition and return-recipient exposure, despite a smaller active base.
- **Byakuya vs Minato (new vs returning):** Byakuya has a higher payer rate and slightly higher ARPU, but lower total revenue, active base, ARPPU and target-pool participation/draws in the matched D1–D2 window.
- `Return-recipient events` counts daily character-return receipts, not unique two-day users and not causal incremental revenue. Byakuya is a new role, so the field is intentionally zero/not applicable.

## Data source and metric definitions

- **Engine / source:** ThinkingData / Trino, `ta.v_event_23`.
- **Version:** Jump Assemble TC, current 3v3 OBT.
- **Identity:** account level using `fc_sdk_common.lcx_id`, then `sdkcommon.lcx_id`, then `#account_id`.
- **Exclusions:** `internal_users`, `is_water`, `is_water_mod`, and `suspicious_ip` clusters.
- **Revenue:** `PURCHASE`, net of wallet `freeamount`; sandbox receipts excluded; daily exchange rate applied once to USD.
- **Pool mappings:** Hisoka hero `136` / gacha `103`; Minato hero `126` / gacha `104`; Byakuya hero `164` / gacha `105`. The Byakuya mapping was verified by the event discovery output.
- **Payer rate:** daily payer occurrences divided by daily DAU occurrences across the matched window (a payer-day rate, matching the comparison design).
- **Growth snapshot:** most recent `daily_role_card_snapshot` for the target character per active account/day; D2 values are used in the aggregate summary.

## Project structure

```text
s_class_byakuya_minato_monetization_20260828/
├── README.md
├── inputs/raw/                         # immutable data-client export copied into the case
├── outputs/
│   └── jump_tc_s_class_matched_d1_d2_preliminary_20260729_20260827.xlsx
├── scripts/
│   └── build_preliminary_report.py
└── sql/
    ├── 00_byakuya_event_discovery_20260826_20260828.sql
    ├── 01_matched_d1_d2_daily_kpi.sql
    └── 02_return_recipient_cohort_d1_d2.sql
```

## Runbook

1. Copy the relevant SQL into `fivecross-data-client/tasks/adhoc/`.
2. Create a task JSON in `fivecross-data-client/tasks/configs/adhoc/` with `engine: ta`, `region: global`, and the SQL file name.
3. Execute with the project virtual environment, for example:

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe main.py fetch --task <task-name>.json
```

4. Update the raw CSV source path in `scripts/build_preliminary_report.py`, then run the script using the same virtual environment.
5. Verify workbook sheet inventory and source row counts before circulation.

## Deliverable verification

The workbook was reopened with `openpyxl` after creation and verified to contain six sheets:

- Executive summary
- Matched D1-D2 summary
- Daily KPI
- Comparisons
- Methodology
- Raw source

The source extract contains six daily rows (three roles × two completed days); the summary contains three role rows; the comparison sheet contains 22 metric-delta rows.
