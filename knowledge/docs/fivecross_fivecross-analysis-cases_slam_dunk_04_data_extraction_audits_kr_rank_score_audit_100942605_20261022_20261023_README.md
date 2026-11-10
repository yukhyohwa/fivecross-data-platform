# KR Slam Dunk screenshot battle-log audit — player 100942605

## Scope and verified source

- **Player ID:** `100942605`; **ThinkingData identity:** `ali_tt_10008@100942605`.
- **Screenshot scope:** 11 backend-log rows on 2026-10-22: one `Honor Prize` and ten `win Battle` / `loss Battle` rows.
- **Source:** migrated KR ThinkingData event stream `ta.v_event_22`, executed through the existing FiveCross data client.

The earlier narrow lifecycle export in this directory contains unrelated later matches. It must not be used for the supplied screenshot. This audit resolves the screenshot battle IDs directly.

## Verified result

All 11 screenshot rows match a player `match_fight` event. The ten battle records are **nine wins (+1 each)** and **one loss (−1)**. The `Honor Prize` row resolves to a preceding win with a `comm#star` increase of **+2**.

The loss ID is exactly **`10115351088070097083135`**; prefix lookup resolved the initially ambiguous final digits.

The screenshot’s clock corresponds approximately to ThinkingData `#event_time + 1 hour` for the first ten rows, with a 57–59 second reporting delay. The final row has a further 96-second delay. The screenshot time is consequently not assumed to be KST.

## Deliverables

- `output/kr_rank_screenshot_full_log_audit_20261022.xlsx`
  - `screenshot_full_log`: joined evidence for all 11 screenshot rows.
  - `player_10_battle_logs`: player-only battle records.
  - `all_10_battles_players`: all 60 participant records (10 × 6).
- `output/kr_rank_screenshot_full_log_audit_20261022.csv` — joined 11-row audit table.
- `output/kr_rank_screenshot_all_participants_20261022.csv` — all participant rows.
- `sql/kr_ta_screenshot_battle_ids_exact_lookup.sql`, `kr_ta_loss_row_id_prefix_lookup.sql`, and `kr_ta_honor_prize_battle_exact_lookup.sql` — reproducible queries.

## Legacy raw-server check

The configured legacy ODPS `g33002013.daily_game_log` returned no rows for 2026-10-20 through 2026-10-24, including these IDs. This deliverable therefore preserves migrated event payloads rather than fabricating a raw-server result.

All battle IDs and participant identifiers are written as **text** in XLSX/CSV so Excel cannot convert them to scientific notation or zero their tail digits.
