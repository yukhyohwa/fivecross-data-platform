# Kuroko TC Player Coin Audit — UID 100621823

## Purpose

This case reconstructs paid and free Kuroko-coin recharge and spending flows for one Kuroko TC player in ThinkingData, then reconciles the observed balance chain.

- Query window: `2026-10-13 00:00:00` through `2026-10-15 17:00:00`, inclusive
- Event table: `ta.v_event_10`
- Role ID / game UID: `100621823`
- 5X ID: `gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412`
- Free Kuroko coin: item `19999998`
- Paid Kuroko coin: item `19999999`

## Identity fields and required lookup logic

Two identifiers are required for this type of audit:

| Business identifier | ThinkingData field | Exported field | Use |
|---|---|---|---|
| Role ID / UID | `gid` | `role_id` | Identifies normal gameplay and Kuroko-coin spending events |
| 5X ID | `uuid` | `uuid` | Connects gameplay events with Web recharge events |

The role ID is the game's `gid`; it is displayed as `role_id` in the output. It is not the same as ThinkingData `#user_id`.

The 5X ID is the event field `uuid`. **The UUID must be queried directly whenever Web recharge records are required.** A lookup that starts with `gid` and then restricts all rows to the gameplay `#user_id` will miss Web recharge events.

Validated identity behavior for this player:

- Normal gameplay/spending rows: `gid=100621823`, `#user_id=1199684065603620864`, `#account_id=100621823`.
- Web recharge rows: `gid=0`, `#user_id=1205183578841813002`, `#account_id=<uuid>`.
- Both identities carry the same `uuid=gc_5X_55e204a8-4d07-4d6c-aca6-f30cd67ed412`.

Therefore, the final SQL uses the exact UUID as the primary player predicate. `gid` remains in the result as `role_id`, but it is not used to exclude Web recharge rows.

## Event classification

### Web recharge

A confirmed Web recharge is represented by:

- `event_name = srcoin_buy`
- `pay_currency = TWD`
- `pay_amount > 0`
- `gid = 0`
- target-currency gains in `a_rst`

These rows directly record paid-coin and bonus-free-coin gains. They must not be reconstructed from balance gaps when the direct rows are available.

### Kuroko-coin spending

A confirmed coin-spending row is represented by:

- `event_name = charge`
- `pay_currency = kuroko_pay`
- target-currency reductions in `a_rst`
- `product_id` identifying the purchased package

A separate free Web package (`product_id=web.package.tw.0.gift289`) grants item `1100971` but does not change either Kuroko-coin item, so it is excluded from the coin ledger.

## SQL logic

`sql/kuroko_coin_event_detail.sql` performs the following steps:

1. Prunes `ta.v_event_10` by `$part_date` and applies exact inclusive `#event_time` boundaries.
2. Filters directly on the player's exact `uuid` so both gameplay and Web recharge identities are retained.
3. Expands the `a_rst` array as `(id, before, diff, after, key)`.
4. Keeps only item `19999998` and item `19999999`.
5. Pivots free and paid currency elements from the same event into one event-level row.
6. Preserves `gid` as `role_id`; Web recharge rows correctly show `role_id=0`.
7. Writes payment context to `extra_info`:
   - recharge: fiat currency, fiat amount, and order ID;
   - spending: `kuroko_pay`, product ID, and order ID.

Output columns are:

```text
时间, event_name, role_id, uuid,
免费币before, 免费币diff, 免费币after,
付费币before, 付费币diff, 付费币after,
extra_info
```

## Balance reconciliation

The complete observed chain must satisfy, separately for each currency:

```text
opening balance + direct positive diffs + direct negative diffs = latest observed after
```

For this extract:

- Paid coin: `0 + 8,500 - 8,270 = 230`
- Free coin: `5 + 595 - 470 = 130`

The last target-currency event occurred at `2026-10-13 21:52:02.374`. Later login records do not contain a direct wallet snapshot for these two items. The reported balances are therefore the **latest verified observed balances**, not a direct `2026-10-15 17:00` wallet snapshot.

## Directory layout

```text
kuroko_uid_100621823_coin_audit_20261015/
├── README.md
├── REPORT.md
├── sql/
│   └── kuroko_coin_event_detail.sql
├── scripts/
│   ├── run_query.py
│   └── build_outputs.py
└── outputs/
    ├── kuroko_coin_event_detail.csv
    ├── kuroko_coin_event_detail.xlsx
    └── kuroko_coin_audit_summary.csv
```

Only final-query code and final deliverables are retained. Identity probes, gap probes, browser profiles, temporary logs, intermediate exports, and obsolete SQL are intentionally excluded.

## Dependencies

- Local query client: `C:\Users\5xgames\Desktop\github\fivecross-data-client`
- Its existing virtual environment and authenticated ThinkingData session
- Python 3.11+
- `openpyxl` for workbook generation

The query client path can be overridden with `FIVECROSS_DATA_CLIENT_ROOT`. If the client's default TA browser profile is busy, set `FIVECROSS_TA_SESSION_DIR` to an isolated authenticated TA profile before running the query; the case does not retain browser-profile files.

## Execution

From this case directory:

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_query.py
uv run --with openpyxl python scripts/build_outputs.py
```

`run_query.py` executes the final SQL and replaces `outputs/kuroko_coin_event_detail.csv`. `build_outputs.py` validates the ledger, verifies both balance equations, and regenerates the summary CSV and Excel workbook.

To audit another player, update all of the following in the SQL and documentation/output naming as appropriate:

1. exact `uuid` / 5X ID — mandatory for Web recharge coverage;
2. requested start and end timestamps;
3. `$part_date` bounds;
4. role ID / `gid` used for interpretation and player confirmation;
5. currency item IDs if the game configuration differs.

Do not replace the UUID predicate with only `gid` or gameplay `#user_id` when the audit must include Web recharge.

## Outputs and verified result

| Metric | Result |
|---|---:|
| Web recharge rows | 4 |
| Fiat recharge amount | TWD 8,500 |
| Paid-coin inflow | 8,500 |
| Free-coin inflow | 595 |
| Coin-spending rows | 7 |
| Paid-coin outflow | 8,270 |
| Free-coin outflow | 470 |
| Latest verified paid-coin balance | 230 |
| Latest verified free-coin balance | 130 |

`REPORT.md` contains the business-facing result and full event table. The CSV is the canonical machine-readable event ledger; the workbook is the formatted delivery copy.
