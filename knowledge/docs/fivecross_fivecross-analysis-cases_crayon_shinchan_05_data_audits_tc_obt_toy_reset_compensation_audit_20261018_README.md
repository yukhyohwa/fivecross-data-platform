# TC OBT Toy Reset Compensation Audit

## Purpose and status

This standalone live-operations/customer-support case investigates a reported toy-reset material loss for the role initially found with the exact nickname predicate `role_name LIKE '%3EB7AD'`. It is not a survey report, a production KPI integration, or a compensation-disbursement tool.

**Live queries and local reconciliation completed.** The screenshot-based 100% potion-refund rule yields a recommended shortfall of **2,006 × Toy Remote / 玩具遥控 (`390001`)**. Both identified resets consumed the reset potion (`10053`), so the evidence does **not** support the initial hypothesis that the player chose the wrong reset payment method. Advance materials were returned in full. No red diamonds or reset potions are recommended for reimbursement on the available evidence.

The result is a recommendation, not proof of the server-code root cause. The reset resource rows contain no toy ID or transaction ID: toy attribution is inferred from the only toy with outstanding investment and subsequent level-1 observations. Engineering should confirm the advertised refund rule and check any compensation already issued after the cutoff before granting anything. No game state has been changed.

## Player and scope

| Field | Value |
| --- | --- |
| Game / version | Crayon Shin-chan TC, OBT / official App 18 |
| Event source | `ta.v_event_18` |
| Role ID | `4101883` |
| FiveCross account | `e70260b3-e916-44ca-89f6-cbf6e4e4bbdd` |
| Server | `1001` |
| Original matched name | `蠟筆3EB7AD` |
| Latest login name | `No95` |
| Loss window | `[2026-10-14 00:00:00, 2026-10-18 11:52:00)` |
| Configured business timezone | `Asia/Shanghai` |
| Identity-only lookup cutoff | `2026-10-18 18:00:00` exclusive |

The later identity lookup is used only to resolve the changed nickname. It does not extend the material-loss window. There are no internal/test-user exclusions for this individual support case. No events before the OBT start or after the loss cutoff contribute to the proposed quantity. Post-cutoff compensation receipts have **not** been audited.

## Verified findings

| Reset time on 2026-10-18 | Inferred toy instance | Level before reset | Actual upgrade investment | Actual upgrade refund | Shortfall |
| --- | --- | ---: | ---: | ---: | ---: |
| 02:17:08.703 | 小小飞鱼 / `1127759627681887` | 29 | 2,253 | 988 | 1,265 |
| 03:07:01.830 | 近水风鸭 / `1127759627682108` | 22 | 998 | 257 | 741 |
| Total | | | 3,251 | 1,245 | **2,006** |

- Each reset consumed exactly one potion (`10053`); its inventory moved `2 → 1 → 0` after a gain of two potions via `shop_buy` at 02:16:09.776. That gain record does not establish a cash/red-diamond purchase price.
- Each reset returned four Advanced Toy Remotes (`10264`), matching the four previously consumed for that cycle.
- The 02:58:16.388 deduction of 1,000 red diamonds matches a `card_Jobchange` event at the exact event and ingestion timestamps. There is no toy-material return there; it is not counted as a toy reset.
- Across the entire loss window, all 25 exact 1,000-red deductions were checked for co-timestamped events. Other costs without a clear event association remain unclassified rather than being called resets. None has nearby toy-material return evidence.
- Three `toy_break` events describe level-1 toys: nine, one and seven instances respectively. These are decomposition records, not assumed reset records. Their material gains are retained separately in the resource balance chain.
- Both reset refunds equal the last single upgrade deduction of the inferred target toy, rather than its accumulated cycle investment. This is an observed pattern worth checking in server refund logic, not a confirmed implementation diagnosis.

## Rules and calculation

The supplied screenshot is archived without modification at `inputs/toy_reset_rule.png`:

- 1,000 red diamonds: 80% of upgrade materials and 100% of advance materials.
- One reset potion: 100% of both upgrade and advance materials.

Only `item_change` rows are used for inventory accounting. A matching high-level `toy_up` or `shop_buy` resource payload is supporting evidence, not another inventory transaction.

1. Derive direction as `after - before`; `a_rst.diff` is positive even on consumes in this sample.
2. Match each of the 11 `toy_up` records to exactly one actual `390001` deduction within 0.5 seconds, with the same after-balance and ingestion time.
3. Attribute advance-material deductions to the only toy reaching a level-10/20 breakpoint within the preceding two seconds; keep this temporal attribution explicit.
4. Maintain cumulative material investments per toy instance since its last reset. At each potion deduction, require exactly one outstanding upgraded toy and inspect the same event-time/ingestion-time resource gains.
5. Corroborate the inferred reset through that toy's next level-bearing event starting at level 1.
6. Compute `upgrade shortfall = cumulative actual cycle investment - same-operation actual refund`. No 20% haircut is applied to potion resets.
7. Independently requery the key `item_change` stream and require exact multiset equality with the full-extract resource rows.
8. Reconstruct complete before/after chains for `10053`, `390001`, and `10264`, including equal-timestamp decomposition gains. Red-diamond rows contain only exact-1,000 deductions and are **not** a complete red-diamond wallet ledger.

A separate lifecycle conservation check excludes circular reset refunds from external acquisition: upgrade materials are `2,435 external gains - 0 closing wallet - 429 still invested = 2,006 unrecovered`; advance materials are `58 - 57 - 1 = 0`. Thus the currently valid toy investment is not included in the proposed reimbursement. The derived check is archived as `outputs/processed/material_conservation.csv`.

Final observed key-material balances at the last in-window change are 0 reset potions, 0 upgrade remotes, and 57 advance remotes. These are event-based observations, not a separately queried current wallet snapshot.

## Step-by-step inference: reset, re-investment, and compensation

This section explains **why the inferred reset time can precede later upgrade records for the same toy**. A reset returns a toy to its initial development state; it does not delete the instance or prevent subsequent upgrades. The audit therefore partitions investment by **toy instance and reset cycle**, not merely by toy name or the full extraction window.

### 1. Separate directly observed facts from inferred attribution

Direct observations are the `toy_up` instance IDs and levels, actual `item_change` before/after balances, potion deductions, material gains, and later decomposition levels. The two potion deductions each share an exact event timestamp **and** ingestion timestamp with upgrade/advance-material returns.

What is **not** directly recorded is a reset operation containing the target toy instance ID. Assigning a particular potion use to a particular toy is an inference from the complete observed sequence. No dedicated `toy_reset` or explicit `29 → 1` event at 02:17:08.703 exists in this extract. Later level-1 records corroborate a rollback, but do not independently identify its precise timestamp. The operation timing is inferred by combining those records with the potion/refund groups and the uniquely outstanding investment.

### 2. Reconstruct the first investment cycle of 小小飞鱼

Track **instance `1127759627681887`**, rather than every toy named 小小飞鱼. Its observed upgrade sequence before the first potion use is:

| Event time on 2026-10-18 | Observed level change | Actual `390001` wallet deduction |
| --- | --- | ---: |
| 00:40:18.282 | 1 → 10 | 78 |
| 00:40:22.262 | 10 → 20 | 663 |
| 00:40:24.066 | 20 → 21 | 239 |
| 00:40:58.191 | 21 → 23 | 285 |
| 01:46:31.325 | 23 → 29 | 988 |
| Total before the inferred reset | | **2,253** |

The time column is the `toy_up` event time; actual costs come from its uniquely matched wallet deduction. For example, the 663 deduction occurs at 00:40:21.911, 0.351 seconds before the corresponding `toy_up`. Its high-level payload reports 741 because the `before` value is stale/cumulative; **741 must not be substituted for the real 663 deduction**.

At **02:17:08.703**, the wallet records potion `10053: 2 → 1`, upgrade material `390001: 10 → 998` (**+988**), and advance material `10264: 42 → 46` (**+4**), all with ingestion time **02:17:37.433**. At that point, 小小飞鱼 is the only toy with observed outstanding upgrade investment; 近水风鸭 has not yet been upgraded. This supports attributing the first reset to 小小飞鱼.

At **03:07:09.071**, the same 小小飞鱼 instance has `level_before=1`. It had previously reached level 29. The same-instance level rollback corroborates that a reset happened, subject to the missing-reset-event limitation above.

Under the supplied potion rule, this first cycle has **2,253 expected upgrade materials − 988 actually returned = 1,265 short**. Its four advance materials were fully returned, so there is no advance-material shortfall.

### 3. Explain the later 11:17:16.919 record: a new investment cycle

The later records belong to the **same surviving instance after reset**, not an extension of its old level-29 investment cycle:

| Event time on 2026-10-18 | Observed level change | Actual new upgrade-material deduction |
| --- | --- | ---: |
| 03:07:09.071 | 1 → 10 | 78 |
| 03:07:13.905 | 10 → 15 | 231 |
| **11:17:16.919** | **15 → 16** | **120** |
| Total invested after the inferred reset | | **429** |

The 11:17 record therefore **does not contradict a reset at the earlier inferred time**. It continues the new `1 → 10 → 15 → 16` development sequence. These **429 upgrade materials remain invested in the current toy and are excluded from the reset-loss reimbursement**. The post-reset advance-material use of one `10264` also remains invested and is not reimbursed.

The worksheet `升级进阶实际扣款` intentionally retains all actual investment records within the observation window, including both cycles. Its late rows must not be read as evidence that all prior investment belongs to a single uninterrupted cycle, nor should all rows for the same instance be summed into the first reset's expected refund.

### 4. Attribute the second reset to 近水风鸭, not to the toy upgraded immediately afterward

Instance **`1127759627682108` (近水风鸭)** was observed at level 1 before its investment sequence. After the first potion use it was upgraded at **02:17:18.089, 02:17:21.970, and 02:17:23.813**, reaching levels **10, 20, and 22**, with actual upgrade deductions **78 + 663 + 257 = 998**. Its advance deductions total four.

At **03:07:01.830**, potion `10053` moves `1 → 0`; upgrade materials move `52 → 309` (**+257**), and advance materials move `54 → 58` (**+4**). These records share ingestion time **03:07:08.634**. At this point, 近水风鸭 is the only toy with observed outstanding investment under the first-reset attribution. Its later **10:43:59.631** `toy_break` entry identifies the same instance at **level 1**, corroborating the rollback from level 22.

Although 小小飞鱼 is upgraded only seconds after this second potion use, **the next toy upgraded is not automatically the toy just reset**. The accumulated investment, refund composition and subsequent level evidence support 近水风鸭 as the second target. Its upgrade shortfall is **998 − 257 = 741**, and the four advance materials were fully returned.

### 5. Test alternative explanations and reconcile the final recommendation

- **Wrong reset payment mode:** not supported. Each operation has a real one-potion deduction. Do not apply the red-mode 80% rule to these operations.
- **The 1,000-red deduction was another toy reset:** not supported. At 02:58:16.388 it coincides with `card_Jobchange` at the same event/ingestion timestamps, without a toy-material refund.
- **`toy_break` was the missing reset event:** not supported by these records. It describes level-1 decomposition, and its gains are accounted for separately.
- **Later upgrades invalidate the earlier reset:** no. The same instance restarts from level 1 and is then upgraded again; the new investment remains valid and is excluded.
- **All material inflows should be counted as new acquisition:** no. Reset refunds are recycled materials and must be removed from external acquisition to avoid double counting.

The per-reset shortfalls give **1,265 + 741 = 2,006**. Independently, full-lifecycle upgrade-material conservation gives **2,435 external gains − 0 ending wallet balance − 429 still invested = 2,006**. Advance-material conservation gives **58 − 57 − 1 = 0**. Agreement between these two accounting views supports the recommendation without reimbursing current development.

Both actual upgrade refunds also equal the corresponding toy's **last single upgrade deduction**, rather than its accumulated investment. This pattern is consistent with an accumulation problem, but it remains a **server-logic hypothesis**, not a confirmed code diagnosis. The recommendation assumes complete relevant telemetry and the screenshot's 100% rule; missing operations or a different authoritative rule would require revisiting the attribution and amount. Engineering/GM confirmation and a post-cutoff duplicate-grant check remain prerequisites for disbursement.

### Evidence and reproduction

- Actual wallet rows and source-line references: `outputs/processed/toy_investment_ledger.csv` and `outputs/processed/key_item_ledger.csv`.
- Per-cycle attribution, later level evidence and refund reconciliation: `outputs/processed/reset_reconciliation.csv`.
- Independent conservation check: `outputs/processed/material_conservation.csv`.
- Original toy/potion/resource records: `outputs/raw/04_toy_and_resource_events.csv`.
- Independently queried resource rows: `outputs/raw/06_independent_item_ledger.csv`.
- All-event context for reset groups and the red-diamond deduction: `outputs/raw/07_reset_context.csv`.
- Reproducible assertions: `scripts/build_report.py`; the builder stops rather than silently selecting a toy when attribution or wallet matching is ambiguous.

## Telemetry limitations and acceptance findings

The user supplied feature documentation as a starting hypothesis, not a validated schema. Actual `information_schema` and raw events are frozen in this case.

- No dedicated reset event was observed for this role/window; do not equate `toy_break` with reset.
- `toy_up.id` is empty. `unique_id` carries the instance identifier. Some `toy_break.toy_info` entries put the instance identifier in `id`, while `unique_id=0`.
- `elder1` is actually `ARRAY(ROW(...))`, while `elder2` is a single `ROW(...)`; the supplied description had different shapes. `son_toy` is `ARRAY(VARCHAR)`. Actual hatched toy details appear in `elder1`.
- Two `toy_up` payloads carry a stale/cumulative `before` value. For example, one reports a 741 difference while the corresponding actual wallet deduction is 663. Summing high-level payloads would overstate the investment and compensation.
- Resource ID `10053` also appears as a stage ID in `stage_fight.a_rst`; only the resource-specific `item_change` event stream qualifies as potion use.
- Reset-to-toy mapping has strong corroboration but no direct operation ID. This should be made first-class telemetry with toy instance ID, reset mode, charged item, accumulated expected refund, actual refund and a shared operation identifier.

## Directory layout

```text
config/snapshot.json       Fixed player, cutoffs and screenshot rules
inputs/toy_reset_rule.png  Original user-provided screenshot
sql/                      Actual read-only SQL (01–08)
tasks/                    Task configurations, without credentials
scripts/fetch_query.py    Runs archived SQL via the existing client
scripts/build_report.py   Reconciles evidence and verifies the workbook
outputs/raw/              Frozen live-query CSVs + SHA256 receipts
outputs/processed/        Reset, investment, key-ledger and red-cost audit CSVs
outputs/final/            Chinese Excel, summary JSON, verification JSON and CS memo
```

## Dependencies and configuration

Reuse the existing sibling checkout `fivecross-data-client` and its `.venv/Scripts/python.exe`, including `openpyxl`. The fetcher invokes that client's configured TA/global engine. There is no custom database connection and no credential copying in this case. Authentication recovery remains the data client's responsibility. Only the active configured client environment is used; no scheduler, email integration or remote writes are added.

The fixed source scope and business rule are in `config/snapshot.json`; the actual SQL includes the explicit dates and identifiers for review. Changing the case scope requires reviewing both configuration and SQL, rerunning queries and rebuilding all derived evidence.

## Run commands

From the analysis-case repository root, in Git Bash / a shell supporting native Windows paths:

```bash
# Refresh all source evidence serially through the existing client.
C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe \
  crayon_shinchan/05_data_audits/tc_obt_toy_reset_compensation_audit_20261018/scripts/fetch_query.py \
  01_identity 02_schema 03_event_inventory 04_toy_and_resource_events \
  05_latest_identity 06_independent_item_ledger 07_reset_context 08_red_cost_attribution

# Rebuild from frozen CSV evidence; no network/database access.
C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe \
  crayon_shinchan/05_data_audits/tc_obt_toy_reset_compensation_audit_20261018/scripts/build_report.py
```

The fetcher overwrites that query's local raw CSV and writes a fresh receipt only after a real export. Before adopting a changed snapshot, compare the previous report and investigate changed counts. Source tables are read-only. Queries run serially to avoid racing the client's browser/authentication profile.

## Outputs and validation

The primary workbook is:

`outputs/final/蜡笔小新繁体_OBT_4101883玩具重置补偿核查_截至20261018_115200.xlsx`

It contains eight Chinese worksheets: support conclusion, reset reconciliation, actual upgrade/advance deductions, key-item ledger, red-diamond exclusions, toy lifecycle, telemetry limitations, and query evidence.

`build_report.py` verifies all eight query receipts and SQL/CSV hashes, 105,851 source-event rows, the independently extracted 95-row key-resource stream, all 11 upgrade-to-wallet matches, unique outstanding-toy reset attribution, complete key-resource balance chains and final Excel read-back. All checks passed on the frozen snapshot. `outputs/final/verification.json` contains the final workbook SHA256 and checked outputs.

No monetary or item disbursement has been performed. Before granting the recommended shortfall, confirm the advertised material rule with engineering and check the support/GM grant history after 11:52 to prevent duplicate compensation.

## Troubleshooting

- **SQL/schema mismatch:** read `02_schema.csv`; named row fields and the actual array/row shapes outrank an unvalidated design sample. Do not silently alter ID meanings.
- **Resource direction confusion:** use `after-before`, not the sign of `diff`.
- **Unexpected compensation amount:** check the actual `item_change` rows, not the possibly cumulative `toy_up.a_rst` values; do not count high-level duplicate payloads as another spend/refund.
- **Ambiguous toy association:** the builder stops if more than one outstanding toy could explain a reset or if later level evidence does not corroborate level 1. Resolve with backend operation logs rather than choosing the closest toy arbitrarily.
- **CSV parsing warnings from the client:** the archived CSVs preserve JSON fields as text. This case parses them with the standard CSV/JSON libraries and verifies the independently queried resource stream.
- **File locked by Excel:** close the target or copy the output before rerunning; this builder will not terminate Excel or modify an open workbook.
