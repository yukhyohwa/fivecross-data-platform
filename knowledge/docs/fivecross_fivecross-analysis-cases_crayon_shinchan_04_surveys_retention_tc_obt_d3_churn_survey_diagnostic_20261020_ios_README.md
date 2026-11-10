# Traditional Chinese Shin-chan: iOS Third-Day Absence Diagnostic

## Purpose and scope

This temporary analysis investigates why players who return on their second natural day do not return on their third. The primary comparison is **D2 return / D3 absence** versus **D2 return / D3 return**, not all players missing D3. The analysis describes observed associations; it does not establish causes or permanent churn.

- Product: Traditional Chinese OBT, ThinkingData Global `ta.v_event_18`.
- Acquisition cohorts: October 14–17, 2026; observation ends October 19, 2026, inclusive, using completed event partitions.
- Population: accounts (`fc_id`) whose first OBT `new_role` has `os=iOS`; select the first registration before filtering platform. This is an OBT-entry definition, not a claim that the account has never played in CBT.
- D1 is registration day; D2 is registration +1 natural day; D3 is registration +2 natural days.
- Return events: `login` or `new_role`. Gameplay-only D3 activity is audited separately.
- Platform is fixed at registration; later events are not platform-filtered.
- Exclusions: `is_windows_new`, `is_water_new`; internal accounts are retained in the main result and excluded in sensitivity checks.
- Revenue: valid cash only, `pay_amount / daily exchange rate`; exclude sandbox, free-buy and COIN. All monetary features stop at D2.
- Date semantics use the source partition date. The analysis does not independently certify the source timestamp timezone.

## Deliverables and structure

```text
ios/
  README.md
  data/processed/       # Audited aggregate CSVs, analysis JSON and source manifest
  data/private/         # Local account-level diagnostic panel; never attach publicly
  outputs/              # Chinese stakeholder memo and verification JSON
../sql/                 # Seven source queries shared with the all-platform case
../data/raw/<batch>/    # Fresh SQL snapshots, exports, hashes and query logs
../scripts/
  fetch.py              # Established serial data-client runner
  analyze.py            # Shared validated cohort/feature aggregation
  analyze_ios.py        # iOS account filter applied before all aggregations
  write_ios_report.py   # Chinese business-facing memo
```

## Execution

Use the existing data-client virtual environment. Do not install or configure another database connector. Commands below assume the case root is the working directory and Bash is the terminal shell:

```bash
export USER_DATA_DIR='C:/Users/5xgames/AppData/Local/hermes/cache/scratch/ta_session_ios_ltv'
export PYTHONIOENCODING=utf-8
'C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe' scripts/fetch.py
'C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe' scripts/analyze_ios.py
'C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe' scripts/write_ios_report.py
```

The scripts depend on the existing client environment, pandas and numpy. Source exports must all come from one completed timestamped batch. Analysis checks CSV/SQL hashes, account uniqueness, mature D3 coverage, amount validity, bounded durations, stage mappings and count reconciliation. Failed or partial batches must not be reported as complete. Preserve the fixed-date configuration; new dates require a separately named run.

## Interpretation

- Average spend for all group members and average spend for payers have different denominators and are reported separately.
- Duration is an event-gap estimate, not exact foreground time: accumulate adjacent within-account/day event gaps below 120 seconds; retain a 300-second sensitivity measure and do not impute session tails.
- Terminal main stage means the last observed main-stage event before D3, not the last successful clear or a demonstrated failure. Maximum progression is reported separately.
- D2 gameplay participation uses all D2-returning members of each comparison group as its denominator, including players who may not have unlocked the feature. Participation alone does not establish causal protection against churn.
- Later-return windows have different maturity-eligible denominators. Do not add them or interpret D3 absence as permanent churn.
- Account counts and this four-date population differ from earlier first-day role-based LTV slides.

## Privacy, automation and troubleshooting

Keep account-level raw/private files local and Git-ignored. Share the aggregate memo, not account identifiers or payment records. No scheduling, dashboard integration, PPT changes or Git publishing is part of this request.

If a TA session expires, allow the existing client's automatic fresh-login recovery to finish; verify a new export afterward. Do not kill another query or clear another session. A mixed-vintage assertion requires completing one full seven-query batch before re-running analysis. Empty/missing source exports and incomplete observation windows are blockers, not zero-valued results.
