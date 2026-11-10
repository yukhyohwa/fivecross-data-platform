# Gojo S-Class First Rerun — 30-Draw Pity Review

## Purpose

Review the first S-class Gojo rerun in **Jump Assemble TW**, launched on **2026-09-02** with a **30-draw pity threshold**. The report evaluates whether the rerun's observed target-pool drawing behavior is consistent with deeper pity-cycle completion than recent 40-draw S-class pools.

The analysis is observational. It provides cross-pool and retention-conditioned evidence, not a causal estimate of the pity-rule effect.

## Reporting Scope

All comparisons use the first **five complete calendar days after each pool launch (D1-D5)**.

| Pool | Target gacha ID | Pity threshold | D1-D5 window |
|---|---:|---:|---|
| Pain | 103 | 40 draws | 2026-08-05 to 2026-08-09 |
| Minato | 104 | 40 draws | 2026-08-12 to 2026-08-16 |
| Byakuya | 105 | 40 draws | 2026-08-26 to 2026-08-30 |
| Gojo rerun | 106 | 30 draws | 2026-09-02 to 2026-09-06 |

The original Gojo reference pool is `gacha_id=101`. The main fixed-cohort comparison uses its D1-D5 window (2026-06-24 to 2026-06-28); the separate incomplete-awakening Excel segment uses the observed full sale cycle, 2026-06-24 to 2026-07-22.

## Evidence Design

### 1. Same-window pool comparison

Compare participation and target-pool drawing depth across the recent S pools. The primary normalized measure is:

`participant pity-cycle equivalent = participant target-pool draws / pool pity threshold`

This permits a like-for-like comparison between 30- and 40-draw pools. It is not revenue, prize value, or actual reward-redemption count.

### 2. Fixed historical cohort

Anchor a cohort to users who were active in original Gojo D1-D5 but did not draw from the original Gojo target pool. Compare their behavior in subsequent S pools. Each period reports its currently active cohort denominator separately.

### 3. Retention-conditioned robustness check

Further restrict the fixed historical cohort to users also active during Gojo rerun D1-D5. This produces a balanced cohort of 3,068 accounts and applies the same denominator to every subsequent S pool. It removes the mechanical change in active denominators across pool windows, while explicitly conditioning on survival to the rerun period.

### 4. Return-path disclosure

From the full original-Gojo active base, split original participants and nonparticipants. Show how many are active in the rerun D1-D5 window and how many of those return-active users participate in the rerun target pool. This makes the retention-selection step transparent.

### 5. Original-sale incomplete-awakening segment

Within all original-Gojo target-pool participants across the observed full original sale cycle (2026-06-24 to 2026-07-22), inspect every available `daily_role_card_snapshot` for business dates in that interval (stored in partitions 2026-06-25 to 2026-07-23). A user enters the segment only when their maximum observed `CARDINALITY(card_awake)` throughout the full cycle is 0–2; `card_awake IS NULL` is the validated storage representation for 0 awakenings and is treated as 0. Users who reach 3 awakenings at any point are excluded. Report this historical segment's rerun D1-D5 active base and target-pool drawing behavior in a separate Excel. This is a descriptive segment, not a causal mechanism test.

## Data Source and Filters

- **Source:** ThinkingData / Trino `ta.v_event_23` for Jump Assemble TW.
- **Active definition:** at least one `LOGIN_SUCCESS` event in the relevant D1-D5 window.
- **Target-pool drawing:** `active_gacha` filtered to the exact target `gacha_id`.
- **Exclusions:** `internal_users`, `is_water`, `is_water_mod`, and `suspicious_ip` clusters.
- **Attribution boundary:** Generic activity-resource consumption and all-window `PURCHASE` revenue are excluded from target-pool drawing conclusions because they are not uniquely attributable to the target pool.

## Repository Layout

```text
inputs/raw/
  jump_tc_first_gojo_active_nonparticipant_across_s_pools_d1_d5_20260907.csv
  jump_tc_first_gojo_cohort_return_active_rerun_d1_d5_20260907.csv
  jump_tc_first_nonparticipant_rerun_active_fixed_cohort_d1_d5_20260907.csv
  jump_tc_first_gojo_full_cycle_not_full_awake_rerun_d1_d5_20260907.csv

sql/
  04_first_active_nonparticipant_across_s_pools_d1_d5.sql
  05_first_gojo_cohort_return_active_at_rerun_d1_d5.sql
  06_first_nonparticipant_and_rerun_active_fixed_cohort_d1_d5.sql
  07_first_gojo_full_cycle_not_full_awake_rerun_draw_d1_d5.sql
  08_first_gojo_new_holder_acquisition.sql
  09_limited_ticket_balance_all_vs_rerun_participants.sql
  10_gojo_rerun_pre_event_nonholder_draw_summary.sql

outputs/
  jump_tc_gojo_return_30_pity_d1_d5_fixed_cohort_20260907.pptx
  jump_tc_first_gojo_full_cycle_not_full_awake_rerun_d1_d5_20260907.xlsx
  gojo_first_sale_cohort_and_limited_ticket_balance_20260907.xlsx
```

The SQL was executed through the established `fivecross-data-client` ThinkingData workflow. SQL task configuration, authentication, local build scripts, dependency caches, and inspection artifacts are deliberately not stored in this finalized case directory.

## Deliverable

- `outputs/jump_tc_gojo_return_30_pity_d1_d5_fixed_cohort_20260907.pptx`
  - Six-slide stakeholder-ready review.
  - Covers same-window comparison, fixed historical cohort evidence, retention-conditioned robustness, return-path disclosure, and causal interpretation boundaries.
- `outputs/jump_tc_first_gojo_full_cycle_not_full_awake_rerun_d1_d5_20260907.xlsx`
  - Original-sale incomplete-awakening cohort and rerun D1-D5 behavior.
- `outputs/gojo_first_sale_cohort_and_limited_ticket_balance_20260907.xlsx`
  - First-sale cohort acquisition and limited-ticket balance analysis.

## Interpretation Boundary

The evidence is consistent with a 30-draw pity threshold being associated with deeper observed drawing and pity-cycle completion among participants. It does **not** prove the rule change caused the behavior. Character appeal, rerun status, user resource stock, concurrent content and offers, user composition, and retention selection can all contribute.
