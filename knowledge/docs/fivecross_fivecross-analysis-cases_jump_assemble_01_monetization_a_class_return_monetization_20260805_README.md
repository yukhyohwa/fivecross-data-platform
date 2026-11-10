# Jump Assemble TW — A-Class Return Self-Select Monetization Assessment

## Decision question

From **2026-08-05 through 2026-08-12**, a new self-select pool sold previously released special-publication A-class characters. The pool consumes **activity item 62**. The business question is whether this format can provide meaningful revenue support when there is no new-character launch.

This project supersedes any earlier interpretation that treated shared `gacha_id=2` activity as the return-pool population.

## Primary attribution rule

Several pools can overlap in the same calendar window. Therefore:

- 8/5 return-pool participation = negative `resource_change.nums` for **item 62**;
- historical new-A special-publication participation = each character's dedicated `active_gacha.gacha_id` and draw `count`;
- Nezuko academy participation = negative `resource_change.nums` for **item 57**.

Platform revenue during the date window is context, not pool-exclusive revenue. Consumer same-day platform revenue is also not direct SKU attribution or causal incrementality.

## Matched D1–D5 result

| Period | Participation / DAU-days | Activity depth / participant-day | Revenue / DAU-day | Payer rate | ARPPU |
|---|---:|---:|---:|---:|---:|
| New A — Yuji | 27.1% | 18.8 draws | $1.38 | 5.1% | $27.04 |
| New A — Shinobu | 15.3% | 17.3 draws | $1.27 | 5.2% | $24.64 |
| New A — Gon | 17.1% | 17.6 draws | $1.17 | 5.7% | $20.59 |
| **8/5 return self-select — item 62** | **1.1%** | **24.3 items** | **$0.82** | **4.1%** | **$20.03** |
| Nezuko academy — item 57 | 71.7% | 13.8 items | $1.28 | 7.3% | $17.62 |

Raw draws and activity items are not interchangeable currencies. The valid interpretation is that converted return-pool users had meaningful depth, but the pool reached far fewer active users than every new-A benchmark.

## Item-acquisition economics

Same-second resource-operation validation gives the following D1–D5 observations:

- item 62: 10,832 of 15,662 gained items (69.2%) were paired with Jump Star consumption; validated average = 28.3 Stars per matched item;
- item 57: 20,348 of 538,757 gained items (3.8%) were paired with Jump Star consumption; the remainder was primarily task distribution; validated store price ≈ 49.8 Stars per matched item.

This explains the reach gap: item 62 starts behind a payment gate, while the academy loop uses broad task distribution and monetizes top-up demand. The result does not imply the different raw item quantities are directly comparable.

## Full-window shape

Item-62 consumers declined from 244 on D1 to 16 on D8, a 93.4% drop. The format monetized a small high-intent audience early but did not create sustained reach.

## Rank is supporting evidence only

Using each player's latest ranked ladder level during the 30 days before the activity:

- Bronze–Gold: 0.7% item-62 consumer rate;
- Platinum–Diamond: 3.6%;
- Star: 9.5%;
- King+: 14.8%;
- no ranked match in lookback: 0.4%.

This supports high-rank targeting, but rank is not the primary attribution method.

## Decision

The current paid-only item-62 return design should **not** be scheduled as the sole replacement for a new-A revenue slot. It can be retained as segmented supplementary monetization for high-intent, unowned-character, duplicate, awakening, and cultivation demand.

To test whether a redesigned return offer can backfill revenue:

1. add a small non-completing mission allowance and monetize completion/top-up;
2. segment by eligible-character ownership, awakening depth, historical special-pool usage, and prior spend;
3. connect `item 62 gain` to SKU/product/purchase identifiers for direct cash attribution;
4. measure matched-control or holdout incremental D1–D5 revenue, D7/D14 persistence, and cannibalization of concurrent pools.

## Deliverables

```text
a_class_return_monetization_20260805/
├── README.md
├── build_ppt_corrected.py
├── sql/
│   ├── 00_event_dictionary_discovery.sql
│   ├── 01_event_revenue_comparison.sql      # historical audit; gacha-id return row is superseded
│   ├── 02_daily_kpi_context.sql
│   ├── 03_resource_flow_comparison.sql      # item 62 vs item 57 resource-flow context
│   ├── 04_resource_flow_by_rank.sql         # supporting pre-window rank segmentation
│   └── 05_item62_vs_item57_acquisition_economics.sql
└── output/
    ├── JUMP_TW_A级角色复刻效益_item62流水分析_20260831.pptx
    └── raw_data/
        ├── jump_tc_a_class_event_revenue_comparison_20260828_20260828_113908.csv
        ├── jump_tc_a_class_resource_flow_comparison_20260828_20260831_112751.csv
        ├── jump_tc_item62_vs_item57_acquisition_economics_20260831_20260831_160904.csv
        └── jump_tc_a_class_resource_flow_by_rank_20260831_20260831_155433.xlsx
```

## Source and filters

- Source: ThinkingData Trino `ta.v_event_23`, routed through the existing `fivecross-data-client` TC/global convention.
- Identity: `COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id, #account_id)`.
- Exclusions: internal users, water users/mods, and suspicious-IP clusters.
- Revenue: valid `PURCHASE`, excluding sandbox receipts, net of wallet free amount, FX-converted once using the established client SQL convention.

## 2026-08-31: item 62 vs four A-class launches (D1–D5)

This addendum answers a narrower operational question: whether the 8/5–8/12 A-class self-select return activity, whose target resource is `item_id = 62`, could provide enough engagement and Jump Star consumption to backfill the no-new-character revenue window.

### Fair comparison scope

The full item-62 activity ran for eight days, but each comparison row uses the first five calendar days (`2026-08-05`–`2026-08-09`) to match the first-five-day launch window of Shinobu, Gon, Nezuko, and Zenitsu. The primary SQL is `sql/06_return_item62_vs_four_A_star_consumption_d1_d5.sql`.

### Result

- The return activity reached **565 / 22,457** unique active users (**2.5%**), versus **29.4%–70.2%** for the four launch windows.
- Its participating users were not shallow: they consumed **27.5 item-62 units per participant**, comparable with Shinobu (24.4 gacha attempts) and Gon (26.0). The failure mode is reach, not depth among those who entered.
- Matched actual Jump Star spending was **307,080**, well below the four launch-window reference range of **1.01M–2.62M**. It is therefore not a strong enough internal-currency recovery mechanism to stand alone as a revenue-gap backfill.
- The same-period all-active-user revenue intensity was **$0.82 per DAU-day**, below the four launch references (**$1.17–$2.46**). This is a directional association with low participation and low Jump Star recovery; it is **not** activity revenue, SKU revenue, incremental lift, or proof of causality.

### New artifacts

```text
sql/06_return_item62_vs_four_A_star_consumption_d1_d5.sql
build_return_vs_four_a_deliverables.py
output/JUMP_TW_A级复刻效益_item62_vs_四个A角色_D1-D5_20260831.xlsx
output/JUMP_TW_A级角色复刻效益_item62_vs_四个A角色_D1-D5_20260831.pptx
```

### Important attribution guardrail

For `item 62`, `item 57`, and `item 67`, the report matches target-resource gain events to negative Jump Star changes for the same user and second, preserving actual discounted or bulk prices. Shinobu and Gon use shared `item 2`; their matched Jump Star values are only a window-level common-resource reference and must not be interpreted as target-pool-exclusive spending.
