# Hall of Fame Card Activity Comparison — Taiwan

A reproducible mixed-source analysis case comparing the Taiwan-server Hall of Fame releases:

| Card | Release date | Measurement window | Source |
|---|---:|---|---|
| Hall of Fame Sakuragi | 2026-04-23 | 2026-04-23 to 2026-05-13 (21 days) | Legacy Aliyun / MaxCompute (ODPS) |
| Hall of Fame Rukawa | 2026-06-04 | 2026-06-04 to 2026-06-24 (21 days) | ThinkingData / Trino |
| Hall of Fame Miyagi | 2026-08-13 | 2026-08-13 to 2026-08-27 (15 available days) | ThinkingData / Trino |

> Miyagi is a partial observation window as of 2026-08-27. It must not be treated as a completed 21-day activity without normalisation or a later re-run.

## Scope

The case compares two independent measures and intentionally does not add them together:

1. **Target-coin acquisition and same-transaction resource consumption** — target coin gains, attributed by source event, plus separately observed paid stamps (`dmp:stamps`), free stamps (`dmp:freestamps`), and diamonds (`dmp:money`) consumed in the same resource transaction.
2. **Related direct-purchase revenue** — real purchase orders for the Hall of Fame package SKU set, including order count, payer-day count, original currency, and CNY-normalised revenue.

Target assets and related products:

| Card | Direct-purchase item | Target assets |
|---|---:|---|
| Sakuragi | `141025009` | `141024988` roulette coin; `141024987` training coin; `141025000` data pack |
| Rukawa | `141025042` | `141025034` roulette coin; `141025035` training coin; `141025032` data pack |
| Miyagi | `141025115` | `141025099` roulette coin; `141025100` training coin; `141025103` data pack |

## Source Routing and Revenue Definitions

### Product-name filter for Purchase detail

The purchase selection is mapped from `C:\Users\5xgames\Desktop\github\fivecross-sql-lib\games\slam_dunk\configs\dim_product.xlsx`, using exact platform SKU mappings. `Purchase detail` includes an explicit `product_name` column and **only** keeps names containing the relevant card keyword:

- Sakuragi: `殿堂櫻木`
- Rukawa: `殿堂流川`
- Miyagi: `殿堂宮城`

Generic co-released goods whose `product_name` does not include the card keyword (for example, generic roulette gifts or campaign gold cards) are intentionally excluded.

### Sakuragi: legacy ODPS

- Event / asset ledger: `g23002013.daily_game_log`.
- Purchase table: `dm_platform.daily_lcx_user_purchase`.
- The target asset ledger keys are `item@141024988` and `item@141024987`.
- CNY calculation: `SUM(price_show * exchange_rate)`, joining `dm_platform.itunes_exchange_rate_fmp` on source currency and month. The exchange table is filtered to `trans_to = 'cny'` and one first exchange-rate row is chosen per source-currency/month.

### Rukawa and Miyagi: ThinkingData / Trino

- Event table: `ta.v_event_20` (Taiwan app `23002013`).
- Revenue event: `PURCHASE`; `SANDBOX_RECEIPT` records are excluded.
- CNY calculation follows the established TA payload convention: `curamt / currencyrate * CNY_currencyrate` per event day, rather than comparing native-currency totals.

## D14 Cultivation Snapshot

“D14” is **release date + 14 calendar days**, not the fourteenth observed activity row:

| Card | D14 snapshot | Native source | Target `card_id` |
|---|---:|---|---:|
| Hall of Fame Sakuragi | 2026-05-07 | ODPS `g23002013.daily_user_card_snapshot` | `99011004` |
| Hall of Fame Rukawa | 2026-06-18 | ThinkingData `ta.v_event_20` / `user_card_snapshot` | `99011104` |
| Hall of Fame Miyagi | 2026-08-27 | ThinkingData `ta.v_event_20` / `user_card_snapshot` | `99010704` |

The `D14 cultivation` sheet reports holders and exact `grade` counts for grades 1–6. For legacy ODPS Sakuragi, talent progress is calculated as valid activated `skill`-node count divided by the 190-node target-card total and bucketed into `[0%,20%)`, `[20%,40%)`, `[40%,60%)`, `[60%,80%)`, and `[80%,100%]`.

> **TA migration caveat (material):** Rukawa/Miyagi holder and grade fields are available and were queried. However, the migrated `ta.v_event_20.skill` field serializes as a fixed 190-key schema with every key value `NULL` at D14; it cannot provide ordinary skill-node progress. Those five TA node-bucket cells remain blank—not zero.
>
> **Hall-of-Fame talent activation (final metric):** Hall-of-Fame players develop talent by consuming their card-specific **Talent Activation Cards**. The consumption is reliably recorded in `a_rst` under **`palace_awaken`** (not `palace_skill`): `item@40111004` for Sakuragi, `item@40111104` for Rukawa, and `item@40111204` for Miyagi. For each card, we count every player’s distinct activation events from activity start through D14 inclusive, up to nine stages. The `D14 palace activation` sheet provides two complementary measures: **Talent Activation N Players (cumulative)** = players who completed at least N activations; **Talent Activation N Stage Players (only this stage)** = players who completed exactly N activations and are therefore at that activation stage on D14. This stage distribution is retained because it shows the player population at each individual talent-activation tier. `palace_skill` consumes `item@410010020`, a separate skill-upgrade resource, and is not used to measure the nine activation stages.

## Analysis Playbook

### 1. Point-coupon consumption / resource flow

- Start from **target coin gains**, not purchase events, and retain the source event or item source.
- Within the same resource transaction, sum only negative `diff` values for `dmp:stamps` and `dmp:freestamps`; that is the attributable point-coupon consumption.
- Keep paid and free stamps together only if the analytical question is total event pressure; split them for monetisation attribution.
- Do not call the resource outflow “revenue”: it measures spend pressure/participation and can arise from saved or free inventory.

### 2. Package purchase analysis

- Use `configs/dim_product.xlsx` as the SKU-to-product-name authority; filter to exact target-card product-name keywords before aggregation.
- Examine **orders**, **payer-day count**, and **CNY revenue** together. CNY revenue makes ODPS/TA and native-currency platforms comparable; raw native currency remains an audit field.
- Compare package mix (starter / acceleration / talent / data) rather than treating all revenue as one undifferentiated total. A high acceleration-package mix alongside point spend indicates active chase pressure; a talent-package mix indicates post-acquisition development.
- Payer-day is not a cross-day deduplicated payer count. For conversion, join to a separately deduplicated card-holder or activity-exposed population.

### 3. Cultivation analysis

- Snapshot each card at the same lifecycle point (D14), then compare holders, grade ladder, and talent distribution—not just income.
- Treat grade counts as mutually exclusive status counts; validate that grade 1–6 sums to holder count. A grade-6 zero is a legitimate observed value, not a missing field.
- Use talent cohorts to differentiate broad ownership from developed ownership: the 60%+ and 80%+ bands are more useful for assessing competitive readiness than holder count alone.
- Never substitute an unavailable migrated talent payload with zero. Preserve nulls, document the source limitation, and rerun after a valid raw-node field is supplied.

## Directory Structure

```text
sql/
  01_odps_sakuragi_hof_card_activity.sql     # Sakuragi ODPS activity + CNY purchase result
  02_ta_rukawa_miyagi_hof_card_activity.sql  # Rukawa/Miyagi TA activity + CNY purchase result
  06_odps_sakuragi_day14_cultivation.sql     # Sakuragi ODPS D14 holder / grade / talent distribution
  07_ta_rukawa_miyagi_day14_cultivation.sql  # Rukawa/Miyagi TA D14 holder / grade snapshot
  09_odps_palace_skill_activation_debug.sql  # Sakuragi D14 palace_awaken / activation-card distribution
  10_ta_palace_skill_activation.sql          # Rukawa/Miyagi D14 palace_awaken / activation-card distribution
scripts/
  run_case.py                                # native-engine query runner
  build_report.py                            # validates source CSVs and builds Excel output
outputs/
  raw/                                       # timestamped native CSV exports
  final/                                     # Excel deliverable
```

## Requirements

Use the existing `fivecross-data-client` environment and configured TA/ODPS credentials. Do not create alternative connections.

```bash
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_case.py --only odps_sakuragi_hof_card_activity
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_case.py --only ta_rukawa_miyagi_hof_card_activity
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_case.py --only odps_sakuragi_day14_cultivation
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_case.py --only ta_rukawa_miyagi_day14_cultivation
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_case.py --only odps_palace_skill_activation_debug
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/run_case.py --only ta_palace_skill_activation
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe scripts/build_report.py
```

## Outputs

`outputs/final/hall_of_fame_card_activity_comparison_20260423_20260827.xlsx` contains:

- **Summary** — comparable activity-window totals.
- **Coin detail** — target-coin gain and same-transaction resource consumption by source event, separated into paid stamps (`dmp:stamps`), free stamps (`dmp:freestamps`), and diamonds (`dmp:money`).
- **Purchase detail** — Hall of Fame package revenue by SKU and native currency, with CNY total.
- **D14 cultivation** — holders, grade 1–6 distribution, and available five-band ordinary talent distribution at release + 14 days; TA ordinary-node buckets are explicitly source-limited, not zero.
- **D14 palace activation** — the authoritative Hall-of-Fame talent-activation progression view from `palace_awaken` / `a_rst`: cumulative players reaching activation 1–9, plus the mutually exclusive player count at each exact activation stage (1–9).
- **Raw palace ODPS** and **Raw palace TA** — native final activation aggregates for auditability.
- **Raw cultivation ODPS** and **Raw cultivation TA** — native D14 aggregate exports for auditability.
- **Raw ODPS** and **Raw TA** — exact exported records for auditability.
- **Methodology** — date boundaries, conversion rules, and aggregation caveats.

## Important Interpretation Notes

- `payer_day_sum` and target-coin `user_day_sum` are sums of daily/grouped distinct counts, **not** activity-level de-duplicated users. Do not label them as unique activity payers.
- Coin acquisition / paid-stamp / free-stamp / diamond spending represents same-transaction resource-flow attribution; it is not monetary revenue.
- All cross-source revenue comparisons must use `revenue_cny`; `revenue_native` is only an audit field.
- Any zero exchange rate / missing currency mapping must be investigated before publishing a decision based on revenue totals.
