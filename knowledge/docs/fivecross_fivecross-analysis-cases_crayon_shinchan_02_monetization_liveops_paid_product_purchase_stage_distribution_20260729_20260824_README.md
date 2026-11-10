# Paid Product Purchase Stage Distribution — Crayon Shin-chan TC CBT

## Purpose

Report the main-stage distribution at the time a player purchased each paid product during the Traditional Chinese CBT. The output explicitly excludes products bought with Crystal Gems (`10206`) by using valid `charge` events only; no `shop_buy` records are included.

## Scope

- Version/source: Crayon Shin-chan Traditional Chinese, ThinkingData App 18 (`ta.v_event_18`).
- Window: 2026-07-29 through 2026-08-24.
- Order eligibility: `charge`, non-null `#account_id` and product ID; sandbox is null/false; free-buy is null/false.
- Exclusions: `internal_users` and `is_windows`, matching the supplied reference SQL.
- Player grain: `#account_id`.

## Attribution method

For every eligible paid order, the query retrieves the account's most recent `stage_fight` at or before the charge timestamp. Only main-stage events are accepted (`a_rst[1].key = 1001`). Stage IDs are mapped through `ta_dim.dim_18_0_52765` to their real stage names.

The result is aggregated as:

```text
product category × product ID × product name × main stage at purchase
```

`购买人数` is distinct accounts inside each output row. It is not additive across stages or products, because an account can buy the same or different products at multiple stage points.

Accounts with no recorded main-stage event before payment are retained under `未匹配到主线关卡`.

## Files

- `sql/01_paid_product_purchase_stage_distribution.sql` — executable Trino SQL.
- `output/paid_product_purchase_stage_distribution_20260729_20260824.xlsx` — verified Excel export.
- `output/paid_product_purchase_stage_distribution_20260729_20260824.csv` — matching CSV export.

## Execution

The SQL was copied to `fivecross-data-client/tasks/adhoc/` and executed with the project virtual environment:

```bash
./.venv/Scripts/python.exe main.py fetch --task crayon_tc_paid_product_purchase_stage_distribution_20260729_20260824.json
```

## Verified output

- Rows: 330 product-stage combinations.
- Products: 60 product IDs.
- Categories: 16.
- Columns: product category, product ID, product name, main stage at purchase, distinct purchasers.
