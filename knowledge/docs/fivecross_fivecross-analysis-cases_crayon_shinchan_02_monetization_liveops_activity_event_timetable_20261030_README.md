# Crayon Shinchan Traditional Chinese Activity Timetable and Rule Reference

This project is the reusable **activity timetable, activity relationship, item, gift-scope, and rule reference** for Crayon Shinchan Traditional Chinese App18 / ThinkingData project 18.

It is deliberately separate from the activity-comparison case:

- **This project:** maintains canonical activity names, aliases, parent/child relationships, occurrence numbers, time windows, item-consumption rules, gift filters, schedule cells, source provenance, and rule certainty.
- **Activity comparison:** `../activity_comparison_review_20261030` keeps historical analytical SQL, observed data, comparison outputs, Excel, and PPT.

Updating this rule reference does **not** refresh production data, comparison metrics, Excel files, or PPT files. When a later analysis needs current data, read the applicable rules from this project and execute a new query for that analysis request.

## 1. Current source and authority

The current timetable source is:

```text
inputs/蠟筆小新-繁體版開服活動整理_20261031.xlsx
```

Relevant worksheets:

- `活動排期_obt調整版` — opening-day schedule through D35;
- `主題-野外露營` — camping sub-activity configuration references.

The current input SHA-256 is:

```text
b9d4a8209b9e2b6769f7232c6044fdd01a93c2bf12805b61a488a5f3a10e4708
```

Rule priority is:

1. explicit user-confirmed business rules;
2. the current workbook and its identified cells;
3. verified SQL and dimension mappings from the comparison case;
4. observed event evidence, which cannot by itself prove an official configured activity window.

Unconfirmed values remain marked as unknown or require dimension confirmation. They must not be silently promoted to verified facts.

## 2. Canonical data model

### `activities`

One row represents one canonical activity node. The important fields are:

| Field | Meaning |
| --- | --- |
| `activity_key` | Stable internal key used for joins. It is not the display name. |
| `name` | Canonical business name used in reports and queries. |
| `parent_key` | Parent activity key for a child activity; `NULL` for a top-level activity. |
| `occurrence_no` | The product/activity series' occurrence number: first launch = `1`, later reruns = `2`, `3`, etc. |
| `schedule_basis` | `server_opening_day` or `natural_date`. |
| `schedule_window` | Only the pure range, such as `D9-D11` or `2026-11-04–2026-11-10`. |
| `special_rule` | Explanations, inheritance rules, exclusions, evidence, and unresolved timing details. |
| `status` | Reference status; these rows are not production activity records. |

The display name for the four current 娃娃機 / 开心福引机 entries uses the required `活动_道具` form:

- `开心福引机_自选-2代影像` — `occurrence_no = 1`, D9-D11;
- `开心福引机_背饰-春日部防衛隊風箏` — `occurrence_no = 2`, D16-D18;
- `开心福引机_奇妙大力锤` — `occurrence_no = 3`, D22-D23;
- `开心福引机_坐骑-涂鸦飞机` — `occurrence_no = 4`, D28-D30.

`开心福引机1` / `giftbox_1` style labels are not canonical display names or current activity keys. Historical/source names remain in `activity_aliases` only so that old SQL and source references can be resolved.

### Time-window semantics

- A cell containing `需要配指定日期` or an equivalent date-based marker uses `natural_date`.
- Other timetable cells use each server's opening age, with D1 defined as the natural date of the first valid `new_role` for that server.
- Opening-age days change at the natural-day midnight boundary.
- `schedule_window` contains no text such as `跟随野外露营` or `含首尾自然日`; those explanations belong in `special_rule`.
- The workbook confirms the following natural-date windows:
  - 野外露营: `2026-11-04–2026-11-10`;
  - 人生大富翁: `2026-10-28–2026-11-03`.
- Exact backend switch timestamps remain separate from the confirmed natural-date range when they were not supplied by the source.

### Parent/child relationships

The database models these relationships explicitly through `parent_key`:

```text
野外露营
├── 垂钓奇遇
├── 盲盒挑战
├── 露营手册
└── 露营自选礼包

人生大富翁
├── 大富翁自选礼包
└── 大富翁时装礼包
```

A child inherits the documented timetable window where stated. It does not automatically inherit the parent's event identity, participation event, item consumption, or gift scope.

## 3. Current canonical activity roster

The generated database currently contains 18 canonical activity nodes:

| Activity | Parent | Occurrence | Schedule basis | Window |
| --- | --- | ---: | --- | --- |
| 限时坐骑·钢达姆机器人 | — | 1 | Server opening day | D2-D7 |
| 限时伙伴·机器犬小白 | — | 1 | Server opening day | D1-D7 |
| 欢乐派对 | — | 1 | Server opening day | D8-D14 |
| 限时伙伴·和服小葵 | — | 1 | Server opening day | D8-D14 |
| 限时技能·飞虹泡泡 | — | 1 | Server opening day | D15-D21 |
| 开心福引机_自选-2代影像 | — | 1 | Server opening day | D9-D11 |
| 开心福引机_背饰-春日部防衛隊風箏 | — | 2 | Server opening day | D16-D18 |
| 开心福引机_奇妙大力锤 | — | 3 | Server opening day | D22-D23 |
| 开心福引机_坐骑-涂鸦飞机 | — | 4 | Server opening day | D28-D30 |
| 野外露营 | — | 1 | Natural date | 2026-11-04–2026-11-10 |
| 垂钓奇遇 | 野外露营 | 1 | Natural date | 2026-11-04–2026-11-10 |
| 盲盒挑战 | 野外露营 | 1 | Natural date | 2026-11-04–2026-11-10 |
| 露营手册 | 野外露营 | 1 | Natural date | 2026-11-04–2026-11-10 |
| 露营自选礼包 | 野外露营 | 1 | Natural date | 2026-11-04–2026-11-10 |
| 人生大富翁 | — | 1 | Natural date | 2026-10-28–2026-11-03 |
| 大富翁自选礼包 | 人生大富翁 | 1 | Natural date | 2026-10-28–2026-11-03 |
| 大富翁时装礼包 | 人生大富翁 | 1 | Natural date | 2026-10-28–2026-11-03 |
| 限时伙伴·探长风间 | — | 1 | Server opening day | D29-D35 |

The roster is a rule reference, not a claim that every node has a confirmed event ID, confirmed SKU, or confirmed participation event.

## 4. Item and gift-scope rules

Item consumption is stored in `activity_items`. Gift-product matching is stored independently in `gift_scopes`.

Current important mappings include:

| Activity | Item / gift rule | Certainty or limitation |
| --- | --- | --- |
| 垂钓奇遇 | Item `10245` 鱼饵; `item_change`, `type=2`, `change_source=43`, positive `before-after`; gift filter `product_id@product_name_tc LIKE '%垂釣%'` | Consumption rule confirmed; quantity is resource consumption, not reward-array length. |
| 盲盒挑战 | Item `10159` 魔法棒; `item_change`, `type=2`, `change_source=43`; gift filter `product_id@product_name_tc LIKE '%盲盒禮包%'` | Positive deductions may include end-of-event conversion. The `active_reward` participation mapping is not confirmed. Do not use the deduction count as participant count. |
| 开心福引机 family | Gift filter `product_name_tc REGEXP '開心禮盒機|开心礼盒机|幸運許願池|幸运许愿池'` | Filter is retained as a family scope; it is not an automatic per-period SKU mapping. |
| 开心福引机_背饰-春日部防衛隊風箏 | Item `10244` 抽奖币 | Registered from the verified historical activity rule; period attribution remains a separate analytical step. |
| 人生大富翁 | Self-select gift scope plus costume SKU `118601`; exclude 大富翁特權卡 | Self-select SKU list still requires current dimension confirmation. |
| 露营手册 | Gift filter `product_name_tc LIKE '%露營手冊%'` | Filter retained; final SKU requires dimension confirmation. |
| 露营自选礼包 | Gift filter `product_name_tc LIKE '%露營自選禮包%'` | Filter retained; final SKU requires dimension confirmation. |

A gift filter is not the same as a confirmed SKU. Query code must read `certainty` and `confirmed_skus` before presenting an SKU as verified.

## 5. SQLite database and table roles

The canonical database is:

```text
reference/activity_rules.sqlite
```

Current generated row counts are:

| Table | Rows | Role |
| --- | ---: | --- |
| `activities` | 18 | Canonical activities, timing, hierarchy, occurrence numbers, and special rules. |
| `activity_aliases` | 39 | Historical names, source labels, and compatibility aliases. |
| `activity_items` | 8 | Activity-to-item mappings and consumption definitions. |
| `gift_scopes` | 12 | Gift filters, confirmed SKU notes, purchase channel, and certainty. |
| `schedule_cells` | 328 | Every non-empty D1-D35 timetable cell; `activity_key` is nullable for cells outside the canonical roster. |
| `sources` | 3 | Input workbook/config locators and SHA-256 provenance. |
| `metadata` | 8 | Schema purpose, source hash, range, refresh policy, and report policy. |

There is intentionally no separate `activity_rules` table. The current model stores the per-activity explanatory rule in `activities.special_rule`; keeping an additional empty rules table would create a second, unused rule layer. If future rules become genuinely multi-row and independently queryable, add that schema only with a migration and explicit source semantics.

The JSON and CSV files are generated exports for review and interchange. They are not a second business definition:

- `reference/activity_rules_reference.json` — canonical activity rule export;
- `reference/activity_schedule_day1_35.csv` — D1-D35 schedule-cell export;
- `reference/activity_schedule_day1_35.json` — schedule export with source hash;
- `docs/ACTIVITY_RULES.md` — human-readable generated rule summary.

## 6. Rebuild and verification

Run from the project root in an environment containing the existing workbook-reading dependency (`openpyxl`):

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/crayon_shinchan/02_monetization_liveops/activity_event_timetable_20261030

python scripts/build_activity_rules_reference.py
python scripts/build_activity_rules_db.py
```

The first script reads the workbook and regenerates the JSON/CSV exports and `docs/ACTIVITY_RULES.md`. The second script deletes and rebuilds the SQLite database from those exports. It does not query production data and does not modify the comparison Excel/PPT.

Basic verification:

```bash
python - <<'PY'
import sqlite3

con = sqlite3.connect('reference/activity_rules.sqlite')
assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
assert con.execute('SELECT COUNT(*) FROM activities').fetchone()[0] == 18
assert con.execute('SELECT COUNT(*) FROM schedule_cells').fetchone()[0] == 328
assert con.execute("SELECT COUNT(*) FROM activities WHERE occurrence_no IS NULL").fetchone()[0] == 0
assert con.execute("SELECT COUNT(*) FROM activities WHERE schedule_window LIKE '%跟随%' OR schedule_window LIKE '%（%'").fetchone()[0] == 0
assert con.execute("SELECT COUNT(*) FROM activity_items WHERE item_id IN (10159, 10245)").fetchone()[0] == 2
print('PASS')
PY
```

Useful inspection queries:

```sql
SELECT activity_key, name, parent_key, occurrence_no,
       schedule_basis, schedule_window, special_rule
FROM activities
ORDER BY parent_key, occurrence_no, activity_key;

SELECT activity_key, item_id, item_name, event_name,
       event_type, change_source, certainty
FROM activity_items
ORDER BY activity_key;

SELECT activity_key, product_filter, confirmed_skus, certainty
FROM gift_scopes
ORDER BY activity_key;
```

## 7. Known limits

- Exact backend switch timestamps are not stored as confirmed facts when the workbook only establishes natural-day ranges.
- `盲盒挑战` item deductions cannot currently be used as a validated participant or draw count because `active_reward` mapping is unresolved and end-of-event conversion may be mixed in.
- Final SKUs for 露营手册, 露营自选礼包, and 大富翁自选礼包 require a current dimension lookup.
- A child activity's timing inheritance does not prove that its event, item, or gift population is identical to the parent activity.
- Historical observations in the activity-comparison project do not overwrite this timetable and cannot independently prove official launch or closure.
- The timetable ends at D35 because that is the range covered by the current workbook.

## 8. Change policy and security

When a product is rerun, append a new canonical activity row with the next `occurrence_no`; do not overwrite the prior occurrence. Keep old names in `activity_aliases` when compatibility is useful, but do not make them the new canonical display name.

Do not refresh business data, comparison outputs, Excel, or PPT as a side effect of rebuilding this reference. Update those deliverables only when explicitly requested.

NEVER include API keys, tokens, passwords, secrets, credentials, or connection strings in the summary — replace any that appear with [REDACTED]. Note that credentials were present, but do not preserve their values.
