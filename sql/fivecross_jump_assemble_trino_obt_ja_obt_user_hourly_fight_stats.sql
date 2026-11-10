/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 每日分时战斗行为统计 (不限新用户)
Description: 统计指定日期 ${PartDate:date1} 内，所有活跃玩家在各个小时段 (0-23) 里的战斗情况。
             包含指标：分时活跃人数、时人均总战斗次数、时人均排位/漫斗及各漫斗玩法的细分人均次数。
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    -- 排除测试与水军黑名单
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

FightLogs AS (
    -- 1. 提取目标日期内所有正常玩家的战斗明细 (分时)
    SELECT
        COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id) AS lcx_id,
        v."$part_date"                                       AS fight_date,
        HOUR(CAST(v."#event_time" AS TIMESTAMP))             AS fight_hour,
        v.model_type,
        v.game_type
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub 
        ON COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id) = ub.lcx_id 
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'arena_fight'
      AND ub.lcx_id IS NULL
)

-- 2. 按日期与小时聚合战斗指标
SELECT
    fight_date AS "日期",
    fight_hour AS "小时",
    COUNT(DISTINCT lcx_id) AS "有战斗记录人数",
    
    ROUND(CAST(COUNT(*) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "人均总战斗次数",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "人均漫斗赛次数",
    ROUND(CAST(COUNT(CASE WHEN model_type = 2 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "人均排位赛次数",
    
    -- 漫斗赛各玩法日人均 (model_type = 5 下的 game_type)
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 1  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-卷轴争夺",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 2  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-单人乱斗",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 3  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-双人乱斗",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 4  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-武道会",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 5  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-积分争夺",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 7  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-咒术高专",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 9  THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-顶上战争",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 10 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-无限列车",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 11 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-淘汰赛",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 12 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-忍界大战",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 15 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-龙珠之争",
    ROUND(CAST(COUNT(CASE WHEN model_type = 5 AND game_type = 16 THEN 1 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0), 2) AS "漫斗赛-爆破对决"
FROM FightLogs
GROUP BY 1, 2
ORDER BY 1 ASC, 2 ASC;
