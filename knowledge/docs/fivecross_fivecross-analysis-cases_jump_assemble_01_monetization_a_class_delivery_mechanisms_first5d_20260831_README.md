# Jump Assemble TW — A-Class Delivery Mechanisms, First Five Days

**Corrected 2026-08-31.** This supersedes the earlier 8/26 interpretation after the confirmed mapping: **Zenitsu is sign-in grant `card_id=146` plus an academy-style activity consuming item `id=67`**.

## Scope and result

| Package | Window | Mechanism | DAU-weighted participation | Activity volume / participant | D1–D5 active-user revenue (USD) | Participant-day revenue share |
|---|---|---|---:|---:|---:|---:|
| Shinobu | 2026-07-08 to 07-12 | Pure gacha / standard special publication | 15.3% | 17.28 pulls | $167,560.87 | 43.6% |
| Gon | 2026-07-22 to 07-26 | BP + gacha | 17.1% | 17.60 pulls | $90,719.38 | 52.4% |
| Nezuko | 2026-08-19 to 08-23 | Academy activity + daily recharge/activity supply; item `57` | **71.7%** | 13.81 item consumes | $66,356.29 | **96.0%** |
| **Zenitsu** | **2026-08-26 to 08-30** | **Sign-in grant `card_id=146` + academy-style activity; item `67`** | **48.4%** | **3.41 item consumes** | **$120,106.20** | **81.9%** |

## Actual Jump Star spend — unique D1–D5 users

| Character | Relevant resource | Participation rate | Attempts / participant | Actual Star spend | Stars / participant | Stars / purchase user |
|---|---:|---:|---:|---:|---:|---:|
| Shinobu | `item 2` shared gacha resource | 29.4% | 24.44 | 2,618,444 | 183.38 | 2,039.29 |
| Gon | `item 2` shared gacha resource | 31.6% | 25.95 | 1,204,991 | 133.67 | 1,385.05 |
| Nezuko | `item 57` academy resource | 70.2% | 17.08 | 1,013,758 | 74.88 | 1,706.66 |
| Zenitsu | `item 67` academy resource | 70.2% | 3.08 | 2,107,150 | 177.89 | 3,031.87 |

This table retains normal discounted bundles as actual payments. In particular, the Zenitsu row includes `10 item 67 → 350 Stars` and `20 → 700 Stars`; these are not filtered as anomalies.

## Primary comparison priority

Because multiple character pools, packages, and payment mechanisms can overlap within the same calendar window, **revenue is retained only as background and is not used for character- or activity-level ranking or attribution.** The report’s primary comparison is:

1. **DAU-weighted participation** — actual reach of the corresponding event;
2. **Actual activity consumption and actual Jump Star spend** — `active_gacha.count` for Shinobu/Gon, or negative `resource_change.nums` for Nezuko/Zenitsu; item purchases are paired with actual negative Jump Star resource changes (`id IN (3,8)`) at the same user and second;
3. **D5 cultivation state** — ownership, awakening depth, and three-awakening completion.

The actual debit amount is used rather than mechanically applying `50 × item quantity`. Consequently normal discounted bundles are retained: Zenitsu `item 67` includes the observed `10 → 350` and `20 → 700` transactions. Its observed weighted cost is **45.93 Jump Stars per item**, versus **49.82** for Nezuko `item 57`.

For Shinobu and Gon, the matched purchase resource is the shared gacha resource `item 2`; the reported Jump Star spend is therefore the window’s real purchase spend on that resource, **not a target-pool-exclusive attribution**. It supports a consistent activity-resource investment view but must not be interpreted as cash or Star spend caused solely by the target pool.


1. **Zenitsu lands between pure gacha and Nezuko’s academy package on reach.** Its 48.4% DAU-weighted participation is far above pure-gacha Shinobu (15.3%) and BP+gacha Gon (17.1%), but below Nezuko (71.7%). The sign-in grant plus activity-based progression appears to create a materially wider engagement footprint than drawing alone.
2. **Zenitsu’s activity intensity is low versus Nezuko, but that is not a “weakness” without normalizing item economics.** Zenitsu averages 3.41 consumed `id=67` items per participant versus Nezuko’s 13.81 `id=57` items. These are different resources and supply rules; raw counts are not interchangeable.
3. **Zenitsu’s first-five-day money signal is strong and broad within the active-user scope.** It produced $120.1k of D1–D5 active-user revenue and 81.9% participant-day revenue share. This says users engaged in the `id=67` activity accounted for most same-day spending among that day’s login-active users; it is a **reference/segmentation metric**, not a causal claim that the activity directly generated this revenue.
4. **The daily shape differs from Nezuko.** Zenitsu participation is 56.4%, 35.7%, 61.3%, 32.2%, 57.5% from D1 to D5, versus Nezuko’s steadier 64.5%–74.2%. This alternating pattern should be examined against the sign-in / reward cadence and item-67 distribution rather than treated as organic decay.

## Workbook

`outputs/JUMP_TW_A级投放机制_首五日横比_20260831.xlsx`

- **执行摘要** — full D1–D5 package-level comparison and participation chart.
- **D1-D5每日明细** — daily DAU, participants, activity volume, revenue, payers and participant-day revenue.
- **D5养成与三觉** — ownership, recorded awakening depth, and the base-copy + three-awakening completion threshold.
- **口径与复跑** — data source, exclusions, revenue logic, item definitions and rerun path.

## D5 cultivation and three-awakening completion

A complete cultivation target is **one base hero copy plus three awakening copies**. The workbook therefore adds **`D5养成与三觉`**, where `card_awake` cardinality **≥ 3** is the three-awakening completion threshold — equivalent to four hero copies’ worth of investment. It is based on each D1–D5 active user’s latest `daily_role_card_snapshot` for the target hero in the corresponding window.

| Character | Hero ID | Holders / D1-D5 active users | Avg. awakening count among holders | Three-awakening completers | Three-awakening rate among holders |
|---|---:|---:|---:|---:|---:|
| Shinobu | 132 | 6,535 / 48,536 = 13.5% | 1.81 | 486 | 7.4% |
| Gon | 157 | 4,367 / 28,519 = 15.3% | **1.97** | 481 | **11.0%** |
| Nezuko | 115 | 4,167 / 19,278 = 21.6% | 1.50 | 179 | 4.3% |
| Zenitsu | 146 | **10,743 / 16,880 = 63.6%** | 1.38 | 222 | 2.1% |

### Cultivation interpretation

- **Zenitsu’s sign-in grant strongly expands ownership, not three-awakening completion in the first five days.** Its 63.6% ownership among D1–D5 active users is by far the highest; its three-awakening rate among holders is only 2.1%. That is the expected first-five-day profile for “free base copy + progression activity”: acquisition is broad, while duplicate accumulation is still shallow.
- **Gon shows the deepest early duplicate investment.** Its average awakening count is 1.97 and 11.0% of holders had reached the three-awakening threshold, the highest of the four. This is the relevant depth signal for the BP + draw package, rather than reach alone.
- **Do not read the three-awakening rate as a direct mechanism effect.** Different release timing, player base maturity, item supply and paid offers affect it. It is a real recorded player state, but is still a cross-package reference metric rather than causal incrementality.

## Methodology

### Activity definition

- Shinobu: `active_gacha`, `gacha_id=4`; volume = `SUM(count)`.
- Gon: `active_gacha`, `gacha_id=5`; volume = `SUM(count)`.
- Nezuko: `resource_change`, `id=57`, `nums<0`; volume = `SUM(-nums)`.
- Zenitsu: `resource_change`, `id=67`, `nums<0`; volume = `SUM(-nums)`. The sign-in grant `card_id=146` is treated as delivery context, while the common participation metric is the actual item-consumption activity.

### Common rules

- Source: ThinkingData Trino `ta.v_event_23`, using the `global` TA route of `fivecross-data-client` for the TW current build.
- Identity: `COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id, #account_id)`.
- Exclusions: `internal_users`, `is_water`, `is_water_mod`, `suspicious_ip`.
- Revenue scope: each calendar day includes only the valid `PURCHASE` revenue of users who also have `LOGIN_SUCCESS` on that same day in the corresponding D1–D5 window. Thus it is **D1–D5 active-user revenue**, not literal all-server revenue; users who purchased without a same-day login event are outside this metric.
- Revenue calculation: `PURCHASE`, excluding `SANDBOX_RECEIPT`; net of `ta.v_event_16` wallet free amount; converted once using `ta_dim.ta_exchange` and the purchase payload discount factor.
- Participant-day revenue: daily revenue of users who joined the relevant activity on that same day. It is not direct attribution or causal incrementality.

## Reproduce

1. SQL: `sql/02_four_A_packages_corrected_first5d.sql`
2. Task config: `fivecross-data-client/tasks/configs/adhoc/jump_tc_four_a_packages_corrected_first5d_20260831.json`
3. Build: `build_corrected_workbook.py`

All four windows use full D1–D5 data. Zenitsu is bounded to 2026-08-26 through 2026-08-30; 2026-08-31 is not included, avoiding a partial-day result.
