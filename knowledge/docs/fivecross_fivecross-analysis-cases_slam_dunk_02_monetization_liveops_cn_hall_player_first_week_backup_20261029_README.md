# Slam Dunk CN Hall Player First-Week Backup

## Purpose

This case preserves an auditable first-week activity snapshot from the Alibaba Cloud MaxCompute/ODPS source before the legacy source is retired. It covers the four Hall-player campaigns that could be validated directly from the CN game-log data on 2026-10-29:

- Hall Sakuragi Hanamichi — 2026-04-22 to 2026-04-28
- Hall Rukawa Kaede — 2026-06-03 to 2026-06-09
- Hall Miyagi Ryota — 2026-08-12 to 2026-08-18
- Hall Mitsui Hisashi — 2026-09-23 to 2026-09-29

The first-week start is the first observed positive change of the campaign's primary token. Each window is seven inclusive natural days.

## Deliverables

| File | Content |
|---|---|
| `results/灌篮简体_殿堂球员首周活动备份_20261029.xlsx` | Consolidated business-facing workbook. |
| `results/01_first_week_all_sku_revenue_20261029_153758.*` | Actual first-week purchase records aggregated by SKU and campaign window. |
| `results/02_first_week_stamp_shop_spend_20261029_153810.*` | Actual `coin_typ='stamps'` shop-spend records aggregated by item and campaign window. |
| `results/03_first_week_token_flow_20261029_153540.*` | Actual obtain/consume flows of campaign-specific wheel/material items by action type. |
| `config/campaign_manifest.csv` | Validated campaign windows and item mappings. |
| `sql/` | Rerunnable ODPS extraction SQL. |
| `scripts/build_backup_workbook.py` | Rebuilds the consolidated workbook from the three CSV exports. |

## Metric definitions

### First-week all-SKU revenue

- **Source:** `dm_platform.daily_lcx_user_purchase`, `app_id=13002010`.
- **Window:** campaign start through start + 6 natural days, inclusive.
- **Revenue:** `SUM(price_show * exchange_rate_to_CNY)`; the same monthly FX-selection pattern as the supplied CN SQL is used.
- **Exclusions:** `dm_platform.dim_user_blacklist` for `app_id=13002010`.
- **Important limitation:** the backup retains all SKU revenue in each campaign’s first-week window. It does **not** assert that every SKU is a package for that player. Player-package-only revenue requires a verified SKU-to-campaign mapping; no such mapping was inferred from names or neighboring IDs.

### Wheel/shop spend

- **Source:** `g13002010.server_shop_detail`.
- **Filter:** `coin_typ='stamps'`.
- **Spend users:** distinct `lcm_id:role_id` per campaign window and shop item.
- **Spend:** sum of `amount`.

### Campaign token flow

- **Source:** expanded `g13002010.daily_game_log.a_rst`.
- **Obtain:** `diff > 0`; **consume:** `diff < 0`.
- **Coverage:** primary wheel tokens plus the paired material token/package listed in `campaign_manifest.csv`.
- **Action type:** `a_typ`; it separates e.g. `activity_reward`, `chain_buy`, `shop_buy`, `charge`, and `activity_roulette` rather than attributing them heuristically.

## Data-source routing

The original CN activity data resides in Aliyun/ODPS and was successfully extracted from the China project (`g13001230`). Existing report migration code was reviewed in `fivecross-sd-tabi`; its Trino `chain_buy` logic remains the intended route for later ThinkingData-side reconciliation. This case deliberately preserves the raw ODPS export because it is the source at risk of deletion.

The legacy legend-player IDs supplied in the existing Global/TW/KR SQL did not occur in CN `g13002010.daily_game_log` during 2024-01-01 to 2026-10-29. They were not fabricated into the CN campaign manifest.

## Reproduction

Use the existing data client and its China ODPS configuration:

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-data-client
venv/Scripts/python.exe main.py fetch --task adhoc/slam_dunk_cn_hall_backup_extract.task.json
```

The task JSON is generated from the SQL files. For each SQL file, create a task with `engine: odps`, `region: china`, `formats: [csv, xlsx]`, and the SQL content as `sql`.

Then copy the resulting CSVs into this case’s `results/` directory and run:

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/build_backup_workbook.py
```

## Verification completed

- ODPS discovery query executed successfully on 2026-10-29 and validated the four campaign starts and item mappings in the manifest.
- The three backup extractions completed successfully from the CN ODPS project.
- Exported row counts: 672 SKU-revenue rows, 1,165 stamp-shop rows, and 49 token-flow rows.
- The workbook was read back after generation: five sheets and four campaign-summary rows are present.
- FX coverage check: `rows_without_fx = 0` for every exported SKU row.

## Pending scope

1. **Player-package attribution:** classify only the player-linked package SKUs after obtaining a verified historical SKU/campaign mapping. Do not use SKU-name matching as a substitute.
2. **Other player campaigns:** add only after their CN activity token/item IDs and first observed dates are validated from the source. The manifest is designed for this extension.
3. **ThinkingData reconciliation:** rerun `chain_buy` and migrated reporting logic after confirming equivalent tables and fields in the `fivecross-sd-tabi` environment.
