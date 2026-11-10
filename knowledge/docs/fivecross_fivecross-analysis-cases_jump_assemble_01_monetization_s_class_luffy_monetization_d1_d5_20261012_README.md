# Jump TC — Luffy first-five-day monetization and competitive performance

## Final deliverables（2026-10-12）

This case now keeps only the final combined report and the evidence needed to reproduce or audit it:

- [15-slide management presentation](outputs/Jump_TC_大路飞_D1-D5商业与竞技表现_含角色来源与时装核查_20261007-20261011.pptx).
- [29-sheet auditable workbook](outputs/Jump_TC_大路飞_D1-D5商业与竞技表现_含角色来源与时装核查_20261007-20261011.xlsx).
- `inputs/manifest.json` and its eight selected raw exports, the final SQL, configuration snapshots and builders.
- [Character-source evidence](all_character_channels/README.md) and [skin-acquisition evidence](skin_audit/README.md), including the compact CSV/SQL/execution records needed by the final builder.

The superseded 13/14-slide reports, predecessor workbooks, render PNG caches, query logs, generated task files, duplicate raw exports and exploratory channel-audit files were removed. They are not final deliverables. Actual confirmed skin IDs remain Luffy `117001` and Minato `126001`; the other six characters stay unconfirmed rather than being reported as zero. The original Trunks case and shared weekly-report configuration were not modified.

All eight queries were rerun through the established client on **2026-10-12**, with final exports between **10:10 and 10:12 local time**. No old D1–D3 or D1–D5 business exports were reused. An earlier malformed coverage-query attempt returned exit code zero without a CSV; it was repaired and rerun. Only the final working query and manifest-selected batch underpin the report; earlier same-day duplicate exports were removed during final cleanup.

## Confirmed launch and complete first-launch roster

The authoritative configuration is `C:/Users/5xgames/Desktop/github/jumptw-weekly-report/config/report.yaml`. Its event dictionary is copied into `inputs/config/events.json`; the filtered, deduplicated S-grade, `times=1` roster is in `inputs/config/campaigns.json`.

**Luffy (大路飞) launched on 2026-10-07**, card ID **117**, pool ID **110**. Query 00 independently found its first observed pool event at **2026-10-07 05:00:29.508**. This timestamp is retained in source time; no unverified timezone conversion is claimed. The configuration date and observed partition start agree. The five complete natural days are **October 7–11**, excluding the partial October 12 partition.

| First-launch S character | Card ID | Pool ID | D1 | D5 |
|---|---:|---:|---|---|
| 五条悟 | 145 | 101 | 2026-06-24 | 2026-06-28 |
| 佩恩 | 144 | 102 | 2026-07-15 | 2026-07-19 |
| 西索 | 136 | 103 | 2026-07-29 | 2026-08-02 |
| 波风凑 | 126 | 104 | 2026-08-12 | 2026-08-16 |
| 朽木白哉 | 164 | 105 | 2026-08-26 | 2026-08-30 |
| 香吉士 | 119 | 107 | 2026-09-09 | 2026-09-13 |
| 特南克斯 | 163 | 108 | 2026-09-23 | 2026-09-27 |
| 大路飞 | 117 | 110 | 2026-10-07 | 2026-10-11 |

The old comparison omitted **西索**; this case restores it. Gojo and Pain reruns are deliberately excluded from this **first-launch-only** comparison, not substituted for first launches. The observed earliest date agrees with configuration for every listed pool. Query 00 scans June 24–October 11; it verifies starts within that bounded history, not all possible pre-launch testing history. Later pool events can persist beyond configured event ends; only the requested first-five-day windows are used.

## Principal findings

Luffy D1–D5:

| Metric | Result |
|---|---:|
| Window-unique active players | 13,174 |
| Window-unique pool participants | 1,874 |
| Participation rate | 14.2% — seventh of eight launches |
| Target-pool draws | 74,140 |
| Draws per participant | 39.6 — first of eight launches |
| Holders, latest available window snapshot | 1,185 |
| Holder coverage among active players | 9.0% — first of eight launches |
| At least one awakening | 440 |
| At least three awakenings | 280 |
| Three-awakening completion among holders | 23.6% |
| Average positive awakening count among holders | 0.90 |
| All daily-active purchase revenue | USD 55,682.64 |
| Same-day participants' purchase revenue | USD 28,490.38; 51.2% of active-player revenue |
| Participants' paid-star consumption share | 52.6% |
| Ranked qualified hero appearances | 2,593 |
| Ranked win rate / full-roster rank | 51.6390% / 12 |
| Ranked MVP rate / full-roster rank | 51.4848% / 5 |

High ownership coverage is not equivalent to high awakening depth. Low broad participation and high draws per participant can coexist. Revenue and currency consumption describe participant segments, not causal incremental revenue or direct pool attribution.

## Data source and metric contract

- Product: Jump Assemble Traditional Chinese / TC.
- Engine: ThinkingData Global / Trino, `ta.v_event_23`.
- Existing execution environment: `C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe`.
- Account identity: `COALESCE(fc_sdk_common.lcx_id,sdkcommon.lcx_id,#account_id)`.
- Business exclusions: `internal_users`, `is_water`, `is_water_mod`, `suspicious_ip` from `user_result_cluster_23`.
- Revenue: PURCHASE, excluding sandbox receipts; subtract matched free-wallet amount from `ta.v_event_16`, divide by daily exchange rate from `ta_dim.ta_exchange`, and retain the validated purchase-payload adjustment. Revenue is USD, not star units.
- Cumulative recharge segmentation ends at each character's own D5. All eight campaigns use the same five-day cohort, draw, purchase and snapshot boundaries.
- Window-active users logged in at least once in D1–D5. Window draws include their target-pool draws on days without a recorded login. Daily metrics intersect each day's login cohort. Therefore window draws need not equal the sum of daily-login-intersected draws, and sums of daily unique counts are player-days, not unique users.
- Holders use each account's last available target-card snapshot inside the window, not a guaranteed simultaneous D5-end census. Holder coverage divides by window-active users. Awakening depth counts positive array entries, treating null as zero. Awakening completion divides by holders. Ownership is not restricted to pool participants: the active/participant/holder table is not a strict nested conversion funnel.
- Participant payment rate uses **participant payer-days / participant-days**. Participant revenue share uses **participant purchase revenue / all active-player purchase revenue**.
- Paid-star share uses **participant paid-star consumption / all active-player paid-star consumption**. The resource event is `resource_change`, `gu_type=2`, paid star `id=3`; free star `id=8` is reported separately. Neither payment amounts nor payer counts nor draws are the star-share denominator. All participant revenue/star segmentation is same-day participation and login intersection.
- The legacy `pity_draws` field retained in raw query 01 is unused metadata from the reference template, not a newly verified guarantee for Luffy. No presentation conclusion or comparison depends on it.

## Competitive contract

The competitive window is exclusively **2026-10-07 through 2026-10-11**. Fresh query 06 verifies positional alignment of `hero_id_list`, `hero_level`, `card_awake` and `card_super_slot` on observed `arena_fight` samples. Qualification is human-only matches (`robot_num=0` or null), hero level at least 8, at least one positive awakening element and at least two positive talent elements. Combat inherits these reference gates; it does not apply the commercial account blacklist.

Ranked `model_type=2` aggregates across game types. All **36 qualified heroes** receive separate full-roster win-rate and MVP-rate rankings before the **13 key-event A/S heroes** are selected for display. Ranking uses unrounded rates, then appearance count descending and hero ID ascending. Display rounding can show identical percentages for different original ranks.

Brawl `model_type=5` ranks all heroes within each mode first, then selects the five highest-ranked event A/S cards. There is no post-filter reranking. The source contains 13 brawl modes; the explicitly excluded `game_type=8` remains only in raw source data. All **12 other observed, mapped modes** are published, totaling **60 rows**:

| Game type | Confirmed Chinese name |
|---:|---|
| 1 | 卷轴争夺 |
| 2 | 单人乱斗 |
| 3 | 双人乱斗 |
| 4 | 武道会 |
| 5 | 积分争夺 |
| 7 | 咒术高专 |
| 9 | 顶上战争 |
| 10 | 无限列车 |
| 11 | 淘汰赛 |
| 12 | 忍界大战 |
| 15 | 龙珠之争 |
| 16 | 爆破对决 |

Names and win logic are confirmed against `fivecross-sql-lib/games/jump_assemble/trino/ja_tc_arena_mvp_svp_stats.sql`. Solo brawl placements 1–4 win, duo brawl placements 1–2 win; other published modes use placement 1. The obsolete weekly-query forced-zero rule is not used. No minimum sample threshold is imposed; small samples must be interpreted cautiously. Appearances are hero appearances, not unique players.

## Query inventory and verification

| SQL | Purpose | Final rows |
|---|---|---:|
| 00_event_discovery.sql | Bounded live pool start-date verification | 229 |
| 01_daily_pool_metrics.sql | Eight campaigns × five days | 40 |
| 02_pool_participation_by_recharge_tier.sql | Eight campaigns × six recharge tiers | 48 |
| 03_pool_holder_awakening.sql | Last available snapshots and progression | 8 |
| 04_battle_hero_metrics.sql | Full-roster combat ranks, including raw excluded-mode rows | 503 |
| 05_matched_coverage.sql | Independent 40 daily + eight window checks | 48 |
| 06_array_sample.sql | Fresh combat-array samples | 5 |
| 07_participant_payment_stars.sql | Daily participant payment and star-consumption denominators | 40 |

Verified:

1. Each task produced a CSV newer than its execution start; process exit zero alone was not accepted.
2. All eight campaign starts agree with observed pool events; all 40 date cells equal exact D1–D5 dates.
3. Independent query 05 matches daily and window active counts, participants and draw totals; tier totals match snapshot cohort totals.
4. Query 07 daily revenue/payer/active totals reconcile with query 01; precision-correct rates reconcile to integer counts.
5. Both win and MVP rankings independently reconstruct from exact count fractions across all 14 ranking groups.
6. Every observed mapped brawl mode except the excluded mode is present; all 60 filtered Top5 rows retain source ranks.
7. The final XLSX reopens with 29 sheets and the final PPTX with 15 slides; ZIP integrity and retained-sheet/slide checks are recorded in `skin_audit/verification.json`.
8. Microsoft PowerPoint rendered the final report during validation. Rendered PNGs were review caches and were removed after the visual checks passed; `skin_audit/render_verification.json` retains the verification result.

## Reproduction

Run from this case directory in Git Bash on the existing Windows environment:

```bash
PY='C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe'
"$PY" scripts/prepare_stars.py
"$PY" scripts/run_queries.py
"$PY" scripts/collect.py
"$PY" scripts/build_case.py
"$PY" scripts/verify_final.py
```

`run_queries.py` registers uniquely named `luffy_case_00`–`luffy_case_07` tasks without changing Trunks tasks. Queries execute serially because the browser-backed IDE session is shared. Generated task files and logs are temporary and are not retained after a validated build. `collect.py` deliberately asserts this historical case's 2026-10-12 export date: a future refresh must explicitly update the vintage check rather than quietly accepting old CSVs.

Render using `scripts/render.ps1 -InputFile <absolute PPTX> -OutputDir <absolute existing-or-new directory>`. An ASCII scratch copy avoids Windows PowerShell path-encoding issues. The script closes only its opened presentation and releases COM references without quitting a user's PowerPoint application.

## Limitations and unresolved interpretation

No execution blocker remains for the requested report. Remaining analytical limitations are explicit: snapshots are last available, not synchronized; launch timestamps retain source timezone semantics; revenue and stars are segment-level rather than direct pool attribution; no causal counterfactual or minimum combat sample threshold is introduced. The September 9 first-top-up double-reward promotion and changing population size are not controlled away by matching first-five-day windows. Raw pity metadata is not revalidated or interpreted. No Git commit/push or shared weekly-report edit was performed.
