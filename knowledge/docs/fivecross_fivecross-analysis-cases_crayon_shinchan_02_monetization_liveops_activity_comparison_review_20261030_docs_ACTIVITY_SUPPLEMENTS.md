# Activity supplement inventory and provenance

## Current rule override — 2026-11-06

Read [活动规则与关键时间表](ACTIVITY_RULES.md) and its [JSON source](../reference/activity_rules_reference.json) / [CSV](../reference/activity_rules.csv) before reusing these supplements. [User confirmation](ACTIVITY_RULES_CONFIRMATION.md) resolves the former global-versus-server-age question: camping starts on natural date **2026-11-04**, not D22. Date confirmed; exact switches and end date unknown. Children inherit only timing; independent switches unconfirmed. Do not infer November10 from the historical span.

The older unresolved timing statement below is retained as archive history and is superseded only for that rule. Blind-box reward mapping and conversion uncertainty remain unresolved. No supplement SQL/evidence, active config, official metric or Excel/PPT is rewritten; future data retrieval is on demand, and report updates require explicit user instruction.


This archive supplements, rather than replaces, the November4 activity-comparison case. All paths below are relative to the case unless explicitly absolute. No source was moved or deleted.

## Selected source branches

1. `sql/dashboards/blind_box_daily.sql`: exact copy of `C:/Users/5xgames/AppData/Local/hermes/cache/scratch/小新繁体_盲盒挑战_每日参与与礼包消费.sql`.
2. `sql/dashboards/fishing_daily.sql`: exact copy of `C:/Users/5xgames/AppData/Local/hermes/composer-pastes/pasted_content_2026-11-05_05-37-43-090_aed94b.txt`.
3. `sql/supplements/blind_box/` and `evidence/supplements/blind_box/`: bounded discovery, dimension, resource, independent linkage control and final validation. The seven CSVs are dimension or group aggregates. `blind_link.csv` and payload sample exports were deliberately excluded because broad sample payload fields are unnecessary for reproducible controls. The aggregate linkage control already tests existence without multiplying resources by reward rows.
4. `evidence/supplements/fishing/`: dimension, activity discovery, independent control and historical daily output. Their original receipt CSV hashes/counts are checked, but executed probe SQL referenced by those receipts is missing from scratch. No claim is made that the latest supplied SQL was executed by that historical receipt.
5. `sql/supplements/camp_d1d2/`, `scripts/supplements/camp/analyze.py`, `evidence/supplements/camp_d1d2/`: November5 independent camping/fishing/blind-box versus party spending diagnosis. Fixed cutoff `2026-11-05 16:40:36`; full-day historical references are distinct from same-clock comparisons. Nine aggregate outputs were reproduced using the original analyzer and compared in full. Official November4 metrics are untouched.

The manifest records relative archive paths, source provenance, SHA-256, bytes, CSV schema and row counts, seven external replay dependencies and88 protected baseline file hashes. Source receipts were not copied verbatim: only explicit allowlisted metadata was retained. SQL hashes in sanitized historical probe provenance are archive-time hashes, not hashes recorded by the original query executor. The latest blind query's bound body equals the historical validation SQL, but this is not authenticated execution provenance or a new live query.

## Dependency closure and privacy

The camp analyzer consumes `payments`, `logins`, `opens`, `fishing_start`, `payment_control`, `products` and `rates`. The exact source files and receipts were hash-checked; source `payments`/`logins` contain account identifiers, while product dimensions contain unconstrained extra fields. These inputs remain at the indexed original directory rather than being put in the public project. The optional validator reconstructs this complete offline dependency closure into temporary ignored storage, strips receipts to `csv_sha256`, verifies payment controls, reproduces all nine outputs, and removes temporary inputs even on failure. Default validation requires only the non-sensitive archive and verifies hashes, schemas, SQL contracts and aggregate identities. Authorized backups of external inputs are necessary for future full replay; scratch paths are not durable backups.

All archived CSVs have explicit manifest schema allowlists and were checked for account/device/role fields and payload columns. Raw account CSVs, user labels, original query receipts, session/browser profiles, page text, cookies, auth files, and individual awakening/fishing investigations were not copied. Private output is exactly `private/activity_supplements/validation.json`; the existing `private/` ignore covers temporary replay directories. No global ignore or other case was changed.

## Related branches indexed, not imported

Original base: `C:/Users/5xgames/AppData/Local/hermes/cache/scratch/`.

| Original relative path | Scope | Decision |
|---|---|---|
| `camp_diag_20261105/details.py` | Additional calculations over analyzer data, imports current case classifier | Reference only; not needed to reproduce the nine selected aggregates. |
| `camp_diag_20261105/ppt_delivery/` and its two PPT files | Separate November5 narrative/visual delivery | Original paths indexed only; not added as an approved output or wired into this case's builder. |
| `shinchan_stage_dashboard/主线副本.sql` | Main-stage progression dashboard | Different business scope; left in place. |
| `shinchan_stage_dashboard/守护海滩.sql` | Guardian-beach progression dashboard | Separate scope without verified activity-comparison closure; left in place. |
| `shinchan_stage_dashboard/限时对决.sql` | Limited-duel dashboard | Separate scope; left in place. |
| `fishing_20261104/session/` | Browser runtime state | Never imported. |
| Individual player investigation directories and root detail/identity/tag exports | Personal-account diagnosis, not aggregate activity comparison | Excluded entirely, including packaged copies. |

## Verification levels and remaining boundaries

- **Archive integrity:** source-copy hash equality, exact schemas/counts, safe receipt CSV binding and protected existing files.
- **SQL:** real sqlglot Trino parsing with a bound macro, exact resource/product scope, FX checks, cash/crystal internal asymmetry, crystal/100 once, blind NULL participation, and bound blind historical-body equivalence. Parser success does not prove warehouse execution.
- **Historical aggregate evidence:** blind resource total reconciles to the independent control; bounded discovery lacks a confirmed target reward; absence is not proof of all-history nonexistence.
- **Camp reproducibility:** real isolated analyzer execution against seven external hash-checked input CSVs and full row-wise comparison of all nine archived outputs; no live refresh.
- **Formal pipeline:** existing `run.py verify` and `refresh-help` passed; candidate content matches approved November4 final. Preserved cover warning remains. No rebuild/publication was needed for archive-only work.

Blind-box reward mapping, end-conversion separation, fishing global-versus-server-age schedule, and authenticated historical SQL execution hashes remain unresolved. These limits must not be converted into completed activity-participation acceptance or inclusion in official comparison rankings.
