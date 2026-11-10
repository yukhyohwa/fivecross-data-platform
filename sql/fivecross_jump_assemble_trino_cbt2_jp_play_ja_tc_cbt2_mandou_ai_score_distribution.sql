/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 4/15 - 4/23 漫斗赛-积分赛 (model_type=5, game_type=5) AI局比分分布
Date    : 2026-04-15 to 2026-04-23
Grouping:
  - 赢家得分固定为10分，输家得分来自 client_customs_pass 的 ji_fen.fail_camp_score
  - 筛选条件：有机器人的对局 (robot_num >= 1)
================================================================================
*/

WITH
-- 1. 获取积分赛中输家的得分 (赢家固定10分)
--    按 battle_id 去重，防止同一场多次触发导致重复
LoserScore AS (
    SELECT
        battle_id,
        MAX(CAST(ji_fen.fail_camp_score AS INTEGER)) AS fail_camp_score
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
      AND "$part_event" = 'client_customs_pass'
      AND CAST(model_type AS INTEGER) = 5
      AND CAST(game_type AS INTEGER) = 5
    GROUP BY battle_id
),

-- 2. 获取期间内积分赛的战斗局，标记是否为AI局
--    使用 arena_fight 获取 robot_num
AiMatches AS (
    SELECT
        battle_id,
        MAX(CAST(COALESCE(robot_num, 0) AS INTEGER)) AS max_robot_num
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
      AND "$part_event" = 'arena_fight'
      AND CAST(model_type AS INTEGER) = 5
      AND CAST(game_type AS INTEGER) = 5
      AND robot_num >0
    GROUP BY battle_id
)

-- 3. 关联并统计AI局的比分分布
SELECT 
    10 AS "赢家得分 (固定)",
    COALESCE(ls.fail_camp_score, 0) AS "输家得分",
    (10 - COALESCE(ls.fail_camp_score, 0)) AS "分差",
    COUNT(DISTINCT ls.battle_id) AS "AI对局数量",
    ROUND(CAST(COUNT(DISTINCT ls.battle_id) AS DOUBLE) / SUM(COUNT(DISTINCT ls.battle_id)) OVER() * 100, 2) AS "数量占比(%)"
FROM LoserScore ls
INNER JOIN AiMatches am ON ls.battle_id = am.battle_id
WHERE am.max_robot_num >= 1  -- 筛选包含AI的对局
GROUP BY COALESCE(ls.fail_camp_score, 0)
ORDER BY "输家得分" ASC;
