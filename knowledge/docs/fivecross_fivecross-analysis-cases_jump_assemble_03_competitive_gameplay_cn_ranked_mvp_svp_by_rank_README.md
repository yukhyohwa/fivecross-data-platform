# Jump Assemble CN ranked MVP / SVP score by rank

## Scope

- Product: Jump Assemble Simplified Chinese CB / 数数 China
- Source: ThinkingData / Trino, `ta.v_event_4`; client task explicitly uses `engine=ta`, `region=china`
- Verified complete available ranked (`model_type = 2`) arena-fight coverage: **2026-01-09 to 2026-08-28**
- Population: account-level `arena_fight` player records; excluded users labelled `internal_users` or `is_water` in `user_result_cluster_4`

## Definitions

- **真人局**: a `battle_id` where `MAX(robot_num) = 0`.
- **机器人局**: a `battle_id` where `MAX(robot_num) > 0`.
- **MVP**: event field `mvp = true`.
- **SVP**: the player with the highest positive `score / 1000` on the losing side of the same `battle_id`; equal scores use ascending account ID as a deterministic tie-breaker. Winning sides follow the existing Jump MVP/SVP library logic by `game_type` and `rank`.
- This deliverable preserves every observed score as an exact-score frequency by **32 rank levels × match population × honor type**, rather than exporting player IDs. This avoids exceeding Excel's 1,048,576-row limit while retaining the complete score distribution.

## Files

- `sql/ja_cn_ranked_mvp_svp_by_rank_20260109_20260828.sql` — reproducible extraction SQL.
- `outputs/JUMP_CN_CB_排位_MVP_SVP评分_按段位_20260109_20260828.xlsx` — delivery workbook.
- `outputs/ja_cn_ranked_mvp_svp_by_rank_20260109_20260828.csv` — source query output.

## Execution

```text
C:/Users/5xgames/Desktop/github/fivecross-data-client/venv/Scripts/python.exe main.py fetch --task ja_cn_ranked_mvp_svp_by_rank_20260109_20260828.json --show
```
