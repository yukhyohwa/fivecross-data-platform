# Kuroko TC BP Purchase and Refund Audit

## Purpose

This case documents the reproducible method used to audit a single player's Season Journey / Battle Pass (BP) purchase history, including successful entitlement purchases, failed payment attempts, wallet funding, refunds, and progression logs.

The case is designed for dispute handling. It does **not** infer a purchase from a level change, and it does not treat a failed retry as a successful order.

## Scope

- Game: Kuroko's Basketball, Traditional Chinese region
- ThinkingData source: `ta.v_event_10`
- Identity supplied by operations: `gid = 101455481`
- Resolved UUID: `gc_5X_93a1cfd1-9601-4681-ab9c-140c4e6d194a`
- Event window: `[2026-10-01 00:00:00, 2026-11-01 00:00:00)`
- Timezone: source event time as stored by ThinkingData; no additional conversion

## Method summary

### 1. Resolve identity before querying payments

The business UID is a role-side `gid`, not necessarily the same as `#user_id`. First resolve the role and UUID. Web wallet events can carry `gid = 0` while retaining the player's UUID, so a gid-only query would miss wallet funding and related transaction context.

For this player:

- `gid`: `101455481`
- `uuid`: `gc_5X_93a1cfd1-9601-4681-ab9c-140c4e6d194a`

The purchase detail query uses the resolved UUID and retains the role-side `gid` where present.

### 2. Use an explicit half-open time window

Every query applies both partition pruning and event-time boundaries:

```sql
"$part_date" BETWEEN '2026-10-01' AND '2026-10-31'
AND "#event_time" >= TIMESTAMP '2026-10-01 00:00:00'
AND "#event_time" <  TIMESTAMP '2026-11-01 00:00:00'
```

The final boundary is exclusive. This avoids accidentally including November 1 events.

### 3. Separate purchase, payment failure, refund, funding, and progression

| Evidence type | Event / field | Interpretation |
|---|---|---|
| BP entitlement purchase | `charge` + validated `cfg_id` | Successful product purchase when valid-order rules pass |
| Payment retry failure | `charge_fail` | Failed payment; not a successful purchase and not a refund |
| Reversal | `refund_order` | Refund evidence; match by order ID when possible |
| Wallet funding | `srcoin_buy` | Black-coin funding; not a BP product purchase |
| Formal BP level purchase | `battlepass_levelbuy` | Point-based level purchase; separate from entitlement purchase |
| Progression | `battlepass_levelup` | Level state change; not purchase evidence by itself |
| Trial progression | `trial_battlepass_levelup` | Trial BP progression; not formal BP entitlement evidence |
| Rewards | `battlepass_reward`, `battlepass_taskreward` | Reward delivery; not purchase evidence |

### 4. Validate the product mapping

The product dimension maps:

- `21100389` → `2026通行证进阶版（10月）`
- `21100390` → `2026通行证典藏版（10月）`
- `21100391` → `2026通行证进阶版（11月）`
- `21100392` → `2026通行证典藏版（11月）`

A product name alone is not used as a purchase predicate. The query retains `cfg_id`, `product_id`, order ID, currency and resource payload so the purchase can be independently traced.

### 5. Apply the transaction interpretation

A successful BP purchase is counted only when the `charge` row is present and the product mapping is confirmed. `charge_fail` is recorded in the audit but excluded from successful purchase count. `refund_order` is queried separately and must not be invented from a failed payment or a missing FM record.

For wallet-priced orders, `pay_amount` can be zero on `charge`; the actual wallet deduction is read from `a_rst` / `resources`, including paid-wallet item `19999999` when present.

## Verified result for this case

Within the requested window:

- Successful October BP advanced purchase: **1**
- Product: `21100389`, `2026通行证进阶版（10月）`
- Successful purchase time: `2026-10-20 01:29:52.077`
- Wallet deduction: `400` paid black coins
- Failed payment attempt: **1**
- Failed attempt time: `2026-10-31 01:45:19.951`
- Failed attempt product: `21100389`
- Refund events found: **0**
- Duplicate successful BP purchase found: **0**

The player also has progression events, including formal `battlepass_levelup` and `trial_battlepass_levelup`. These are retained as context only and are not counted as additional BP purchases.

## Directory structure

```text
bp_purchase_refund_audit_20261001_20261101/
├── README.md
├── sql/
│   ├── bp_uid_purchase_refund_detail.json
│   ├── bp_uid_identity_summary.json
│   └── bp_uid_progression_context.json
├── scripts/
│   └── build_uid_bp_audit_excel.py
└── outputs/
    ├── 黑子繁體_UID101455481_BP購買核查_20261001_20261101.xlsx
    ├── 黑子繁體_UID101455481_BP購買退款明細_20261001_20261101.csv
    └── 黑子繁體_UID101455481_BP相關事件_20261001_20261101.csv
```

## Execution

Run queries through the existing data client; do not create a new database connection:

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-data-client
./.venv/Scripts/python.exe main.py fetch --task \
  C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/kurokos_basketball/04_data_audits/bp_purchase_refund_audit_20261001_20261101/sql/bp_uid_purchase_refund_detail.json
```

The other SQL task files use the same command pattern. Query exports are then copied into `outputs/` and the workbook is rebuilt with:

```bash
cd C:/Users/5xgames/Desktop/github/fivecross-analysis-cases/kurokos_basketball/04_data_audits/bp_purchase_refund_audit_20261001_20261101
python scripts/build_uid_bp_audit_excel.py
```

The build script reads the latest matching CSV exports from the configured data-client output directory, classifies rows, writes the Chinese audit workbook, and reloads it to verify sheet names and key counts.

## Validation checklist

- [x] Exact `gid` and UUID are retained separately.
- [x] UUID-based wallet context is included.
- [x] Half-open event window is explicit.
- [x] Product ID is mapped through the BP product dimension.
- [x] Successful `charge` is separated from `charge_fail`.
- [x] `refund_order` is queried explicitly.
- [x] `srcoin_buy` is treated as funding, not BP purchase.
- [x] `battlepass_levelup` and `trial_battlepass_levelup` are not counted as purchases.
- [x] Order ID, timestamp, currency, amount and resource payload are retained.
- [x] Workbook was rebuilt and reloaded successfully.

## Limitations

- A missing `refund_order` in this event window means no matching refund event was observed in the queried source and window. It does not prove that an external FM record cannot exist outside this telemetry source.
- A progression event proves progression telemetry only. It cannot establish how the player obtained the entitlement unless the corresponding purchase or entitlement event is present.
- Wallet `after` values are observed balances from the payload, not necessarily a certified end-of-window wallet balance if later events omit the relevant resource.
- This case audits the supplied player and does not export the whole event table.
