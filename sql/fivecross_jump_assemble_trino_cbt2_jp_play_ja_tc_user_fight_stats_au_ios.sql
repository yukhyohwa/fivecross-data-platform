/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 玩法/对局参与度统计 (支持模式、玩法、对手类型过滤)
             仅统计 iOS 用户，排除黑名单
Environment: Trino (TA - v_event_16)
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- iOS 用户白名单
--------------------------------------------------------------------------------
iOSUsers AS (
    SELECT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name = 'fixed_os'
      AND tag_value     = 'iOS'
),

--------------------------------------------------------------------------------
-- 战斗事件明细
--------------------------------------------------------------------------------
FightLogs AS (
    SELECT
        ${Selector:timetype} time_dimension,
        CASE
            WHEN ${Selector:model_type} THEN '全部模式'
            ELSE
                CASE
                    WHEN model_type = 1 THEN '休闲赛'
                    WHEN model_type = 2 THEN '排位赛'
                    WHEN model_type = 3 THEN '自定义'
                    WHEN model_type = 5 THEN '漫斗赛'
                    ELSE '其他'
                END
        END AS model_type,

        CASE
            WHEN ${Selector:game_type} THEN '全部玩法'
            ELSE
                CASE
                    WHEN game_type = 1  THEN '卷轴争夺'
                    WHEN game_type = 2  THEN '单人乱斗'
                    WHEN game_type = 3  THEN '双人乱斗'
                    WHEN game_type = 4  THEN '武道会'
                    WHEN game_type = 5  THEN '积分争夺'
                    WHEN game_type = 7  THEN '咒术高专'
                    WHEN game_type = 9  THEN '顶上战争'
                    WHEN game_type = 10 THEN '无限列车'
                    WHEN game_type = 11 THEN '淘汰赛'
                    WHEN game_type = 12 THEN '忍界大战'
                    WHEN game_type = 15 THEN '龙珠之争'
                    WHEN game_type = 16 THEN '爆破对决'
                    ELSE '其他'
                END
        END AS game_type,

        CASE
            WHEN ${Selector:user_type} THEN '全部对手'
            ELSE
                CASE
                    WHEN robot_num >= 1 THEN '机器人对手'
                    ELSE '真实对手'
                END
        END AS user_type,

        COALESCE(s1.sdkcommon.lcx_id, s1.lcxsdkcommon.lcx_id) lcx_id,
        s1."#event_time"
    FROM ta.v_event_16 s1
    -- 仅 iOS 用户
    INNER JOIN iOSUsers ios ON COALESCE(s1.sdkcommon.lcx_id, s1.lcxsdkcommon.lcx_id)= ios.lcx_id
    -- 排除黑名单
    LEFT JOIN UserBlacklist bl ON COALESCE(s1.sdkcommon.lcx_id, s1.lcxsdkcommon.lcx_id) = bl.lcx_id
    WHERE ${PartDate:date1}
      AND s1."$part_event" = 'arena_fight'
      AND model_type IN (1, 2, 3, 5)
      AND game_type  IN (1, 2, 3, 4, 5, 7, 9, 10, 11, 12, 13, 14, 15, 16)
      AND bl.lcx_id IS NULL
),

--------------------------------------------------------------------------------
-- 基准用户数（分母）
--------------------------------------------------------------------------------
DailyBase AS (
    SELECT
        time_dimension,
        COUNT(DISTINCT lcx_id) AS daily_total_users
    FROM FightLogs
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 日期范围标签
--------------------------------------------------------------------------------
DateRange AS (
    SELECT
        ${Selector:timetype}                                            AS time_dimension,
        CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date"))      AS date_range
    FROM ta.v_event_16 s1
    WHERE s1."$part_event" = 'LOGIN_SUCCESS'
      AND ${PartDate:date1}
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 最终输出
--------------------------------------------------------------------------------
SELECT 
    t1.time_dimension,
    t3.date_range,
    t1.model_type,
    t1.game_type,
    t1.user_type,
    
    COUNT(DISTINCT CAST(t1.lcx_id AS VARCHAR) || CAST(t1."#event_time" AS VARCHAR)) AS fight_cnt,
    COUNT(DISTINCT t1.lcx_id) AS user_cnt,
    CAST(COUNT(DISTINCT t1.lcx_id) AS DOUBLE) / NULLIF(MAX(t2.daily_total_users), 0) AS participation_rate,
    CAST(COUNT(DISTINCT CAST(t1.lcx_id AS VARCHAR) || CAST(t1."#event_time" AS VARCHAR)) AS DOUBLE) / NULLIF(MAX(t2.daily_total_users), 0) AS avg_fights_per_base
    
FROM FightLogs t1
LEFT JOIN DailyBase t2 ON t1.time_dimension = t2.time_dimension
LEFT JOIN DateRange t3 ON t1.time_dimension = t3.time_dimension
GROUP BY 1, 2, 3, 4, 5
ORDER BY 2, 3, 4;