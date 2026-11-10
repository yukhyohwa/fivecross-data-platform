# Nezuko Daily Recharge Reward — Reimbursement Reconciliation

## Objective

Produce the **account-level operational extract** required after the Jump Assemble TC daily-recharge activity ends. The activity runs from **2026-08-19 through 2026-09-02**, inclusive:

- A player who recharges the equivalent of **TWD 150 / 300 paid Stars** on a calendar day may claim one daily recharge reward.
- At most **7** daily rewards may be claimed in the 15-day activity.
- A player entitled to at least **5** daily rewards may claim the Nezuko costume.
- The implementation defect means recharges made during the final seven days (2026-08-26–2026-09-02) do not count in the live activity. The extract compares payment-based entitlement with actually claimed rewards to calculate the reimbursement quantities.

## Deliverable

The final workbook is intentionally generated **only after 2026-09-02 data is complete**. Its `Player Reconciliation` sheet has one row per player with at least one valid recharge in the activity window:

| Field | Definition |
|---|---|
| `player_id` | `lcx_id` with the validated Jump OBT SDK/account fallback chain. |
| `role_id` / `role_name` | Latest non-null role identity observed in `resource_change` since 2026-06-24, ordered by `#event_time` descending; follows the supplied player-profile search logic. A null means no eligible role event was found for that recharging account. |
| `total_recharge_twd` | Valid activity-window recharge, converted to TWD exactly once. |
| `recharge_days_ge_150_twd` | Count of days with cumulative daily recharge >= TWD 150. |
| `daily_recharge_twd_list` | A fixed 15-element list ordered 8/19 → 9/2; zero means no valid recharge that day. |
| `expected_daily_recharge_reward_count` | `MIN(recharge_days_ge_150_twd, 7)`. |
| `actual_daily_recharge_reward_claim_count` | Distinct daily reward IDs actually claimed from the provided seven-item list. |
| `daily_reward_reimbursement_count` | `MAX(expected - actual, 0)`. |
| `expected_nezuko_skin_entitlement` | 1 if expected daily reward count >= 5; otherwise 0. |
| `actual_nezuko_skin_claim_count` | Count of Nezuko costume acquisition events (`hero_id=115`, `skin_id=115001`). |
| `nezuko_skin_reimbursement_count` | 1 only when entitled but no costume acquisition is recorded. |
| `missing_fx_order_count` | QA flag: non-TWD valid purchase rows without an exchange-rate match. It must be zero before operational use; source-TWD orders do not require an FX match. |

## Data definitions

| Topic | Definition |
|---|---|
| Game/source | Jump Assemble TC current 3v3 OBT, ThinkingData Trino: `ta.v_event_23`, run with `region=global`. |
| Valid recharge | `PURCHASE`, excluding `SANDBOX_RECEIPT`. No internal/water blacklist is applied because this is a reimbursement extract; any operations exclusion must be explicitly supplied and audited. |
| Currency conversion | Source `TWD` payments use `payload.curamt` directly, with no FX join or intermediate conversion. Other currencies use `payload.curamt / source_fx.exchange * TWD_fx.exchange`, joining `ta_dim.ta_exchange` by purchase date and currency. This avoids a TWD → USD → TWD round trip. |
| Points-mall discount treatment | **Activity cumulative recharge is not reduced by Points Mall discount factors.** It uses the original valid `PURCHASE.payload.curamt` order amount (then only applies the needed currency conversion). Do not apply `purchaseeventpayload` discount multipliers or deduct `LCX_WALLET_SPEND_TRANSACTION.freeamount`; those belong to net-revenue analysis, not this activity eligibility/reimbursement definition. |
| Daily reward actuals | `resource_change`, `reason='任务奖励领取'`, item IDs `5000244`–`5000250`; distinct item IDs cap actual claims at 7. |
| Costume actuals | `card_skin`, `hero_id=115`, `skin_id=115001`. |
| Window | Calendar days 2026-08-19 to 2026-09-02 inclusive, ordered exactly in every daily list. |

## Project structure

```text
nezuko_daily_recharge_reimbursement_20260819/
├── README.md
├── sql/
│   └── 01_player_recharge_reward_reconciliation.sql
├── scripts/
│   ├── run_extract.py
│   └── build_workbook.py
└── outputs/
    ├── raw_data/                         # copied client CSVs
    └── JUMP_TC_弥豆子每日储值奖励回补_20260819_20260902.xlsx
```

## Runbook

### 1. Final extraction (run on/after 2026-09-03 once TA partition data is complete)

This uses the existing `fivecross-data-client` virtual environment and TA browser-session connection. It does not create another database connection.

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/jump_assemble/02_liveops_payments/nezuko_daily_recharge_reimbursement_20260819
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_extract.py
```

The script writes a transient adhoc task under the existing data client, runs `main.py fetch --task`, and copies the exported CSV into `outputs/raw_data/`.

### 2. Build the workbook

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/build_workbook.py
```

The workbook build refuses to proceed if it cannot find the final full-window raw CSV or if any `missing_fx_order_count` is non-zero.

### 3. Validate the workbook

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe \
  C:/Users/5xgames/AppData/Local/hermes/skills/productivity/xlsx/scripts/xlsx_read.py \
  outputs/JUMP_TC_弥豆子每日储值奖励回补_20260819_20260902.xlsx --sheets
```

## Preflight before activity end

A preflight may validate fields and TA access without creating the final workbook:

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_extract.py --end-date 2026-08-28 --preflight
```

A preflight extract is incomplete by definition and must not be used for reimbursement.

## Operational QA checklist

- [ ] Extraction end date is `2026-09-02` and TA partitions have landed.
- [ ] Raw CSV has one row per recharging player and the 15-element list order is 8/19 → 9/2.
- [ ] `missing_fx_order_count` is zero for all rows.
- [ ] Reward IDs and skin IDs match the live configuration.
- [ ] Daily reward reimbursement is `max(min(qualified_days, 7) - actual_claims, 0)`.
- [ ] Costume reimbursement is limited to eligible players with no recorded costume claim.
- [ ] Workbook sheet count, row count, and source filename are verified before delivery.
