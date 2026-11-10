# Kuroko TC Weekly Comprehensive Requirements

This case replaces the dated `weekly_comprehensive_requirements_20260928` folder and is the maintained home for the Kuroko Traditional Chinese weekly comprehensive operational report.

## Current deliverable

- Workbook: `outputs/黑子繁體_LG終戰活動_營運階段報告_20261104至20261109_0000_完整更新版.xlsx`
- Window: `2026-11-04 09:30:00 <= event_time < 2026-11-09 00:00:00`
- Scope: return users, new users, existing active users, spending and top products, point-stamp destinations, activity participation, LG ticket sales/use, and historical USD 5,000+ whales.
- Sheets: `01_營運總覽`, `02_玩家分群`, `03_儲值商品TOP3`, `04_點券消費去向`, `05_活動參與`, `06_LG扭蛋券銷售`, `07_大R分析`, `08_口徑與驗證`.

## Requirements covered

1. Count users who had not logged in during the seven days before `2026-11-04 09:30` and returned during the window.
2. For return users, count subsequent payers, top-three purchased products, and point-stamp destinations.
3. Count users newly observed at or after `2026-11-04 09:30`.
4. For new users, count subsequent payers, top-three purchased products, and point-stamp destinations.
5. Separately count participation in `LG終戰餽贈 (50001385)` and `LG終戰集結 (50001386)`, plus their UID intersection.
6. For existing active users, report spending, top-three products, and point-stamp destinations.
7. Separately count existing-active participation in both activities.
8. Report LG ticket sales and use with resource IDs `3010697`, `3010698`, and `3010699`.
9. Report historical cash whales with cumulative cash spend >= USD 5,000, including window spending, activity participation, and return share.

## Metric rules

### Cohorts

- New: no historical login before `2026-11-04 09:30`.
- Return: historical login exists, but no login during the preceding seven-day interval.
- Existing active: at least one login during the preceding seven-day interval.
- UID is the account grain. Existing TC blacklist cohorts are excluded.
- The end boundary is exclusive: events at exactly `2026-11-09 00:00:00` are excluded.

### Product TOP3

The workbook retains product ID and product name. Cash orders expose USD and converted TWD. `kuroko_pay` is a virtual black-token payment and is not itself a product. Token funding (`srcoin_buy`) is excluded from product ranking; products purchased with black tokens are included.

```text
ranking_twd = cash_twd + black_coin_spend
```

The operational assumption is `1 black coin = 1 TWD`. This is a consumption-equivalent measure, not financial net revenue.

### Point-stamp destinations

`04_點券消費去向` is a destination report, not a cash report. It retains the actual product ID and product name where present and reports negative resource deductions separately: paid point stamps, free point stamps, and diamonds. These are consumption quantities and must not be added to cash revenue.

### LG tickets

`06_LG扭蛋券銷售` keeps the resource types separate:

| Resource ID | Business name |
|---:|---|
| 3010697 | LAST GAME奇迹集结特训卡扭蛋币 |
| 3010698 | LAST GAME奇迹集结觉醒卡扭蛋币 |
| 3010699 | LAST GAME奇迹集结时装扭蛋扭蛋币 |

The sheet reports logged product/resource name, ticket buyers, tickets sold/gained, draw users, actual ticket consumption/draw count, paid point-stamp consumption, free point-stamp consumption, and diamond consumption. Point-stamp and diamond values are deductions associated with the ticket purchase/use flow, not cash revenue.

## Directory layout

```text
weekly_comprehensive_requirements/
├── README.md
├── sql/
│   ├── kb_lg_refresh_relevant_delta.json
│   └── kb_lg_refresh_login_cohort_20261109_blacklist.json
├── scripts/
│   ├── aggregate_kb_lg_refresh.py
│   └── build_kb_lg_complete.py
└── outputs/
    ├── 黑子繁體_LG終戰活動_營運階段報告_20261104至20261109_0000_完整更新版.xlsx
    └── raw/
```

Raw CSVs are audit inputs. Do not commit credentials, browser sessions, or `.env` files.

## Environment and refresh

Queries use the existing `fivecross-data-client` TA connection; credentials are not embedded in this case.

```powershell
$client = 'C:\Users\5xgames\Desktop\github\fivecross-data-client'
$py = "$client\.venv\Scripts\python.exe"
& $py "$client\main.py" fetch --task "$PWD\sql\kb_lg_refresh_relevant_delta.json"
& $py "$client\main.py" fetch --task "$PWD\sql\kb_lg_refresh_login_cohort_20261109_blacklist.json"
$env:KB_LG_CASE_ROOT = (Get-Location).Path
$env:KB_LG_CLIENT_OUTPUT = "$client\data\output"
python .\scripts\aggregate_kb_lg_refresh.py
$env:KB_LG_SCRATCH = "$PWD\outputs\raw"
python .\scripts\build_kb_lg_complete.py
```

The SQL uses an exclusive cutoff. The operational query is bounded to relevant event types; it must not be replaced with an unrestricted all-event export. The build script writes a dated workbook into the configured raw/output directory; copy the approved final workbook to `outputs\` after validation.

## Validation checklist

- Verify the exclusive end boundary `2026-11-09 00:00:00`.
- Verify UID-distinct cohort counts and blacklist exclusions.
- Verify `03_儲值商品TOP3` contains product IDs, product names, USD, TWD, black tokens, and ranking value.
- Verify `04_點券消費去向` contains destinations, product IDs, names, and actual paid/free point-stamp and diamond deductions.
- Verify `06_LG扭蛋券銷售` has all eight operational fields and keeps all three resource IDs separate.
- Verify activity rows remain separate for `50001385` and `50001386`; do not sum them as unique users.
- Verify the workbook has all eight sheets and opens successfully with openpyxl or Excel.

## Limitations

Black-token valuation is a business assumption, not an accounting conversion. Event telemetry provides evidence of participation and purchase/use flows; it does not prove a page view when no corresponding event exists.
