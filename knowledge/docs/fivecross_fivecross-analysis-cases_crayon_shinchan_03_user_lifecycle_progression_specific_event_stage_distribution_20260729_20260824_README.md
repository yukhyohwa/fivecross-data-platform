# Crayon Shin-chan TC — Specific Event Stage Distribution

## Objective

This reusable case locates the main-story chapter at which players first meet a specified event condition during the Traditional Chinese test. It currently contains:

1. First `mount_get` per account.
2. First `open_toysbox` item-depletion-to-zero condition per account and item: an `a_rst` object where `before > after` and `after = 0`.

## Scope

- **Game/version:** Crayon Shin-chan Traditional Chinese, ThinkingData App 18 (`ta.v_event_18`)
- **Test window:** 2026-07-29 through 2026-08-24, inclusive
- **Stage attribution:** the account's latest main-story `stage_fight` (`a_rst[1].key = 1001`) at or before the target event time
- **Chapter rule:** extract the first two numeric segments of the stage name, e.g. `1-1-5 → 1-1`, `简单Ⅱ:1-5-2 → 1-5`

## Files

- `sql/01_mount_get_stage_distribution.sql` — executed and verified `mount_get` result.
- `sql/02_open_toysbox_first_zero_stage_distribution.sql` — all-item toys-box first-depletion distribution.
- `sql/03_item_10238_first_zero_stage_distribution.sql` — executed distribution for item ID `10238` only.
- `tasks/specific_event_stage_distribution.json` — task metadata.
- `output/` — verified exports.

## `open_toysbox` data source and result

`open_toysbox` itself does not carry `a_rst`. The requested object group is recorded in its paired `item_change` event at the **same account and event timestamp**. The query therefore joins those two events, selects `a_rst` objects with `before > after AND after = 0`, and retains the first such event per `#account_id + item_id`.

Verified execution for the test window produced **9,995** account-item first-zero records from **1,647** accounts and **167** item IDs. The export has 3,885 item-ID × chapter rows.

## `mount_get` note

The observed `mount_get` telemetry has 32 events from 4 accounts in the window. All four accounts carry the `internal_users` label; the executed result intentionally retains them because excluding standard test labels would yield no rows.
