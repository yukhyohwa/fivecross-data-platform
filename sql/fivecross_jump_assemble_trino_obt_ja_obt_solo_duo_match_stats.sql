/*
================================================================================
Game    : Jump Assemble - OBT
Report  : 排位单双排匹配与 3 人组队碰撞分析 (Solo/Duo Match & Opponent Trio Analysis)
Description:
          - 统计排位真人局中 (robot_num=0) 单排玩家在不同段位层级 (00-20, 21+) 上的匹配分布与对局胜率
================================================================================
*/

/*
-- Python 验证脚本说明与口径定义:
-- population: robot_num=0 排位真人局中的单排玩家记录
-- ladder: arena_fight.player_ladder_level >= 21
-- strict_opponent_trio: 对方恰有3名观测玩家，且3人的 team_member_num 均为3
*/

WITH MatchBase AS (
    SELECT
        CAST("$part_date" AS DATE) AS log_date,
        battle_id,
        rolecommon.role_id AS lcx_id,
        TRY_CAST(player_ladder_level AS INTEGER) AS player_ladder_level,
        CASE 
            WHEN TRY_CAST(player_ladder_level AS INTEGER) >= 21 THEN '21+'
            WHEN TRY_CAST(player_ladder_level AS INTEGER) >= 16 THEN '16-20'
            ELSE '00-15'
        END AS ladder_group,
        is_win
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type = 2 -- 排位赛
      AND robot_num = 0  -- 真人局
      AND battle_id IS NOT NULL
)

SELECT
    log_date AS "日期",
    ladder_group AS "段位分组",
    COUNT(DISTINCT lcx_id) AS "单排玩家数",
    COUNT(DISTINCT battle_id) AS "单排场次",
    SUM(CASE WHEN is_win = 1 THEN 1 ELSE 0 END) AS "胜场数",
    CAST(SUM(CASE WHEN is_win = 1 THEN 1 ELSE 0 END) AS DOUBLE) / NULLIF(COUNT(*), 0) AS "胜率"
FROM MatchBase
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
