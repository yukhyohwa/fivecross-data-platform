# Shinchan Events Tracking

This repository owns Shinchan tracking documents, configuration, business rules and acceptance output. Shared validation code, full and targeted workflows, ThinkingData execution and sessions are provided by the adjacent [thinkingdata-events-validation](../thinkingdata-events-validation/README.md) repository.

The root `run.py` is a thin entry that locates the framework and forwards this project's configuration and arguments. Shared source code, maintenance scripts, tests and Node dependencies are maintained in the framework.

## Change policy

**Do not modify `thinkingdata-events-validation` for project-specific work.** Put temporary extraction, cleanup, troubleshooting, execution retries and project-specific checks in this project's `debug/` or `test/` directory, both ignored by Git.

Modify the shared framework only when implementing or improving validation logic shared by the projects, such as field existence, type comparison, sample fidelity, query boundaries or evidence consistency. Update its README, any affected documentation and the corresponding regression tests together.

Keep permanent Shinchan or regional configuration, identity rules, business enums and maintained SQL in this project's `config/` and `rules/`. Possible future reuse alone does not justify adding project helpers to the framework. The KR investigation and temporary retry helper live in `debug/kr/` and do not change the framework's default execution behavior.

## Layout

```text
inputs/tc/tracking.xlsx      Traditional Chinese source specification
inputs/kr/tracking.xlsx      Prepared KR input snapshot
config/tc.json               Traditional Chinese profile and framework location
config/kr.json               KR profile and separate output/evidence paths
rules/identity.json          Shinchan nickname and identity definitions
rules/validation.tc.json     Traditional Chinese targeted checks
rules/validation.kr.json     KR targeted checks
rules/contracts.tc.json      Traditional Chinese supplementary definitions
rules/contracts.kr.json      KR supplementary definitions
rules/sql/                   Maintained project-specific business SQL
run.py                       Thin entry into the shared framework
outputs/tc/                  TC review workbook and acceptance notes
outputs/kr/                  KR review workbook and acceptance notes
outputs/tc/target/           Separate directories for TC targeted invocations
outputs/kr/target/           Separate directories for KR targeted invocations
data/evidence/tc/            TC full-audit evidence; ignored by Git
data/evidence/kr/            KR full-audit evidence; ignored by Git
debug/tc/                   TC investigation scripts, SQL and results
debug/kr/                   KR investigation scripts, SQL and results
test/                       Temporary project-specific checks
.cache/tc/                  TC workbook, catalog and preview caches
.cache/kr/                  KR workbook, catalog and preview caches
```

## Regional profiles

| Region | Profile | Table | Review workbook |
| --- | --- | --- | --- |
| Traditional Chinese | `config/tc.json` | `ta.v_event_18` | `outputs/tc/tracking_review.xlsx` |
| KR, as selected for this audit | `config/kr.json` | `ta.v_event_24` | `outputs/kr/tracking_review.xlsx` |

The default entry selects `config/tc.json`; pass `--config config/kr.json` for KR. This project no longer uses `config/project.json`. Commands shown in older external examples should use the appropriate regional profile here.

The TC source is under `inputs/tc/`. KR uses the prepared `inputs/kr/tracking.xlsx` snapshot derived from that source. See the [TC input notes](inputs/tc/README.md) and [KR input notes](inputs/kr/README.md). Evidence, caches, targeted rules and output are isolated by region. Currency mappings require observed records and confirmed business definitions; historical samples from another region are not substitutes.

```powershell
python run.py --config config/tc.json full run
python run.py --config config/kr.json full run
python run.py --config config/kr.json targeted --event charge --date 2026-11-06 --execute
```

The KR profile currently sets `project.event_time_before` to the exclusive warehouse event-time bound `2026-11-06 11:30:00`. Update or remove this bound when changing the audit window. Generated inventory, property and discovery queries, plus targeted queries and nickname lookup, honor it. Hand-written SQL must declare its own intended boundaries.

## Shinchan identity and business rules

- `#account_id` is the role ID. `fc_id` is the account ID.
- The default targeted identity is `role`, matching `#account_id`. The `account` identity matches `fc_id`.
- Nickname fields, identity groups and the default identity are defined in `rules/identity.json`.
- Validation rule files contain executable checks; contract files record supplementary definitions. Shared-property candidates are not automatically mandatory common properties.

## Commands

Use a Python environment with the framework's dependencies installed:

```powershell
python run.py full status
python run.py full validate
python run.py verify
python run.py full run
python run.py full preview

python run.py targeted --event charge --date 2026-11-04
python run.py targeted --event charge --date 2026-11-04 --nickname "ExamplePlayer" --identity-type role --execute
python run.py targeted --event charge --date 2026-11-04 --id ACCOUNT_ID --identity-type account --execute
python run.py session status
```

`full offline` rebuilds using existing evidence. `verify` rebuilds in an isolated cache without overwriting the delivered workbook. Targeted mode generates SQL by default; `--execute` performs the query. Older full-audit shorthand such as `python run.py validate` remains compatible.

Use `logs_found` and `row_count` in the summary to determine whether logs were observed. `NO_DATA` means no matching event rows; `FAIL` means rows exist but business checks failed. Nickname lookup currently searches records on the selected date. If a zero-row result does not establish the player's identity, resolve the role ID and verify with `--id`. Queries use warehouse partition dates without an additional timezone conversion.

## Output, evidence and temporary files

Each targeted invocation creates a separate directory under the profile's `targeted_output` path, containing `query.sql`, `manifest.json`, and, after execution, `rows.csv` and `summary.json`. TC runs use `outputs/tc/target/`; KR runs use `outputs/kr/target/`. The CLI command remains `targeted`; only its output directory is named `target`.

Each regional output directory contains `tracking_review.xlsx`, `acceptance.md` and `target/`; region-specific supplementary reports may also appear there. Existing workbooks and raw evidence were relocated without changing their bytes.

Full-audit evidence belongs under `data/evidence/tc/` or `data/evidence/kr/`. Temporary investigations belong in `debug/tc/`, `debug/kr/` or `test/`. Older flat output and evidence layouts have been retired. Legacy migration and isolated-verification caches may remain under the root `.cache/`; active workbook, preview and catalog paths are region-specific.

The `.gitignore` excludes the entire `outputs/`, `data/evidence/`, `debug/` and `test/` directories. Generated SQL remains local; maintained SQL intended for version control belongs in `rules/sql/`.

The targeted document catalog is cached under `.cache/tc/catalog/` or `.cache/kr/catalog/` and rebuilt when its source changes. Migration scripts and player diagnostics in `debug/` are project-local, temporary material.

## Dependencies and references

This project directly depends on `../thinkingdata-events-validation`, located through the profile's `framework` setting. The existing data client, Node dependencies, credentials and sessions are execution dependencies owned by the framework; this project does not copy their implementations or dependency links.

See the [shared acceptance rules](../thinkingdata-events-validation/docs/acceptance-rules.md), local [TC acceptance notes](outputs/tc/acceptance.md) and [KR acceptance notes](outputs/kr/acceptance.md). The KR charge investigation is in `outputs/kr/charge_shop_currency.md`.

The TC audit profile now covers inventory partitions `2026-10-12` through `2026-11-10` and property partitions `2026-11-04` through `2026-11-10`. Both `project.event_time_before` and `project.server_time_before` are set to the exclusive warehouse-clock bound `2026-11-10 11:27:00`. The receipt-time bound is needed because AppsFlyer callback event clocks differ from the existing game-event clock. Update these bounds and windows together when refreshing; they apply to full and targeted queries and are included in evidence signatures. The current day is partial. See `outputs/tc/acceptance.md` for the findings and paired-clock checks.

`#data_source_detail` is collection metadata used to identify AppsFlyer evidence. The TC internal-field rule excludes it from the game business-property additions. Historical evidence is retained under `debug/tc/baseline_before_20261110/`; refreshed evidence is queried again rather than given a replacement signature.

Use the framework's `scripts/init_project.py` when creating another game project. Do not copy Shinchan identity semantics or historical query evidence into it.
