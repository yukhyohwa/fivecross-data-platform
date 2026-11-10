# TC OBT Customer Support Mainline Audit

## Current release: v3 — Mainline OR limited challenge

**The current deliverable is v3.** It expands the original v2 roster from the source, rather than merely enriching the previous export:

```sql
mainline_max_stage_id > 4000
OR limited_success_stage_id > 10090
```

Limited challenge uses `stage_fight`, type/key **1027**, and **`result = 0`** only. The user confirmed **10001 = level 1**, so displayed limited-challenge level is `stage_id - 10000`; **strictly above level 90** therefore means raw ID >10090, not raw ID >90. Keep raw ID and derived level separately. `result = 1` rows are counted only in audit evidence and never contribute to highest successful limited-challenge stage. The user also confirmed that mainline `stage_fight` records victories only; dungeon victory/defeat semantics must not be generalized to mainline logs.

The fixed cutoff remains **2026-10-17 13:09:00**. Existing power, nickname, payment and internal-user definitions remain unchanged.

| v3 population | Roles |
|---|---:|
| All qualifying roles | 1,009 |
| External-label-not-matched roles | 978 |
| Internal users (new) | 31 |
| Mainline criterion only | 810 |
| Both criteria | 196 |
| Limited-challenge criterion only / newly added | 3 |
| External zero-recharge roles | 67 |

**Current files:**

- `sql/cs_obt_mainline_or_limited_stage_v3.sql` and its matching `tasks/` JSON: executed expanded-population query.
- `sql/cs_obt_v3_limited_and_payment_audit.sql`: independent post-creation `result=0` aggregation and role/FC raw-charge audit for all 1,009 roles.
- `sql/cs_obt_limited_stage_probe.sql`, `sql/cs_obt_limited_dim_probe.sql`: schema/mapping discovery evidence.
- `scripts/build_report_v3.py`: build and validate the current workbook from versioned raw exports; verifies `config/raw_sha256_v3.json`.
- `config/snapshot_v3.json`: v3 scope and expected counts.
- `outputs/final/蜡笔小新繁体_OBT主线超4000或限时闯关超90_20261014至20261017_130900_v3.xlsx`: current six-sheet workbook, including the three newly added players.
- `outputs/verification_v3.json`: executed v3 acceptance-check results.

```bash
CLIENT='C:/Users/5xgames/Desktop/github/fivecross-data-client'
"$CLIENT/.venv/Scripts/python.exe" scripts/build_report_v3.py
# Optional live re-execution; does not replace archived baseline CSVs:
"$CLIENT/.venv/Scripts/python.exe" scripts/fetch_query.py --client "$CLIENT" \
  --task cs_obt_mainline_or_limited_stage_v3
```

Validation passed: all 1,006 v2 roles are retained, and the three added roles have mainline IDs at or below 4,000 but limited-challenge success above level 90. Every existing field matches v2, allowing only sub-cent floating-point aggregation noise in monetary fields (less than 1e-12, identical at currency precision). All 1,009 limited-stage maxima match an independently queried **post-creation result=0** aggregate. All 67 external zero-payers have zero raw `charge` rows under both role and FC identity checks. Every cell of the main v3 worksheet was read back and compared with the source export plus audited enrichment.

The original v2 files and commands below remain as a **historical baseline**, not the current expanded-population deliverable. `scripts/verify_report.py` verifies v2 only; v3 validation is performed by `scripts/build_report_v3.py`. The v3 workbook's recent-success timestamp is the last successful limited-challenge log, not necessarily the timestamp of the highest stage. Derived limited-stage display labels are not configuration-sourced official names.

## Historical v2 purpose and status

This subproject preserves the customer-support investigation of Traditional Chinese Crayon Shin-chan OBT players with an observed mainline stage ID above 4,000. It packages the **corrected, delivered snapshot**, its executed SQL, raw query exports, supplementary audit evidence, and scripts that rebuild and verify the workbook. It is a player-review aid, not an automated cheat verdict or account-sanction pipeline.

The authoritative version uses **`battle_start.battlepower`** for player power and the **last `login.role_name`** for nickname. Earlier workbooks based on `card_battlepower` are superseded and are not included as final deliverables here.

## Data source and scope

| Setting | Value |
|---|---|
| Game/version | Crayon Shin-chan, Traditional Chinese OBT |
| Engine | ThinkingData / Trino, existing `fivecross-data-client` |
| Event table | `ta.v_event_18` |
| OBT start | 2026-10-14 00:00:00 |
| Fixed observation cutoff | 2026-10-17 13:09:00, Asia/Shanghai |
| Geography/servers | All regions and servers in App 18; no country/server restriction |
| Grain | One row per role, `#account_id`; platform account retained separately as `fc_id` |
| Eligibility | OBT-window `new_role` exists for the role; highest observed mainline ID strictly greater than 4,000 |
| Internal accounts | Retained and labelled, not excluded |

This archive is a historical snapshot, **not a live report as of the time the build script is run**. Cumulative revenue covers this OBT window only, not the account's full history. The cutoff is embedded in the executed SQL; `config/snapshot.json` documents it but is not a runtime parameter that rewrites SQL.

## Business definitions

- **Player ID:** role `#account_id`, preserved as text. Do not merge multiple roles solely because they share a platform account.
- **5X ID:** latest observed nonblank `fc_id` mapped to that role within the fixed window.
- **Latest nickname:** `role_name` from the last `login` by `#event_time`, with `#server_time` as a timestamp tie-breaker. Do not substitute names from unrelated event types or older nonblank login rows.
- **Latest power:** `battlepower` from the last `battle_start` using the same ordering. `lamp_level` and `role_lev` come from that **same event row**. The battle timestamp is exported. `card_battlepower.battlepower` and its `a_rst.after` are not authoritative player-total power.
- **Final mainline stage:** highest observed `mainstage_id` / mainline `stage_fight.a_rst[1].id` (`key=1001`) in the window, not the last attempted stage or confirmed victory. Names come from `ta_dim.dim_18_0_52765`. Latest positive reported mainline ID is retained separately.
- **Internal user (new):** membership in `internal_users_new` from `user_result_cluster_18`, joined on `TRIM(CAST("#varchar_id" AS VARCHAR)) = fc_id`. A negative flag means no matching current label, not independently certified external identity. Water and Windows labels are retained as review context rather than removing potentially relevant players.
- **Cash recharge:** `charge`, sandbox/free-buy false or null, positive `pay_amount`, excluding `COIN`. Daily/currency FX uses `ta_dim.ta_exchange`; missing FX remains unknown rather than being silently treated as 1. Role recharge and all-server FC-account recharge are separate columns. Event-provided USD is a reference field, not the final FX-normalized amount.
- **Zero recharge:** independently checked against raw `charge` by role ID **or** FC ID. The 64 external zero-recharge roles have zero raw charge rows in the archived window; this says nothing about time outside that window.

## OBT versus legacy-data safeguards

Launch-day snapshots at approximately 00:30 can contain pre-OBT progress even when the same role's OBT `new_role` occurs later that morning. Snapshot identity is `lid`; snapshot `#account_id` can be an invalid placeholder. Do not simply treat every October 14 snapshot as OBT progress.

The executed primary SQL gates the roster by OBT `new_role` and scans owned event progress. Independent regression SQL recalculates post-creation maximum progress for every selected role; all 1,006 rows match. Post-creation snapshot anti-join returned no missing eligible external role. Nine high-progress legacy snapshots were confirmed to precede OBT creation. Nineteen unlabelled legacy records without an observed OBT creation are retained on a separate pending-confirmation sheet, not silently called current external OBT players.

Some supplementary audit SQL files retain unused historical CTE definitions from the original investigation. They support registration, payment and snapshot checks only; the corrected primary query is the sole source of delivered power and nickname.

## Directory layout

```text
config/
  snapshot.json                 Snapshot metadata, source filenames and expected counts
  raw_sha256.json               SHA-256 checksums of all archived raw CSV files
sql/
  cs_obt_over4000_battle_start_v2.sql   Corrected primary detail query
  cs_obt_final_regression.sql          Post-creation progress/payment regression
  cs_obt_zero_pay_audit.sql            Raw charge check for external zero-payers
  cs_obt_snapshot_completeness.sql     Initial snapshot anti-join
  cs_obt_snapshot_reason.sql           Missing-snapshot eligibility/tag classification
  cs_obt_snapshot_postreg.sql          Post-creation external completeness check
  cs_obt_prelaunch_snapshot_check.sql  Launch-day legacy snapshot evidence
tasks/                         Matching client task JSON files
scripts/
  build_report.py              Rebuild the workbook from archived raw exports
  verify_report.py             Verify raw hashes, sheet counts and optional original workbook
  fetch_query.py               Optional re-execution through the existing data client
outputs/
  raw/                        Seven original CSV snapshots
  final/                      Corrected workbook rebuilt locally
  verification.json           Build validation result
  archive_verification.json   Archive/reference comparison result
```

## Environment and dependencies

Reuse the existing sibling repository `fivecross-data-client` and its virtual environment. No credentials are copied into this project. Offline rebuild requires Python and `openpyxl`; the local client environment already supplies these. Live SQL execution additionally requires the client's configured ThinkingData access and browser dependencies. There is no separate database, SQLite store, scheduled job, or dashboard integration.

## Rebuild and verify offline

Run from this case directory using the existing client interpreter (Git Bash examples):

```bash
CLIENT='C:/Users/5xgames/Desktop/github/fivecross-data-client'
"$CLIENT/.venv/Scripts/python.exe" scripts/build_report.py
"$CLIENT/.venv/Scripts/python.exe" scripts/verify_report.py
```

To compare every cell with the originally delivered corrected workbook:

```bash
"$CLIENT/.venv/Scripts/python.exe" scripts/verify_report.py \
  --reference "$CLIENT/data/output/蜡笔小新繁体_OBT全区全服主线超过4000关玩家明细_20261014至20261017_130900_战力修正版v2.xlsx"
```

The archived builder intentionally contains fixed snapshot filenames and regression counts. For a new reporting date, create a new versioned snapshot and update its SQL, raw inputs, metadata, build expectations and audit checks together. Do not replace only the primary CSV and reuse stale supplementary evidence.

## Optional SQL re-execution

```bash
"$CLIENT/.venv/Scripts/python.exe" scripts/fetch_query.py --client "$CLIENT"
"$CLIENT/.venv/Scripts/python.exe" scripts/fetch_query.py --client "$CLIENT" \
  --task cs_obt_final_regression
```

The runner copies the selected archived SQL/config to the client's ad-hoc task tree under a distinct `cs_support_archive_` prefix, invokes `main.py fetch`, requires a newly exported CSV, and copies it into `outputs/refreshed/`. **It never replaces archived baseline CSVs.** Re-execution keeps the historical cutoff but current tags, dimensions, FX data or late arrivals may differ. Reconcile any refreshed result before promoting it to a new baseline. The runner's CLI/help was exercised during packaging; no additional live query was submitted solely to archive this case.

## Output and verified acceptance checks

The final workbook is `outputs/final/蜡笔小新繁体_OBT全区全服主线超过4000关玩家明细_20261014至20261017_130900_战力修正版v2.xlsx`.

| Sheet | Data rows |
|---|---:|
| 全区全服超过4000关明细 | 1,006 |
| 外部玩家明细 | 975 |
| 外部零充值重点核查 | 64 |
| 零充值原始订单复核 | 64 |
| 无OBT创角存量待确认 | 19 |
| 口径与核查说明 | 14 |

The full roster contains 31 internally labelled roles. The external roster covers 34 servers. The archived rebuild was actually executed, then every cell of all six sheets was compared with the corrected delivered workbook: **identical values**. All seven raw-file hashes were verified. Power, nickname, lamp level and role level were also checked row by row against the corrected query export. The expected primary role set, progress regression and zero-payment role set were validated.

## Troubleshooting and limitations

- **Missing raw file / checksum mismatch:** restore the archived CSV; do not edit a raw file to bypass verification.
- **Count assertion fails:** check that the corrected v2 CSV and matching historical audit files were used. A new live population needs a new validated snapshot.
- **Missing power or nickname in a future refresh:** leave unknown; investigate the last `battle_start`/`login` instead of falling back to `card_battlepower` or other names.
- **ThinkingData session expires:** use and inspect the existing client's automatic re-login path before asking for manual login. Do not store credentials here.
- **No new CSV from live runner:** inspect the client's log and final export state; successful process exit alone is not proof of a completed query.
- **Threshold interpretation:** stage ID >4,000 identifies an investigation population, not a confirmed number of successful stages or a cheat verdict. Review payment, progress timing and gameplay evidence before taking action.
- **Automation:** offline builds and optional query runs are manual; no scheduled job or external state changes are installed by this project.
