# KR Player Battle Customer-Service Log Lookup

## Purpose

This case is a reproducible customer-service lookup workflow for a Korean Slam Dunk player’s disputed battle records. It starts from dates and battle IDs displayed in a backend/customer-service log, resolves the exact `match_fight` telemetry, and exports a row-level audit with raw resource-change payloads.

This README documents the **query approach and rerun procedure**, not a business report or final incident conclusion.

## Applicable scenario

Use this workflow when customer service supplies one or more of the following:

- business player ID or ThinkingData identity;
- backend log date and clock time;
- `win Battle`, `loss Battle`, or similar record labels;
- long battle IDs that may have been copied from a screenshot;
- a suspected mismatch between the displayed battle result and rank-star change.

## Data routing

| Item | Source |
|---|---|
| KR migrated telemetry | `ta.v_event_22` |
| Player identity used by this example | `a_usr = 'ali_tt_10008@100942605'` |
| Settlement event | `match_fight` |
| Battle key | `match_id_str` |
| Player win/loss | `reuslt_str` (source spelling is intentional) |
| Personal score / duration / queue time | `score_str`, `time_str`, `matching_time_str` |
| Rank-star settlement | `comm#star` entry within `a_rst` |

Do not infer a battle from nearby timestamps alone. The primary correlation key is the full `match_id_str`.

## Query method

### 1. Transcribe and preserve IDs as strings

Transcribe the backend screenshot row by row: displayed timestamp, change value, sequence/rank, label, and battle ID. Do not open identifiers as numeric Excel cells; a 23-digit ID can be rounded into scientific notation and lose its tail digits.

The workbook builder explicitly writes all identifier columns as text.

### 2. Lock the initial search range from the backend date

Use the backend date to restrict `$part_date`. If the source timezone is unknown, scan the adjacent partition as well. Do not initially assert KST/UTC conversion from the region alone; establish it by comparing exact battle-ID matches to the displayed timestamps.

### 3. Resolve each battle ID directly

Run `sql/kr_ta_screenshot_battle_ids_exact_lookup.sql` through `fivecross-data-client` with the TA/global engine. This returns every telemetry row matching the directly transcribed IDs, including all participants.

The player’s own row is selected by `a_usr`, not by assuming the ID prefix identifies the reporting player.

### 4. Handle an ambiguous screenshot digit with prefix lookup

If a screenshot’s last digits are unclear, do not invent an ID. Narrow the prefix and scan only the locked date partitions using `sql/kr_ta_loss_row_id_prefix_lookup.sql`. Confirm the complete ID from returned `match_fight` records and then update the transcription.

### 5. Resolve non-battle labels separately

Rows such as `Honor Prize` can precede or follow a battle settlement and may not print a battle ID in the backend log. Query the small time window around the row, identify the player’s adjacent `match_fight`, and then use its exact ID. `sql/kr_ta_honor_prize_battle_exact_lookup.sql` demonstrates the final exact lookup after that correlation.

### 6. Parse and retain the settlement payload

Keep the full `a_rst` payload in the final export. Parse the `comm#star` object only as a convenience field (`star_change`); it is not a substitute for the original resource payload. A customer-service answer must retain enough evidence for R&D to reproduce the settlement.

## Directory layout

```text
kr_battle_customer_service_log_lookup_100942605_20261022/
├── README.md
├── sql/
│   ├── kr_ta_screenshot_battle_ids_exact_lookup.sql
│   ├── kr_ta_loss_row_id_prefix_lookup.sql
│   └── kr_ta_honor_prize_battle_exact_lookup.sql
├── scripts/
│   └── build_customer_service_battle_log.py
└── outputs/
    ├── raw/       # executed TA exports retained as inputs
    └── final/     # generated CSV/XLSX audit deliverables
```

## Execution

### Prerequisites

- Existing FiveCross data-client environment: `C:\Users\5xgames\Desktop\github\fivecross-data-client`
- Python environment with `pandas` and `openpyxl`
- Valid authenticated ThinkingData client session

### Run the SQL

Execute each applicable SQL file through the existing client. Example:

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-data-client
.venv/Scripts/python.exe main.py fetch --engine ta --region global \
  --file C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/slam_dunk/04_data_extraction_audits/kr_battle_customer_service_log_lookup_100942605_20261022/sql/kr_ta_screenshot_battle_ids_exact_lookup.sql
```

Copy the real exported CSV files into `outputs/raw/` with the filenames used by the builder, or change the three filenames at the top of the script.

### Build final artefacts

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/slam_dunk/04_data_extraction_audits/kr_battle_customer_service_log_lookup_100942605_20261022
python scripts/build_customer_service_battle_log.py
```

## Output grain

| File / sheet | Grain |
|---|---|
| `screenshot_full_log` | one displayed backend-log row matched to the player’s settlement event |
| `player_10_battle_logs` | one `match_fight` settlement per player battle |
| `all_10_battles_players` | one participant’s telemetry row per battle |
| raw CSV exports | one event row returned by the executed TA query |

## Validation rules

The builder fails if:

1. any screenshot row does not resolve to `match_fight`;
2. the expected player battle count is not 10;
3. the expected participant count is not 60 (10 battles × 6 players);
4. battle IDs in the main audit sheet are not stored as strings in the workbook.

For a different ticket/window, adjust the expected counts and replace the screenshot transcription block in the script before running it.

## Limitations

- The current legacy ODPS route `g33002013.daily_game_log` returned no data for the investigated 2026-10 date range in the configured project. This case uses exact matches from the migrated ThinkingData event stream and preserves its raw payload.
- Timestamp alignment is empirical for each ticket. The example’s backend clock is approximately event time +1 hour, but that relationship must be revalidated rather than reused as a global KR timezone rule.
- `reuslt_str` is the source field name. Do not rename it in SQL without confirming the schema.
