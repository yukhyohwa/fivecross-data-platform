# Shin-chan TC OBT: D3 Absence and Survey Diagnostic

## Purpose and current delivery

This fixed-date case investigates why some players who return on their second natural day do not return on their third. The principal comparison is **D2 return / D3 absence** against **D2 return / D3 return**. It describes associations in early payment, progression, estimated play time and gameplay participation; it does not prove causal drivers or permanent churn.

The delivered continuation is the **iOS first-OBT-registration account population**, documented further in [ios/README.md](ios/README.md). The root analysis remains an independent **all-platform baseline**; do not label its counts as iOS counts. The preserved iOS delivery uses the complete `20261020_135918` seven-query batch, with iOS filtering applied before feature aggregation. The copied historical all-platform outputs retain their original receipts from `20261020_134053` and `20261020_134847`; they must not be represented as the same-vintage iOS baseline. Rerunning the root analyzer now selects the newest valid receipts and changes those historical baseline artifacts.

**Survey linkage is implemented and verified.** The extension reuses the definitions and validated normalization in `C:/Users/5xgames/Desktop/github/shinchantc-obt-survey-analysis`, using its current repository name. It links role-based Day1/Day2 questionnaires to the same iOS account panel using a fresh App18 role-to-account bridge. The combined workbook preserves the 16 behavior sheets and adds 14 questionnaire sheets, with 30 sheets total. The first sheet summarizes questionnaire findings and their limitations.

## Provenance and reproducibility

This directory was copied, without modifying or deleting its source, from:

```text
C:/Users/5xgames/Desktop/github/ai-agent-adhoc/shinchan_tc_obt_d3_churn_diagnostic_20261020
```

`migration_manifest.json` records the copied file paths, byte sizes and SHA-256 hashes. Every copied file was compared with its source at copy time. The destination `.gitignore` was subsequently strengthened, and this English README was added. Original query receipts, source manifests and output verification JSON are preserved. Historical absolute paths in `ios/outputs/verification.json` and `excel_verification.json` identify the original verification environment; they are provenance, not runtime dependencies. Runtime scripts derive the case root from their own location. The external data-client path in `config.json` is intentionally unchanged.

The latest complete source batch is `data/raw/20261020_135918/`, containing seven CSV exports, seven SQL snapshots and seven metadata receipts. Earlier available batches are retained for provenance. Client `.log` files were deliberately excluded because they may contain session or login details. No source root `outputs/` artifacts were copied or invented; the source has no such directory. Root report outputs can be generated explicitly if needed.

## Population, dates and identity

- Product: Traditional Chinese Crayon Shin-chan OBT, App18; event source `ta.v_event_18` on ThinkingData Global.
- Cohorts: October 14–17, 2026; observation through October 19, 2026 inclusive. Every included cohort has a complete D3 window.
- Analysis unit: account `fc_id`, not role, device, survey response or session. Identifiers remain strings.
- Registration: the first observed `new_role` over OBT history beginning October 14, selected before restricting cohort dates or platform. This is not proof the account never played in CBT.
- iOS: `os` on that first OBT registration, normalized for whitespace/case. Subsequent events are not restricted to iOS; registration platform defines the account cohort.
- D1 = registration natural day; D2 = registration +1 day; D3 = registration +2 days. SQL uses source partition dates. Configuration records `Asia/Shanghai`, but this case does not independently certify the upstream timestamp timezone.
- Return = `login` or `new_role`. Charge or gameplay alone is not the primary retention definition. Gameplay-only activity is a sensitivity check.
- Main exclusions: account tags `is_water_new` and `is_windows_new` in `user_result_cluster_18`. `internal_users_new` accounts remain in the main population and are excluded separately for sensitivity.
- Accounts absent on D2 but returning on D3, and accounts absent on both, are described separately from the main D2-returning comparison.

## Feature cutoff and interpretation

**All explanatory payment, progression and duration features stop at the end of D2.** D2 gameplay measures use only the second natural day. D3 labels, gameplay-only D3 checks and later-return windows are outcomes or audits, not predictive features. Do not use later observations to explain earlier behavior without explicitly identifying leakage.

- Payment: valid cash USD = `pay_amount / daily exchange rate`, using `ta_dim.ta_exchange`. Exclude sandbox, free-buy and COIN. Validate missing/invalid rates and duplicate charge events. Average across all accounts and average among payers have different denominators.
- Duration: sum adjacent within-account/day non-app event gaps below 120 seconds; retain a 300-second sensitivity measure. This is an event-gap estimate, not exact foreground duration, and does not impute session tails.
- Progression: last observed and highest visible main-stage events before D3. Last observed stage does not mean failed, blocked or last successfully cleared. Stage labels come from `ta_dim.dim_18_0_52765`; configuration order is used instead of subtracting encoded stage IDs.
- Gameplay: D2 event participation, not inferred battle counts. Events lacking `fc_id` use only unambiguous login/registration session mappings; mapping coverage is audited.
- Participation denominators include all D2-returning accounts in each group, including players who may not have unlocked a feature. Associations do not establish causal protection against absence.
- D4–D6 return uses each window's mature cohort denominator. Do not sum unequal windows or interpret D3 absence as permanent churn.

## Directory layout

```text
config.json                     Fixed dates, definitions and external client root
migration_manifest.json         Copy-time file inventory and SHA-256 verification
scripts/
  prepare_queries.py            Generate seven fixed-date SQL queries
  fetch.py                      Serial read-only queries via existing client
  analyze.py                    All-platform aggregation and account panel
  analyze_ios.py                iOS filter, then shared aggregation
  write_report.py               Optional all-platform memo/workbook
  write_ios_report.py           iOS stakeholder memo and verification JSON
  build_ios_excel.py            iOS aggregate Excel workbook and verification
  fetch_survey_bridge.py        Verify cached bridge; --refresh explicitly queries TA
  analyze_survey.py             Pre-D3 account-level questionnaire aggregation
  build_survey_excel.py         Combined behavior/survey workbook and cell verification
sql/                            Seven reusable query definitions (no ID lists)
data/raw/<timestamp>/           Local SQL snapshots, CSVs and metadata receipts
 data/processed/                All-platform aggregate CSVs/JSON and source receipt
 data/private/                  Local all-platform account panel
outputs/                        Optional root outputs; not part of source copy
ios/
  README.md                     iOS-specific definitions and caveats
  data/processed/               iOS aggregate CSVs/JSON and source receipt
  data/private/account_panel.csv  Local iOS diagnostic panel; never publish
  outputs/                      Existing iOS memo, workbook and verification JSON
```

The leading spaces before root `data/processed` and `data/private` above are visual only; both are direct children of the case root. Survey aggregates live under `ios/data/processed/survey/`; its bridge CSV and receipts live under `ios/data/private/survey/`. The role-ID query is `sql/private/survey_role_fc_bridge.sql`. All private directories are ignored recursively. Private panels and raw source data are available locally for reproduction, not as shareable deliverables.

## Environment

Use **Bash** and the existing Windows data-client virtual environment. Do not use the system Python or install another database connector. The existing environment supplies Python, pandas, NumPy and openpyxl. It also contains the established ThinkingData client and its authorized connection setup; credentials and browser state must remain outside this repository.

```bash
cd 'C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/crayon_shinchan/04_surveys_retention/tc_obt_d3_churn_survey_diagnostic_20261020'
export PYTHONIOENCODING=utf-8
export PYTHONDONTWRITEBYTECODE=1
CLIENT_PY='C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe'
"$CLIENT_PY" -c 'import pandas, numpy, openpyxl; print("analysis dependencies available")'
```

`config.json` intentionally points to `C:/Users/5xgames/Desktop/github/fivecross-data-client`. If the machine changes, update that external installation path locally after checking the client environment. Do not replace it with the case path.

## Offline reproduction from copied receipts

No database call or login is required to analyze the preserved exports:

```bash
# Primary delivery: iOS cohort, memo and workbook
"$CLIENT_PY" scripts/analyze_ios.py
"$CLIENT_PY" scripts/write_ios_report.py
"$CLIENT_PY" scripts/build_ios_excel.py

# Questionnaire extension: uses the local survey repository and preserved bridge
"$CLIENT_PY" scripts/fetch_survey_bridge.py
"$CLIENT_PY" scripts/analyze_survey.py
"$CLIENT_PY" scripts/build_survey_excel.py

# Optional independent all-platform baseline and root deliverables
"$CLIENT_PY" scripts/analyze.py
"$CLIENT_PY" scripts/write_report.py
```

Analysis and report commands overwrite their own scope's generated files. Preserve a snapshot if comparing historical outputs. `analyze_ios.py` imports shared logic but redirects generated aggregates and the private panel to `ios/`; it does not replace the all-platform aggregates. Do not run it concurrently with other generators writing the same scope.

The loader chooses the newest hash-valid receipt per query. The iOS wrapper additionally asserts that all seven selected receipts come from one batch. A mixed-vintage selection is a blocker; complete a single full seven-query batch rather than editing receipts to bypass checks.

## Refreshing SQL and source exports (explicit, online operation)

Only refresh when new source access is intended. This is not necessary for migration validation. The fetcher creates task configurations and exports in the **external client** and timestamped raw files in this case; it uses read-only SQL but has local filesystem side effects.

```bash
# If using the established separate local browser profile, keep it outside Git.
export USER_DATA_DIR='C:/Users/5xgames/AppData/Local/hermes/cache/scratch/ta_session_ios_ltv'
"$CLIENT_PY" scripts/prepare_queries.py
"$CLIENT_PY" scripts/fetch.py
# Then rerun the desired offline analysis/report commands above.
```

Never run multiple fetchers against the shared browser session. Keep dates fixed for this delivered case; use a separately named case for another observation window. `fetch.py` accepts optional query stems for diagnosis, but partial refreshes must not be represented as a complete iOS batch.

### SQL inventory

| Query | Role |
| --- | --- |
| `01_cohort_accounts.sql` | First OBT account registration, return labels, D1/D2 payment, exclusions and maturity |
| `02_first_two_day_progress.sql` | D1/D2 main-stage exposure, highest and last visible progression |
| `03_second_day_gameplay.sql` | D2 feature events and unambiguous session-to-account mapping |
| `04_first_two_day_duration.sql` | D1/D2 event-gap duration estimates and session sensitivity |
| `05_stage_dimension.sql` | App18 stage configuration labels |
| `06_event_mapping_audit.sql` | Direct-account coverage, mappability and shared-session audit |
| `07_return_event_sensitivity.sql` | D2/D3 gameplay-only and charge-event sensitivity |

For each successful query the fetcher saves CSV/SQL SHA-256 values, row count, task, local paths, original external export path, completion timestamp and process return code in `.meta.json`. It requires a fresh export, retries serially and rejects results at or above one million rows. Analysis checks those CSV/SQL hashes before loading; source manifests preserve the selected receipts. It also checks account uniqueness, observed D3 maturity, feature keys, valid amounts, bounded durations, mappings and count reconciliation. Failed checks are blockers, not zero-valued results.

## Outputs and sharing

- `ios/outputs/` contains the existing Chinese stakeholder memo, aggregate Excel workbook and JSON verification records. The workbook file name identifies October 14–17 acquisition and observation through October 19.
- Each scope's `data/processed/` contains 15 aggregate CSV tables, `analysis.json` and `source_manifest.json`: group summaries, return funnel, cohort/platform comparisons, D2 gameplay, stage exposure, traits, standardization, later return, sensitivity, mapping and paid-group features.
- `data/private/account_panel.csv` and `ios/data/private/account_panel.csv` are account-level working data. Their presence is needed locally, but they are never public deliverables.
- Root memo/workbook references in the original case README are not evidence that those files existed. The optional root report generator can produce them on request.
- Review all aggregate files for disclosure risk before external sharing; aggregate does not automatically mean anonymous, particularly for small groups. Source manifests expose local paths and should be reviewed for the audience.

## Privacy and repository rules

The case `.gitignore` recursively excludes raw/private account data, account panels, logs, client task configurations, generated ID-list SQL, credentials, login/browser/session state, environments, caches and builds. Generated survey/account-ID SQL belongs under `sql/generated/` or `generated_sql/`, never mixed into the seven generic source queries. Put new account-level linkage outputs under a `data/private/` directory, not `data/processed/`.

Do not print, email or publish `fc_id`, role IDs, contact information, payment/order identifiers, browser cookies, tokens or login data. Do not copy client credential/session folders into this case. A `.gitignore` does not untrack already committed files and is not a substitute for pre-publication review. No `git add`, commit or push is part of this migration.

## Automation and boundaries

This is a manually executed, fixed-date analytical case. **No scheduler, cron job, background refresh, email, dashboard integration or automated publication is installed.** This work does not change other cases, the existing PPT, or the source case. Questionnaire linkage is an additional descriptive analysis, not a causal attribution model.

## Questionnaire identity, timing and denominators

- Inputs are the original Day1/Day2 questionnaire definitions and exports in the specified survey repository. `multiwave.normalize_wave` validates question alignment, actual option codes and known definition issues. This case fails if that loader discards duplicate source responses; earlier eligible submissions would require explicit treatment first. The current sources contain 9,710 and 5,314 role responses, respectively.
- The bridge scans App18 `new_role`, `login` and `charge` from October 14 through October 19. It queries role IDs only, never answers or free text. Of 10,795 requested roles, 10,792 have a unique nonempty `fc_id`; three ambiguous roles are excluded rather than forcibly matched.
- Match to the already-frozen first-OBT-registration iOS account panel. Multiple characters do not multiply an account. Within each wave, choose the earliest submitted eligible response per account. Conflicting multi-role gender or mushroom-experience answers are counted in the quality audit; the primary analysis does not merge inconsistent choices. A first-OBT-role-only sensitivity is provided.
- Questionnaire wave names are not player ages. The primary feature cutoff is submission strictly before registration date +2 days at 00:00, interpreted in Asia/Shanghai, and not before the registration natural day. Thus D3 or later responses cannot overwrite early answers. UTC source submission timestamps are converted by the existing parser. The source event-partition timezone limitation above still applies.
- Day1 pre-D3 coverage is 1,137/13,935 (8.2%) in the absent group and 4,644/21,652 (21.4%) in the retained group. Day2 coverage is 286/13,935 (2.1%) versus 2,598/21,652 (12.0%). Raw any-time coverage is separate. Results cannot be generalized to the nonresponding majority.
- Original export coverage is limited: Day1's last submission is October 17 at 09:40:36 and Day2's is October 18 at 10:53:59, UTC+8. These are not complete questionnaire exports through October 19. Per-registration-date direct standardization adjusts common-date composition but not unobserved response selection or partial-day collection.
- Each option share uses that group's pre-D3 accounts answering that question; multi-select shares may sum above 100%. A missing/conditional answer is not a negative answer. Day1 Q15 branches from satisfaction 1–3, including neutral; Day2 Q20 includes neutral continuation intent. Branch respondents are not all dissatisfied users.
- Gameplay: unplayed share divides by all answers to that gameplay question. Very-fun and negative shares divide by self-reported experienced respondents; negative combines the two explicit negative options. These are not inferred D2 gameplay event participation rates.
- Satisfaction and recommendation use actual valid 1–5 answers. The Day2 definition's recommendation type label says 0–5, but valid options and observed codes are 1–5; this is recommendation intent, not a 0–10 NPS metric. Prior mushroom experience means ever played, not current active status.
- Share differences, lower recommendation and past game experience are descriptive respondent associations. No causal claim or permanent-churn claim is supported. Behavioral selection-bias comparisons show that respondents are more engaged and more often paying than nonrespondents within the same outcome group.

### Survey reproduction and explicit bridge refresh

The three offline commands above verify the preserved bridge, regenerate all aggregate questionnaire CSV/JSON tables, and build `ios/outputs/小新繁體iOS_三日流失與問卷特徵分析_20261020.xlsx` plus the accompanying Chinese memo and `survey_excel_verification.json`. The workbook is read back cell by cell, both native charts are checked, the ZIP is tested, and account/role identifiers are scanned out. It contains no free-text answers or account-level rows.

For an intentionally refreshed bridge only:

```bash
export USER_DATA_DIR='C:/Users/5xgames/AppData/Local/hermes/cache/scratch/ta_session_ios_ltv'
"$CLIENT_PY" scripts/fetch_survey_bridge.py --refresh
"$CLIENT_PY" scripts/analyze_survey.py
"$CLIENT_PY" scripts/build_survey_excel.py
```

This uses the existing data-client environment and task protocol, captures local logs privately, requires a fresh successful export, and stores hash receipts. It does not refresh the seven baseline feature exports. If the questionnaire files or parser change, inspect their recorded SHA-256 values and question semantics before treating a rerun as comparable. If preserved private bridge files are missing, the offline path stops and requires the authorized client refresh; no synthetic mappings are substituted.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Python executable or packages missing | Confirm the external client path and use its existing `venv/Scripts/python.exe`; do not silently switch interpreters. |
| `No verified export` | Check local CSV/SQL existence and SHA-256 receipts. Restore the intended batch or complete a fresh one; never hand-edit hashes to conceal changes. |
| `Mixed export vintages` | Complete all seven queries in one timestamped batch. Partial newest receipts can mix with older ones. |
| Missing/expired TA session | Use the existing client's supported login/recovery flow and local profile; never put credentials in this repo or terminate another user's query. Verify fresh exports after recovery. |
| Empty, incomplete or truncated fetch | Inspect local logs privately, freshness, row counts and receipts. A failed fetch is not an empty population. |
| Unexpected platform/count differences | Distinguish first-registration iOS accounts from all-platform accounts, role-based reports and other cohort dates. |
| Stage or duration interpretation differs | Check the definitions above: last visible event is not failure, and event-gap time is not measured foreground duration. |
| Historical verification points at old directory | These copied JSON records document the original run. Runtime inputs resolve relative to this case; regenerate outputs explicitly for a new verification run. |
| Private data appears in Git status | Stop before staging; check ignore rules and whether files are already tracked. Never publish account-level rows to resolve the warning. |
