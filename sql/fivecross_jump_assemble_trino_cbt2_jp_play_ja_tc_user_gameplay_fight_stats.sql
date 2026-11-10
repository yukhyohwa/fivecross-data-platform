/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 玩法/对局参与度统计 (支持模式、玩法、对手类型过滤)
Environment: Trino (TA - v_event_16)
================================================================================
*/

WITH 
FightLogs AS (
    SELECT 
        ${Selector:timetype} time_dimension,
        CASE 
            WHEN ${Selector:model_type}  THEN '全部模式'
            ELSE 
                CASE 
                    WHEN model_type = 1 THEN '休闲赛'
                    WHEN model_type = 2 THEN '排位赛'
                    WHEN model_type = 3 THEN '自定义'
                    ELSE '其他' 
                END
        END AS model_type,
        
        CASE 
            WHEN ${Selector:game_type}  THEN '全部玩法'
            ELSE 
                CASE 
                    WHEN game_type = 1 THEN '卷轴争夺'
                    WHEN game_type = 2 THEN '单人乱斗'
                    WHEN game_type = 3 THEN '双人乱斗'
                    WHEN game_type = 4 THEN '武道会'
                    WHEN game_type = 5 THEN '积分争夺'
                    WHEN game_type = 7 THEN '咒术高专'
                    WHEN game_type = 9 THEN '顶上战争'
                    WHEN game_type = 10 THEN '无限列车'
                    WHEN game_type = 11 THEN '淘汰赛'
                    WHEN game_type = 12 THEN '忍界大战'
                    WHEN game_type = 13 THEN '龙珠之争'
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
        "#account_id",
        "#event_time"
    FROM ta.v_event_16 s1
    WHERE ${PartDate:date1} 
    AND "$part_event" = 'arena_fight'
    AND model_type IN (1,2,3)
    AND game_type IN (1,2,3,4,5,7,9,10,11,12,13)
),

DailyBase AS (
    SELECT 
        time_dimension,
        COUNT(DISTINCT "#account_id") AS daily_total_users
    FROM FightLogs s1
    GROUP BY 1
),

DateRange AS(
    SELECT ${Selector:timetype} time_dimension,CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) date_range
    FROM ta.v_event_16 s1
    WHERE "$part_event" = 'LOGIN_SUCCESS'
    AND ${PartDate:date1}
    GROUP BY 1
)

SELECT 
    t1.time_dimension AS "时间维度",
    t3.date_range AS "日期范围",
    t1.model_type AS "模式类型",
    t1.game_type AS "玩法类型",
    t1.user_type AS "对手类型",
    
    COUNT(DISTINCT CAST(t1."#account_id" AS VARCHAR) || CAST(t1."#event_time" AS VARCHAR)) AS "对局次数",
    COUNT(DISTINCT t1."#account_id") AS "参与人数",
    CAST(COUNT(DISTINCT t1."#account_id") AS DOUBLE) / NULLIF(MAX(t2.daily_total_users), 0) AS "参与率",
    CAST(COUNT(DISTINCT CAST(t1."#account_id" AS VARCHAR) || CAST(t1."#event_time" AS VARCHAR)) AS DOUBLE) / NULLIF(MAX(t2.daily_total_users), 0) AS "人均对局数"
    
FROM FightLogs t1
LEFT JOIN DailyBase t2 ON t1.time_dimension = t2.time_dimension
LEFT JOIN DateRange t3 ON t1.time_dimension = t3.time_dimension
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC, 3, 4;
