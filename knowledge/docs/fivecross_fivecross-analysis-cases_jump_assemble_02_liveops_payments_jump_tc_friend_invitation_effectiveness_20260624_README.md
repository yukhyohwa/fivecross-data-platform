# Jump Assemble TC OBT Friend Invitation Activity Effectiveness

## V3: Active-account coverage, first-week comparison, and registration retention

The current deliverable is `outputs/JUMP_TC_OBT_好友邀请活动成效分析_含注册留存_v3.xlsx`. It contains the full-period active-account coverage, first-week comparison, daily claims, claimant payment segmentation, methodology, registration-retention distribution, and retention numerator/denominator audit sheets. It supersedes the original and v2 workbooks, which are reproducible intermediate outputs and are not retained.

The build chain is `scripts/build_workbook.py` → `scripts/build_coverage_v2.py` → `scripts/build_retention_v3.py`. The corresponding source queries and archived CSV snapshots remain under `sql/` and `inputs/raw/` so the final workbook can be audited and rebuilt.

Full-period coverage uses June 24 00:00 through July 22 05:00 (exclusive). The dedicated first-week sheet uses June 24–30, ending July 1 00:00 (exclusive). Active accounts are distinct accounts with `LOGIN_SUCCESS` or `NUU`, not summed DAU or distinct devices. The primary coverage numerator is the intersection of same-period active accounts and same-period task claimants. All claimants and claimants without matching activity are retained as separate audit columns.

Correction: the original cumulative claim query did not apply the blacklist, unlike its daily and payment companion queries. V2 applies the same `internal_users`, `is_water`, `is_water_mod`, and `suspicious_ip` exclusions to numerator and denominator. Original headline counts are superseded. Own payer rates are recomputed from counts instead of the rounded exported rate. Per-task counts are independent, not a verified nested conversion funnel. Calendar first-week comparison alone does not establish that tasks became harder later.

## Purpose

Evaluate the launch-period friend invitation activity using its verifiable reward-claim records. The activity was live from **2026-06-24 00:00** to **2026-07-22 05:00**. The analysis describes reward-claim reach, milestone progression, claim timing, and the activity-period payment profile of reward claimants.

## Scope and data limitations

No event tracking exists for sending an invitation, accepting an invitation, or the inviter–invitee relationship. Therefore this case **does not claim to measure real invitation conversion, referred-user retention, or exact friend recharge revenue**.

Reward claims are the verified substitute metric:

- An invitation-milestone reward claim proves that the claimant met that configured milestone at the time of claim.
- A friend-recharge reward claim proves only that the system judged the claimant's associated friends to have reached at least that threshold.
- The actual identity, count, recharge amount, and subsequent behavior of those friends cannot be reconstructed from the available tracking.
- Claimant payment is the claimant's own valid `PURCHASE` revenue, not the invited friends' payment.

## Activity design and supplied task IDs

| Task ID | Task | Observable interpretation |
|---|---|---|
| 7010001 | First share of activity page | Claimed share reward |
| 7010002 | Invite 1 friend reaching 150 trophies | Claimed 1-friend invitation milestone |
| 7010003 | Invite 2 friends reaching 150 trophies | Claimed 2-friend invitation milestone |
| 7010004 | Invite 3 friends reaching 150 trophies | Claimed 3-friend invitation milestone |
| 7010101 | Friends' cumulative recharge reaches 200 | Claimed ≥200 threshold |
| 7010102 | Friends' cumulative recharge reaches 600 | Claimed ≥600 threshold |
| 7010103 | Friends' cumulative recharge reaches 1,500 | Claimed ≥1,500 threshold |
| 7010104 | Friends' cumulative recharge reaches 3,000 | Claimed ≥3,000 threshold |

The image also contains an all-invitation completion reward and an invite-code binding task, but no IDs were supplied for them; neither is included in this result.

## Data source and rules

- Source: ThinkingData Global / Trino, `ta.v_event_23`.
- Claim event: `resource_change`, `reason = '任务奖励领取'`.
- ID parsing: `element_at(split(sub_reason, '_'), 2)`.
- Account identity: `COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id, #account_id)`.
- Time window: exact event timestamps from `2026-06-24 00:00:00` (inclusive) to `2026-07-22 05:00:00` (exclusive). `$part_date` is simultaneously constrained for partition pruning.
- Deduplication: account × task ID for cumulative task reach. Daily tables are account × task ID × day.
- Test/water/suspicious user clusters are excluded in the daily and claimant-payment queries.
- Claimant own revenue: valid `PURCHASE`, excludes `SANDBOX_RECEIPT`, and is converted to USD by `payload.curamt / ta_exchange.exchange`. It is ancillary behavior, not friend recharge.

## Directory layout

```text
sql/                         Reproducible TA / Trino SQL
inputs/raw/                  Exported source CSV snapshots
scripts/                     Sequential v1 → v2 → v3 workbook builders and saved query configs
outputs/                     Final v3 workbook and conclusion
```

## Run

1. Execute SQL 01–05 and archive the five exported CSV files in `inputs/raw/`.
2. Run the three builders in order:

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe scripts/build_workbook.py
C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe scripts/build_coverage_v2.py
C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe scripts/build_retention_v3.py
```

3. The builders validate expected source columns and output sheets. The original and v2 workbooks are intermediate files and may be deleted after the v3 workbook passes validation.

## Output workbook

`JUMP_TC_OBT_好友邀请活动成效分析_含注册留存_v3.xlsx`

- **全周期活跃覆盖** — active-account denominator and reward-claim reach.
- **首周对比** — first-week activity and claim coverage.
- **每日领取趋势** — daily unique claimers and event rows.
- **领取者自身付费分层** — claimant cohorts grouped by their maximum claimed invitation and friend-recharge tier.
- **口径与限制** — audit-ready methodology and interpretation limits.
- **注册留存分层** — registration-cohort retention distribution.
- **注册留存分子分母** — inspectable retention numerator and denominator.

## QA checks

- All eight supplied task IDs are present.
- Unique-reach calculations deduplicate at account × task-ID grain.
- The final calendar day is timestamp-truncated at 05:00.
- The workbook sheet names, row counts, and numeric fields are checked after writing.
- No inferred relationship graph, actual invitation count, or exact friend revenue is represented as observed fact.
