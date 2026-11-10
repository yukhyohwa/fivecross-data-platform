# First-Day Tutorial Stage Dropout — Crayon Shin-chan TC CBT

## Purpose

Quantify new users whose **last recorded main-stage event on their creation day** remained in the `入门` (Tutorial) route, summarized at chapter grain (`1-1-5` → `1-1`). The output shows the size of each chapter segment, D1 non-login, and no subsequent login for the rest of the CBT window.

## Scope

- Game/version: Crayon Shin-chan Traditional Chinese, ThinkingData App 18.
- CBT window: 2026-07-29 through 2026-08-24.
- User cohort: each account's earliest `new_role` inside the window.
- User grain: `#account_id`.
- Exclusions: `internal_users`, `is_windows`, and `is_water` via `user_result_cluster_18`.

## Definitions

| Metric | Definition |
|---|---|
| First-day tutorial chapter | Chapter of the final `stage_fight` event on the account's `new_role` calendar day, limited to `a_rst[1].key = 1001` and stage names matching `入门:<chapter>-<section>-<stage>`. |
| D1 non-login | No `login` event on the natural day after creation. |
| No later login in CBT | No `login` event from D1 through 2026-08-24. |
| Observable users | Only accounts created no later than 2026-08-23 are eligible for D1 / later-login measures. Accounts created on the final CBT day remain in the first-day count but are excluded from those denominators. |

`stage_fight` has no explicit outcome field. “Stayed” here means the last **recorded** main-stage event on D0, not a confirmed failure or a definitive account progression state.

## Files

- `sql/01_first_day_tutorial_stage_dropout.sql` — executable Trino SQL.
- `output/` — verified CSV and Excel exports.

## Run

Copy the SQL into `fivecross-data-client/tasks/adhoc/`, add a task configuration pointing to it, then run:

```bash
./.venv/Scripts/python.exe main.py fetch --task crayon_tc_first_day_tutorial_stage_dropout_20260729_20260824.json
```

## Output columns

- First-day tutorial chapter
- First-day stayers
- D1-observable users
- D1 non-login users and rate
- No-later-login-in-CBT users and rate
- An example final stage and stage ID
