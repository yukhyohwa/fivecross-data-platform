# Crayon Shinchan TC — Activity Comparison Review

## First read: reusable activity rules (2026-11-06)

[Activity rules and key timetable — Chinese business reference](docs/ACTIVITY_RULES.md) is the priority entry point for future rule reuse; [machine-readable JSON](reference/activity_rules_reference.json), [CSV](reference/activity_rules.csv), and [user confirmation](docs/ACTIVITY_RULES_CONFIRMATION.md) preserve field-level unknowns and evidence. The reference covers all eight configured comparison activities plus camping and its fishing/blind-box children (11 entries), with a code-reconciled full workbook-cell inventory.

**Superseded for future use:** camping starts on the confirmed natural date **2026-11-04**, not server D22. The date is confirmed; exact switch times and end date are unknown. Children inherit timing only, with independent switches unconfirmed. This overrides the historical camping/fishing D22–D28 statements below and the frozen active configuration for future interpretation; it does not revise historical metrics. Other current-case activities retain server-age rules. No end date is inferred from the old seven-day span.

Read the rules before any future query. Re-query only when needed for an actual analysis request, not on every reference use. Update Excel/PPT only on explicit user instruction. The reference schema is **not wired into the running report config**. All original English sections remain below as historical provenance. Offline reference-only commands: `python scripts/activity_rules.py build` (Markdown/CSV only), then `python scripts/activity_rules.py validate` (read-only). Neither runs a report build or accesses the database.


Current case: `C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/crayon_shinchan/02_monetization_liveops/activity_comparison_review_20261030`. Current scripts resolve inputs from this case root; historical receipt paths remain unchanged as provenance.

## Current report

[November 4 operations presentation](outputs/小新繁体_消费去向与活动效果_运营汇报版_20261104.pptx) covers daily spending, four calendar weeks, activity comparisons, Monopoly composition, the fixed launch-week cohort, and a new fishing participation/bait/bundle page. It contains **nine slides: the preserved user cover plus eight analytical pages**. The October 31 presentation remains byte-identical and is not overwritten.

Fixed exclusive event cutoff: **2026-11-04 16:58:14 Asia/Shanghai**. The actual system clock at freeze was `2026-11-04T16:58:14.581993+08:00`, matching the requested date. All 17 source/control queries were executed against that event-time bound; source timestamps are not additionally converted. This is an event-time-bounded refresh, not a transactional database snapshot: current labels and dimensions are re-read during extraction. W1=October 14–20; W2=October 21–27; W3=October 28–November 3, complete; W4=November 4 through cutoff, partial. W4 is never folded into W3.

**Existing user edits preserved:** the eight-page source/template SHA-256 remains `711a22dc9702b15c55505f21c79d57f8715d1a66809ed4413d3dfa185a4ad959`. The user cover, layout and cumulative comparison scope are retained. Its cover date remains **2026.10.30**, and its title still says second week; both are preserved user artwork, not the refreshed data cutoff. Data-dependent ranks and conclusions are updated rather than preserving obsolete rankings. The cumulative title retains the user's “整个活动周期” wording, but the adjacent note explicitly describes cutoff-limited, unequal and ongoing windows; it does not certify completed cycles.

Offline build regenerates metrics/charts into `verification/latest/rebuilt.pptx`, renders every page through PowerPoint COM, checks independent source controls and per-server FC unions, and compares the candidate against the approved final without overwriting it. Cover content and original/template/workbook hashes are protected. Rebuilt ZIP hashes may vary; the current delivery hash is recorded in `verification/latest/package_validation.json`, not inferred from a filename.

## Directory map

| Path | Purpose |
|---|---|
| [scripts/current/](scripts/current) | Current build, classification, server-window calculation, rendering, verification and opt-in fetch |
| [config/](config) | `refresh.json` is the active cutoff/path contract; `fishing.json` defines the child activity; `schedule.json` holds workbook provenance. |
| [templates/](templates) | Current user-edited presentation template, not an old deck chain |
| [sql/current/](sql/current) | Twelve retained baseline query bodies plus five fishing/identity queries; fetch binds one explicit cutoff and saves exact executed SQL |
| `data/raw/20261104/` | Seventeen newly queried canonical CSVs, receipts and `sql/` executed SQL; private/ignored. |
| [outputs/](outputs) | Current deliverable and independent-work exceptions |
| `verification/latest/` | Derived data, candidate deck, COM renders/checks, manifests and cleanup validation; private/ignored |
| [docs/DELIVERABLES.md](docs/DELIVERABLES.md) | Current selection and exceptions |

The original supplied workbook, current Nov4 report, required Oct31 template/report, active scripts, SQL, configs and Nov4 source evidence are retained. Superseded inputs and unrelated historical extensions were removed; exact deletion records and protected-file hashes are in `docs/final_only_cleanup.json`.

## Exact sources and filters

ThinkingData global **App18**: `ta.v_event_18`, `ta_dim.dim_18_0_52801`, `ta_dim.ta_exchange`, `user_result_cluster_18`. The retained SQL is authoritative and receipt-hash checked.

- Cash: positive charge, nonblank FC; exclude sandbox, freebuy, COIN, `is_water_new`, `is_windows_new`; **retain internal users**. Validate finite amounts and positive nonconflicting daily FX; source currency→USD→TWD once.
- Crystal shop: item10206 in `shop_item[1]`, positive quantity, product through `shop_id`; raw/100 once. Exclude blank FC, water, Windows and `internal_users_new`.
- Direct summons: positive item10206 balance debit, eligible reward within0–2 seconds by FC/role/server; one ranked attribution per debit; exclude positive shop payments within±2 seconds. Preserve exact type/ID. This is bounded event matching, not a proven transaction FK.
- Login/cohort contracts follow their exact SQL. Opening anchors exclude blank FC/server, water, Windows and internal tags. No minimum15-character FC filter is added to report revenue/logins.
- Consumption equivalent = cash TWD + crystals at approved1:1, excluding funding/top-up/conversion. **Not financial net revenue or causal uplift.**
- Payers are cross-server/product/channel FC unions; active denominator is same-window eligible login union, not summed DAU. **Payer rate**=eligible joint payers/login union, not payer-login intersection. Fishing **participation rate**=child reward claimants/login union. Payer depth=amount/joint payers. No FC-length restriction is applied to revenue or login populations.
- Monopoly=self-select+fashion118601; privilege cards belong to privileges/monthly cards. Giftbox shared SKUs use approved disjoint configured server windows, not buyer reward gating or an invented instance FK.

## Schedule and natural D1

Use exactly sheet **活動排期_obt調整版**. D1=each server’s first eligible new_role natural date, resetting at midnight. D(a)–D(b) window is `[open_date+(a-1), open_date+b)`, clipped to cutoff. First-two-day comparisons require `start+2 days <= cutoff`; cumulative excludes unstarted servers and distinguishes ongoing/ended. Union FCs over eligible server windows.

Roster: mount D2–7; Xiaobai D1–7; Xiaokui/party D8–14; giftbox1 D9–11; giftbox2 D15–17; skill/Monopoly D15–21; fishing D22–28. The fishing schedule is inherited **only** from the camping-parent cells `J23:J29`; participation and products never inherit the parent's scope. `主題-野外露營!N23:O23` identifies child configuration `1074001 / 垂钓奇遇`. The schedule sheet has no merged ranges; the child sheet has `E9:F9`, unrelated to this mapping. The validator reads original OOXML without saving, checks all occupied days plus adjacent boundaries, and verifies the workbook hash. Historical absolute-date comments do not override user-confirmed server-age semantics.

### Fishing metric contract

- Reward participation: `active_reward`, `type=1074`, `name='垂钓奇遇'`; no hard-coded instance ID. Daily FC distinct; period FC union, never summed daily UV. Raw instance observations remain in `fishing_instances.csv`.
- Bait: item **10245**, `item_change.type=2`, `change_source=43`, actual positive `before-after`. Quantity is resource consumption, **not certified fishing operations**. No item10268 or reward-array count substitution. Bait-to-child-reward existence is checked on FC+role+server within 0–2 seconds, without multiplying bait rows by reward matches.
- Products: deduplicated dimension IDs satisfying exactly `product_name_tc LIKE '%垂釣%'`; no simplified-name expansion and no whole camping-family bundles. The fresh mapping contains 12 IDs. Product-name conflicts are blocked before downstream attribution.
- Cash keeps internal users, excludes water/Windows/sandbox/freebuy/COIN, and requires valid positive amounts. Crystal shop additionally excludes internal users, uses payment10206 and `num/100` exactly once. Cash source-currency FX and same-day TWD FX are validated and deduplicated; missing/conflicting rates are errors, not zero revenue.
- The topic page separately shows all actually observed activity and the eligible configured-window subset. Both are real actuals, not targets. Their populations differ. Observed and configured user counts are not additive: cross-server FCs may overlap. Fishing has **zero mature first-two-day servers** at this cutoff; its first-two-day comparison row is explicitly unavailable, not zero performance.

## Offline commands — actually exercised

Run from this case in Git Bash. Exercised interpreter: `C:/Users/5xgames/AppData/Local/hermes/hermes-agent/venv/Scripts/python.exe`; pandas, NumPy, matplotlib, python-pptx, Pillow, pywin32. Windows PowerPoint and Microsoft YaHei are required for COM rendering. Shared query environment was not modified.

```bash
python scripts/current/run.py build
python scripts/current/run.py verify
python scripts/current/run.py refresh-help
```

Build is offline: it recomputes, renders and verifies a candidate in `verification/latest/rebuilt.pptx`, comparing its visible text/tables with the approved November 4 output. It never overwrites any approved delivery or queries the database. A different candidate fails validation rather than replacing user edits. Individual entry points remain available:

```bash
python scripts/current/build.py
python scripts/current/render.py
python scripts/current/verify.py
python scripts/current/verify_package.py
python scripts/current/fetch.py --help
```

Verified November 4 source: **102,383 payment groups; 548,937 login groups; 185,421 registration groups; 62 server anchors; 139,143 fixed launch-week accounts; 18 activity comparison rows**. Independent cash and payment-identity controls reconcile: 81,871 cash events and 21,535 crystal-shop events have no missing or repeated source event IDs. Consumption is **30,677,049.39 TWD equivalent**. Configured Monopoly totals **513,624.23**, 176 joint payers and 12,016 logins. The cohort changed from the previous snapshot's 139,144: no added accounts, one removed account now carrying `is_water_new`. Fresh membership is independently reconstructed from registrations and current labels, not forced to the old count.

Fishing actually observed: **2,619 claimants; 78,583 bait; 30.00 bait per consumer; USD4,994.62 cash; 578,015 crystals; TWD741,578.80 consumption equivalent; 72 joint payers** (44 cash, 47 crystal; overlapping). All 78,583 eligible bait events have a child-reward match within 0–2 seconds. The first eligible log is **November 4 00:01:50.029**, not November 1; the attachment's November1–4 probe range is not a first-observed timestamp. Configured eligible subset: 19 started servers, 893 claimants, 46,219 bait, 2,446 logins, 32 joint payers and **TWD334,779.77**. The original cover warning remains disclosed; all eight analytical pages pass COM text-height and table-bound checks.

## Reusable live refresh — exercised on November 4

Authorized shared client: `C:/Users/5xgames/Desktop/github/fivecross-data-client`, its `.venv/Scripts/python.exe` and existing global `.env`. Credentials stay outside the case. Serial queries handle downloaded-file responses and reject the million-row cap.

```bash
'C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe' scripts/current/fetch.py --execute activity_names_dates_payments registrations server_registrations tags rates products instances logins payment_controls login_controls registration_controls cash_controls fishing fishing_controls fishing_instances payment_identity_controls fishing_payment_controls
```

First read the actual Beijing clock and freeze one exclusive event cutoff in `config/refresh.json`, with a new dated raw directory and output path. Fetch binds the retained Oct31 query-body bounds and the new query placeholders to this cutoff, saving the exact executed SQL alongside every fresh export and hash receipt. Keep the full bounded OBT extraction; do not append overlapping partial-day aggregates. Run sources serially. The existing client successfully cleared an expired session and automatically reauthenticated; no credentials are copied into this case. Reject million-row exports and reconcile source controls before build. For future weeks beyond W4 or a changed activity roster, extend the explicit chart/eligibility logic and re-review it rather than assuming a date edit is sufficient.

## Timing anomalies

Fresh prestart consumption remains unresolved: skill **289,242.00**, Monopoly **365,723.28**, and fishing **406,799.03 TWD equivalent**. Fishing has 43 not-yet-started servers with 1,727 claimants and 32,364 bait already observed; these records are excluded only from configured comparisons, not whole-game/fixed-cohort spending. One claimant overlaps the configured and prestart populations across servers. The giftbox family additionally has **126,690.23 TWD equivalent** outside the two selected configured periods; it remains in whole-game totals and is visibly disclosed rather than forcibly allocated. Source amounts reconcile to inside+outside. These timing differences are quantified anomalies, not explained-away errors or permission to remove legitimate consumption.

## Cleanup - final dependencies only

Removed 156 obsolete files (203.74 MiB): old private/export/receipt branches, Oct31 raw inputs replaced by the Nov4 extracts, unrelated historical extension outputs/evidence, obsolete regression configs and cleanup/runtime logs. Current input, script, template and final-report hashes were checked unchanged. The current offline verify command passed after cleanup, including all 17 source receipts and preserved final-report content. See `docs/final_only_cleanup.json` for exact paths and reasons.

## Independent activity supplements — archive integration

These additions preserve the existing report, all previous README sections, official metrics, templates and active configurations. They do **not** refresh the database or publish a new presentation. The earlier final-only cleanup describes the historical cleanup; the explicitly selected supplements below are now retained independent exceptions.

| Sub-activity / path | Archived scope and relationship to the official pipeline |
|---|---|
| [Fishing daily dashboard](sql/dashboards/fishing_daily.sql) | Exact bytes of the user-supplied latest SQL. Recurring type1074 + name `垂钓奇遇`, item10245 type2/source43, exact `%垂釣%` products. A standalone ThinkingData dashboard, not a replacement for `sql/current/fishing.sql`. Fishing was **already wired into** the November4 report's source queries, classifier, configured comparisons and topic page; this dashboard and earlier probe aggregates were previously missing from the case. |
| [Blind-box daily dashboard](sql/dashboards/blind_box_daily.sql) | Exact latest scratch SQL, item10159 魔法棒 and exact `%盲盒禮包%` products. Runnable macro SQL with **participation count and rate NULL**. **Not wired into the official PPT fetch/classification/comparison pipeline.** |
| [Probe SQL](sql/supplements/blind_box) and [probe evidence](evidence/supplements) | Selected aggregate CSVs and allowlisted receipt provenance for blind-box and fishing. No browser state, original raw receipts, account rows or sample payloads. Historical probe dates are not report cutoffs or release dates. |
| [Camping / party D1–D2 branch](evidence/supplements/camp_d1d2) | Independent November5 same-clock spending, repeat-purchase, baseline and calendar-versus-server-age analysis. Its original [offline analyzer](scripts/supplements/camp/analyze.py), [bounded SQL](sql/supplements/camp_d1d2) and nine verified aggregate outputs are retained. **Not merged into official November4 report metrics or slides.** |
| [Supplement validator](scripts/supplements/validate.py) and [manifest](docs/activity_supplements_manifest.json) | Offline SQL parse/contract checks, aggregate schemas/counts/hashes, historical receipt CSV binding, source-copy hashes, optional isolated complete camp replay, and protected report/config/metric hashes. |

### Dashboard use and metric limitations

Paste one dashboard SQL into the authorized App18 ThinkingData SQL dashboard and configure `${PartDate:date}` as the date predicate. These queries are not plain unbound Trino SQL; the validator binds a fixed probe date solely for parsing. They have no dependency on `config/refresh.json`, and their daily USD/crystal columns are not the PPT's configured-window TWD-equivalent comparison rows. Channel payer counts must not be added.

Both dashboards retain internal users in cash while excluding water/Windows/sandbox/freebuy/COIN; crystal purchases additionally exclude `internal_users_new` and divide raw item10206 quantities by100 once. Cash has positive, nonconflicting daily source-currency exchange rates; missing/conflicting FX yields NULL, not zero. No minimum FC-length rule is introduced.

Blind-box item10159 is explicitly described by the dimension as a blind-box resource that converts to12000 coins at event end. The current query counts **all-source positive item decrements**, potentially including conversion; it does not certify draws or successful openings. The bounded type2/source43 observation is **not a proven blind-box reward mapping**: the saved control found no subsequent same-FC/role/server active_reward link within0–2 seconds. No verified active_reward type/name was discovered. Participants and participation rate therefore remain NULL, never replaced by resource consumers or camping-parent participation. Blind-box is not added to the formal activity comparison.

Fishing retains exact child reward participation rather than camping-parent activity. Item10245 quantities are resource consumption, not certified fishing operation counts. Its inherited server-age schedule versus actual observations remains unresolved; this archive does not alter that configuration or the current first-two-day maturity status.

### Reproducible validation and observed status

```bash
uv run --with sqlglot==30.29.0 python scripts/supplements/validate.py
# Optional full offline replay against authorized original inputs, never a live query:
uv run --with sqlglot==30.29.0 --with pandas --with numpy python scripts/supplements/validate.py --replay-source C:/Users/5xgames/AppData/Local/hermes/cache/scratch/camp_diag_20261105
python scripts/current/run.py verify
python scripts/current/run.py refresh-help
```

Actually exercised: supplement validation **PASS**, 51 archived manifest files, 18 parsed SQL statements, 2,290 aggregate CSV rows, and all nine camp outputs compared row-by-row after a real isolated offline analyzer run using seven hash-checked external inputs. Payment controls reconcile during that replay. Existing `run.py verify` and `refresh-help` both passed using the existing Hermes Python environment; 17 formal source receipts and18 activity rows were verified. The existing cover warning remains. No build/render or live refresh was requested or run; existing candidate content was verified against the approved final. All88 protected baseline files, including both delivered PPTs, template, workbook, official SQL/config/scripts, raw sources and formal metric CSV, remain unchanged.

The blind dashboard body, after date binding, exactly matches the archived historical November4 validation SQL; its saved CSV hash and row count match the historical receipt, and resource totals reconcile to the separate control. This is stronger than a string-only SQL check but **not a fresh live execution**. Historical receipts do not bind SQL hashes, so original execution provenance is not cryptographically authenticated. Fishing's earlier executed probe SQL no longer exists at its receipt path; the preserved historical aggregate is not claimed byte-equivalent to the latest supplied dashboard. Parsing cannot prove warehouse permissions, current schema compatibility or complete participation metrics.

Full camp replay intentionally requires original authorized inputs whose paths, hashes, row counts and schemas are indexed in the manifest. Account-level payment/login aggregates and original receipts are **not copied to the public package**. The wrapper copies dependencies temporarily under ignored `private/activity_supplements/`, constructs allowlisted local hash receipts, compares all rows, then deletes temporary account data. Without those external inputs, the portable default verifies aggregate contracts and integrity only, not a full reconstruction of payer cohorts. Do not run the archived analyzer directly: its output directory is its own script directory. Use the wrapper.

Validation output lives at ignored `private/activity_supplements/validation.json`. Original scratch files remain untouched. The new archive is independently versionable but no git commit/push was performed. See [supplement provenance and exclusions](docs/ACTIVITY_SUPPLEMENTS.md) for source inventory and boundaries.

## Privacy and troubleshooting

- Raw data, receipts/count/hash ledgers, account-level derived files, cleanup manifests, sessions and supplied workbook are gitignored. Ignored inputs still need authorized backup.
- Receipt export paths are provenance, not runtime dependencies; timestamp duplicates were removed only with canonical data retained.
- Missing inputs: recover matching authorized sources, never substitute another vintage or fabricated records.
- Hash mismatch: inspect actual user edits before changing expectations; never revert cover/title to satisfy an old hash.
- Workbook style failure: use OOXML, never resave the original with openpyxl.
- Metric mismatch: check cutoff, funding, internal-user asymmetry, server eligibility and FC-union denominators.
- Rendering: use installed Windows PowerPoint, native paths and the exercised interpreter. Analytical overflow fails; preserved cover warnings remain explicit.
- Git updates are performed only when requested; private inputs and runtime caches remain ignored.
