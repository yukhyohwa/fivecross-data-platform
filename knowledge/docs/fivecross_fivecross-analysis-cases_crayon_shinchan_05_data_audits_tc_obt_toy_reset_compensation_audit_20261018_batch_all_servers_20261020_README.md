# TC OBT all-server toy reset compensation audit

## Result and release status

This is an independent batch under the original single-role audit. **No original snapshot, query, workbook or script was overwritten. No grant, game-state change, commit or push was performed.**

Fresh TA/global SQL and local reconciliation completed on 2026-10-20. The audited recommendation is **69,912 units of item `390001` for 123 server-role keys across 26 servers**. This is the sum of verified positive shortfalls, **not an assertion that all unresolved losses have been quantified**.

| Mode | Reset candidates | Verified attribution/amount | Positive shortfall resets | Verified zero-shortfall resets | Review resets | Recommended 390001 |
|---|---:|---:|---:|---:|---:|---:|
| Potion `10053` | 45 | 43 | 31 | 12 | 2 | 28,108 |
| 1,000 red diamonds (`10009`) | 183 | 169 | 125 | 44 | 14 | 41,804 |
| Total | 228 | 212 | 156 | 56 | 16 | 69,912 |

Every recommendation is marked `HOLD_GM_HISTORY_NOT_VERIFIED`. **Do not use the file as an immediately executable grant file.** The post-fix material inflow/context query does not expose an authoritative compensation operation key or support/GM grant ledger. Existing compensation cannot be reliably ruled out or deducted. Engineering/operations must complete that check before release.

No compensation is proposed for reset potions, red diamonds or advance material `10264`. Thirty reset records have an advance-allocation review, including sixteen with otherwise verified upgrade compensation; these are retained separately, not assumed to prove a loss of advance materials.

## Scope and rules

- Product/source: Traditional Chinese Crayon Shin-chan OBT, TA/global `ta.v_event_18`.
- Affected payment/reset window: **[2026-10-18 00:00:00, 2026-10-19 20:35:00)**.
- History starts at OBT: **2026-10-14 00:00:00**.
- Supporting future-level and post-fix observation cutoff: **2026-10-20 15:30:00**, exclusive.
- Business timezone: `Asia/Shanghai`. SQL compares the raw TA `#event_time` clock directly. This audit has not independently established a source-timezone conversion; it must not be described as a verified timezone-converted timestamp dataset.
- All servers and platforms are included. There is no iOS, role-name, internal-account, test-account or water-account exclusion. `platform_id` in the identity result is a publisher/channel field (`5x`/blank), not a verified iOS/Android field.
- Special-account classification is unknown without an authoritative roster. Numeric account IDs equal to role IDs are labelled where relevant rather than silently excluded.
- The last-upgrade-only refund defect is **user-confirmed**, superseding the earlier case's hypothesis language.
- Potion mode should return 100% of actual cycle upgrade investment. Diamond mode should return 80%; both should return 100% of advance investment.
- The payment itself is not reimbursed automatically.

`config/snapshot.json` records this contract. SQL boundaries and reconciliation constants are explicit and must be reviewed together when changing the scope. Initial 132-role exact-timestamp probes are preserved as preliminary evidence only; the final history and post-fix queries use **all 2,020 broad-candidate roles**, dynamically selected by SQL.

## Deliverables

All business files are under `outputs/final/`:

- `繁体小新_全服玩具重置赔偿建议_20261018至20261019_2035_待GM查重.xlsx`
- `繁体小新_全服玩具重置_20261018至20261019_2035_发放建议_待GM查重.csv`
- One same-prefix CSV for every workbook sheet, including all candidates, reset evidence, exception review, advance review, mode summary, actual investment, cycles, wallet entries, balance chains, conservation, rounding, identities, post-fix context, coverage, receipts and checks.
- `summary.json`: exact business counts, amounts and release caveats.
- `verification.json`: every output SHA-256, bytes, sheet row counts, source-contract checks and full cell-by-cell read-back results.

The recommendation key is `server_id + role_id + item_id`; quantities are integer `amount`. `fc_id`, included reset IDs, mode amounts, other unresolved candidate IDs and grant gate are retained. Workbook identifiers are strings with text format, not scientific notation. CSV has no type system: import identifier columns as text when opening it in Excel.

## Exhaustive candidate accounting

The broad window query returns **3,245 payment rows for 2,020 server-role keys**, consisting of potion deductions or exact 1,000-red deductions. Independent day counts reconcile exactly with that export. Every row is assigned a stable candidate ID and retained:

| Final classification | Rows |
|---|---:|
| Toy-reset candidate with verified attribution | 212 |
| Toy-reset candidate requiring review | 16 |
| Red deduction without a toy refund or decisive context; review | 30 |
| No toy refund; linked `card_Jobchange` or `shop_buy` context | 2,864 |
| No toy refund and no prior observed toy investment | 123 |
| Total | 3,245 |

The 228 reset candidates concern 157 server-role keys. The exception sheet contains **46 payment candidates across 39 server-role keys**: 16 reset candidates plus 30 unproven red payments. An ambiguous toy or incomplete history never receives a fabricated automatic compensation amount. The review's lower bound is zero; its optional upper bound is explicitly conditional on observed history, not a guaranteed upper bound when telemetry or prior cycles are unresolved. These bounds must not be summed as a global payable amount.

Background `open_toysbox`, stage or equipment events alone are not used to exclude a red payment. `card_Jobchange`/`shop_buy` exclusions remain context-based, not a universal transaction-ID proof. All such rows and raw context remain available for backend review.

## Fresh source evidence and query strategy

The fetcher is adapted from the original audit's `scripts/fetch_query.py`; it reuses the existing sibling `fivecross-data-client/.venv/Scripts/python.exe` and configured TA/global engine. No database connection or credentials were created/copied. The existing client successfully cleared its expired session and performed its configured fresh login.

Each source receipt binds the actual exported CSV to its SQL SHA-256, CSV SHA-256, row count, headers and export UTC timestamp. The fetcher requires a newly created/modified client export and fails rather than substituting an old CSV. Fourteen fresh receipts are retained:

| SQL | Purpose |
|---|---|
| 01_coverage | All-event daily aggregate, Oct 14–20; event discovery and partition coverage |
| 02_candidates | All-window potion/exact-1,000-red payment rows, no population filter |
| 03_context | Initial exact event/ingestion context |
| 04_history / 05_history_counts | Preliminary 132-role targeted history and count, preserved but superseded for final population |
| 06_candidate_counts | Independent exact-window daily payment counts |
| 07_schema | Fresh information_schema discovery |
| 08_all_candidate_history | All 2,020 candidate roles; toy lifecycle and relevant wallet rows from OBT through observation cutoff |
| 09_independent_wallet | Independent UNNEST resource extraction, same final scope |
| 10_history_counts | Independent final history day/event counts |
| 11_identities | Grouped role/server/fc/channel identity evidence |
| 12_near_context | All-candidate context within 500 ms, with exact ingestion timestamp; retains payment anchor separately |
| 13_postfix_gain_context | Preliminary post-fix probe, preserved |
| 14_all_postfix_gain_context | Final all-candidate post-fix material-gain context |

The final history contains **47,507 rows** and its day/event counts match the independent probe. The **27,105 resource objects** match the independent wallet export as an exact multiset, preserving duplicate multiplicity. No exact duplicate history records were observed. There was no full-server all-event detail export; broad coverage is aggregate, and detailed history is candidate-targeted.

Fresh event discovery finds `toy_up`, `toy_break`, `toy_cultivate`, `toy_incubate`, but no dedicated `toy_reset`. Toy events begin Oct 18 in this snapshot; no pre-window toy reset was found in the OBT history. `toy_break` is decomposition, never relabelled as reset.

## Accounting and attribution

### Real wallet investment

Only `item_change.after - item_change.before` determines inventory direction and actual cost. A positive `a_rst.diff` may still describe a consume. High-level `toy_up` payloads are supporting evidence, never a second wallet transaction.

The primary upgrade link requires same role/server, same ingestion time, matching after-balance and event time within 500 ms. Two explicitly labelled fallback links are supported: exact event time and matching after-balance across an ingestion split of at most 35 seconds; or matching after-balance/same ingestion within two seconds. A wallet entry can be used by at most one upgrade. Ambiguous or missing matches are retained as issues.

Of 4,422 toy-upgrade records in the extended candidate history, 4,387 have unique wallet matches; 35 do not. There are 33 unmatched upgrade-wallet deductions. These are extended-population diagnostics, not automatically 35 affected payouts. Cycle gaps exclude the affected reset's amount. Among matched upgrades, 1,276 high-level reported costs differ from actual wallet costs, which demonstrates why those reported costs must not be summed.

### Operation time and instance cycles

Material returns can occur one millisecond after payment. Exact timestamp-only matching missed genuine returns, including a third reset of the original regression role. The final grouping uses role/server, identical ingestion timestamp and at most ten milliseconds between payment and material return. A separate 500-ms discovery query retains wider surrounding context; wider events are not silently merged into an operation. Multiple nearby payments are review cases.

`toy_up.unique_id` is the instance ID. `toy_break.toy_info` may instead store that instance in `id` with `unique_id=0`. Instances are normalized with exact decimal/integer parsing; the numeric values are integral and below 2^53 in this extract. Raw exporter output is preserved, including `.0` formatting introduced by its numeric inference.

The state machine accumulates actual investment by instance and reset cycle, checks level continuity, removes decomposition investment, and clears only a uniquely attributed reset cycle. An unresolved prior reset contaminates later cycle attribution rather than being ignored.

Association requires a unique candidate consistent with the observed refund and no contradictory next same-instance level. A later level-1 observation is explicit corroboration when available. When there is no later observation, the row is labelled `unique_pattern_no_later_level_observation`; this is an inference under the user-confirmed bug, not direct reset telemetry.

**Observed payload nuance:** some refunds match the last high-level reported accumulator rather than the final real wallet deduction. For example, consecutive real costs can be 93 and 43 while the last high-level payload reports 136 and the reset returns 136. The last reported payload may support identity matching, but the amount calculation still uses only **93 + 43 of actual wallet deductions**, never a sum of stale high-level values. This distinction avoids treating an observed full refund as a loss.

### Integer rule

For uniquely attributed diamond resets, **118 fractional examples** match floor(80% of the matching last actual/reported refund basis); no accepted fractional example requires ceiling. The intended cumulative calculation therefore uses `floor(4 * actual_cycle_investment / 5) - actual_refund`. The floor and ceiling alternatives remain visible per reset.

This is an **empirically supported rounding rule**, not a claim of inspected server code or authoritative configuration. No local authoritative toy-reset implementation/config was found. If engineering establishes a different intended cumulative rounding policy, rebuild rather than adjusting individual grants manually.

### Advance materials and conservation

Advance deductions are first retained with the original short temporal-link diagnostic. The cycle reconciliation additionally attributes them to the unique outstanding, not-yet-advanced level-10-multiple breakpoint; ambiguous breakpoints remain unresolved. The separate advance-attribution sheet is the final cycle linkage, not the preliminary two-second match status. Across window resets, 198 have matched attributed advance investment/refund and 30 require review. No uncertain advance shortfall is granted.

All complete key-material wallet chains pass. For **141 applicable reset roles**, an independent lifecycle calculation also passes:

`opening + external gains - closing wallet - still-invested cost - decomposed investment - lawful diamond loss = bug shortfall`.

Reset refunds are removed from external gains. Legal diamond loss is `actual investment - floor(80% of actual investment)` and is not compensated. Sixteen role-level conservation rows are marked inapplicable because of unresolved cycles or upgrade gaps; the audit does not claim they passed.

## Regression and expanded-window finding

The original role `4101883` still reproduces the two pre-11:52 shortfalls, **1,265 + 741 = 2,006**. The larger authorized window finds another potion reset at **2026-10-18 20:47:12.081**, returning 120 against 429 of actual new-cycle investment: **309 additional**. Its batch recommendation is therefore **2,315**, not 2,006. This does not modify the original narrower audit.

## Existing-compensation check

The final post-fix query covers all broad-candidate roles from the repair time through 2026-10-20 15:30, and returns **8,886 joined context rows**. These are context rows, not unique grants; a gain may link to several events. Observed contexts include item changes, decomposition, stage/task/shop activity, charge and other game events. This is not an authoritative GM compensation ledger. No reliable grant reason/operation ID is available to distinguish all compensation from ordinary acquisition. **Existing GM compensation remains unverified, not zero.**

## Reproduction

Use Git Bash with native Windows paths. Do not run the old parent-case builder or overwrite its frozen data.

```bash
export USER_DATA_DIR='C:/Users/5xgames/AppData/Local/hermes/cache/scratch/ta_session_toy_compensation'
PY='C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe'
BATCH='C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/crayon_shinchan/05_data_audits/tc_obt_toy_reset_compensation_audit_20261018/batch_all_servers_20261020'

# Refresh all archived query receipts serially. Preliminary probes are retained for provenance.
"$PY" "$BATCH/scripts/fetch_query.py" \
  01_coverage 02_candidates 03_context 04_history 05_history_counts \
  06_candidate_counts 07_schema 08_all_candidate_history 09_independent_wallet \
  10_history_counts 11_identities 12_near_context 13_postfix_gain_context \
  14_all_postfix_gain_context

# Offline reconciliation, report build, full Excel/CSV read-back and source-contract checks.
"$PY" "$BATCH/scripts/build_report.py"
```

`prepare_history.py` is an initial discovery helper, not the authoritative final-population selector. It regenerates only preliminary role-literal probes and `config/initial_probe.json`; it must not overwrite the final snapshot configuration. Final queries 08–12 and 14 use the broad candidate CTE.

Refreshing can revise source data. Preserve the current batch first if a new vintage is required, and investigate changed source counts. The fixed observation cutoff is intentionally not advanced by a report rebuild.

## Creation-time nickname delivery copy

`scripts/add_creation_names.py` adds only `创角昵称` after `角色ID` to the Chinese-header grant sheet/CSV, producing `_含创角昵称.xlsx` and `_含创角昵称.csv` in `outputs/final/`. It reuses `fetch_query.py` and the configured client, freshly querying only `new_role` from `ta.v_event_18` for the exact 123 server-role keys. The identity is `CAST(server_id AS BIGINT)` plus `#account_id`; names are selected from the earliest event per pair, never from latest login. The observation window is `[2026-10-14 00:00:00, 2026-10-21 00:00:00)` with full Oct 14–20 partitions, using the raw TA event clock without an asserted timezone conversion.

Fresh SQL, result, receipt, per-key match audit and `verification.json` are under Git-ignored `private/creation_names/`. The fresh execution matched 123/123 keys, with zero missing/blank names, repeated new_role keys or time-tie conflicts. UTF-8 hex transport preserves source nicknames exactly, avoiding CSV exporter null/type inference. Unsafe CSV formula prefixes fail closed instead of changing the nickname. CSV is UTF-8 BOM; import ID columns as text because CSV has no type metadata. The XLSX stores IDs and nicknames as strings.

The revised workbook preserves all other ZIP members byte-for-byte. Readback verifies all 20 sheets, every old value/type, row ordering, 123 rows and the unchanged 69,912 item-390001 recommendation. GM hold statuses remain unchanged; this is not recalculation or authorization to grant. Run the script normally for a fresh query or with `--reuse` to reproduce from its hash-verified receipt.

During this revision the requested Chinese-header XLSX was absent on disk (the CSV existed); the existing `localize_grant_headers.py` was executed to recreate the Chinese-header copy from the preserved `_待GM查重.xlsx`, with its own full-cell verification, before adding the column. No compensation builder was rerun.

## Acceptance and privacy

The executed builder validates all 14 SQL/CSV receipts, independent candidate/history counts, exact resource multiset equality, wallet uniqueness, balance chains, applicable conservation, regression, integer-rounding observations, unique grant keys and recommendation sums. It then reloads **every cell of every XLSX sheet and CSV**, including row IDs, counts, string identifiers and integer amounts. No formula calculation/cached-result assumption is used.

`verification.json` reports `PASS_LOCAL_ARTIFACT_AND_SOURCE_CONTRACTS` separately from `EXCEPTIONS_AND_GM_GRANT_CHECK_PENDING`. Successful local validation is **not** permission to disburse or proof that the remaining exceptions are resolved.

Outputs, raw receipts and preliminary SQL containing literal role IDs are Git ignored. Final SQL using candidate CTEs and code contain no credentials. The existing client's task copies/exports remain in its normal local working directories. No external message, payment or game API was called.
