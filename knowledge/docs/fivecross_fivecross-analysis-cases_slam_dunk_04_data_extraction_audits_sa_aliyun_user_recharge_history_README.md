# Slam Dunk Global — South America historical recharge detail

## Request

Retrieve the Aliyun-era historical recharge detail for account `945ae573-392b-40c8-b99d-e13383dd8bbc` in Slam Dunk Global South America.

## Scope and source routing

- **Game:** Slam Dunk Global / GL (`app_id = 63002013`)
- **Region validation:** historical `daily_user_snapshot` records show zone IDs `30001` and `30002`; zone prefix `3` is South America.
- **Source:** Aliyun MaxCompute / ODPS.
- **Aliyun coverage queried:** `2020-01-01` through `2026-05-27`.
- **Order-detail table:** `dm_platform.daily_lcx_user_purchase`.
- **Account-level recharge summary check:** `dm_platform.daily_lcx_user_info` has 231 daily records through `2026-05-24`, with cumulative `purchase = 2155.8303`. This is a separate account-day summary metric and is **not used to replace or re-aggregate** the order-detail result.

`dm_platform.transaction_wallet` returned no records for the account, so the documented per-order table `daily_lcx_user_purchase` was used instead.

## Result

- **61** positive-value recharge orders
- **First order:** 2021-03-03 00:17
- **Last order:** 2023-05-27 09:38
- **Original currency:** USD
- **Original total:** USD 1,160.25
- **Converted CNY total:** CNY 8,383.76

The converted CNY amount follows the existing ODPS reference convention: a maximum available historical currency-to-CNY exchange rate per currency. Original order amount/currency remains the authoritative order-level value for reconciliation.

## Files

```text
sql/01_odps_sa_aliyun_user_recharge_history.sql
    Reusable ODPS query.
tasks/sd_gl_sa_aliyun_user_recharge_history_945ae573.json
    Data-client task used to execute the query.
outputs/raw/sd_gl_sa_aliyun_user_recharge_history_945ae573_20200101_20260527_20260907_123407.csv
    Unmodified query export.
outputs/report/灌篮全球服_南美_用户历史充值明细_阿里云时期_20200101_20260527.xlsx
    Deliverable workbook: Summary, Currency Summary, Recharge Details.
scripts/build_report.py
    CSV-to-Excel transformation and validations.
```

## Re-run

Run the task from `fivecross-data-client` using its own virtual environment:

```bash
PYTHONUTF8=1 C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe main.py fetch --task C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/slam_dunk/04_data_extraction_audits/sa_aliyun_user_recharge_history/tasks/sd_gl_sa_aliyun_user_recharge_history_945ae573.json
```

Update `SOURCE_CSV` in `scripts/build_report.py` to the newly exported CSV path, then run the script with the same client virtual environment.
