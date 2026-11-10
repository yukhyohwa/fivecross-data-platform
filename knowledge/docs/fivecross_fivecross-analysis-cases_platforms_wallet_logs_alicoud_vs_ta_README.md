# Wallet Logs Reconcile: AliCloud vs TA (ThinkingData)

This project compares wallet transaction logs (`LCX_WALLET_PURCHASE_TRANSACTION`) from ThinkingData (TA) against the billing records in AliCloud ODPS (`dm_platform.transaction_wallet`). 

Unlike `order_reconcile_alicloud_vs_ta` which attempts to match transactions via order IDs (like `ta_purchase_id` vs `odps_order_id`), this project performs an **aggregated reconciliation by Game and Channel (`channelno`)**.

## Directory Structure

```text
wallet_logs_alicoud_vs_ta/
├── sql/
│   ├── sys_extract_odps_wallet.sql   # ODPS extraction query
│   └── sys_extract_ta_wallet.sql     # TA extraction query (unions multiple projects)
├── sys_match_wallet_logs.py          # Main execution & reconciliation script
└── README.md                         # This file
```

## Logic Overview

1. **TA Data Extraction**: 
   Queries events `v_event_19`, `20`, `21`, and `22` where `$part_event = 'LCX_WALLET_PURCHASE_TRANSACTION'`. Extracts `productid`, `channelno`, `price`, `paidamount`, and parses the `game_id` from the product ID using `regexp_extract`.
2. **ODPS Data Extraction**:
   Queries `dm_platform.transaction_wallet` for transaction types `CHARGE` and `DIRECT_CHARGE` for the target `game_id`s.
3. **Reconciliation (`sys_match_wallet_logs.py`)**:
   - Fetches both datasets utilizing the `fivecross-data-client` engine.
   - Aggregates metrics (Total Orders, Total Revenue) grouped by `game_id` and `channelno` (for ODPS, this maps to `channel_type`).
   - Performs a full outer join on the aggregated sets.
   - Calculates the `diff_order_count` and `diff_paid_amount`.
   - Exports the final result as an Excel file containing a `Channel_Summary` sheet (the aggregated diffs) along with the raw `TA_Raw` and `ODPS_Raw` sheets.

## Usage

Ensure your Python environment is set up and `fivecross-data-client` is correctly configured in the parent directory.

Run the script by providing the start and end dates (format: `YYYY-MM-DD`):

```bash
python sys_match_wallet_logs.py --start 2026-04-26 --end 2026-04-27
```

Results are saved to the `reconcile_results/` directory as an Excel file.
