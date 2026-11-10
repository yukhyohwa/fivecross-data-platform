/*
================================================================================
项目：蜡笔小新 - 各副本与玩法参与深度及渗透率统计
指标：日期、玩法名称、参与人数、参与次数、人均参与次数、活跃人数(AU)、渗透率
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- [新增] 提取新加坡用户白名单
SingaporeUsers AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country' AND tag_value = '新加坡'
),

-- 玩法名称维表
DimStage AS (
    SELECT * FROM (VALUES
        (1001,'主线副本'),
        (1002,'挑战玩具小偷'),
        (1003,'挑战怪物扭蛋人'),
        (1005,'守护古老城市'),
        (1004,'竞技场'),
        (1018,'挑战邪恶的兔兔玩偶'),
        (1019,'挑战邪恶喵巴士'),
        (1006,'守护海滩'),
        (1007,'恐龙拳手大挑战'),
        (1022,'花圃内pvp副本'),
        (1008,'影像副本'),
        (1023,'切磋'),
        (1009,'穿越魔法之门'),
        (1021,'积木大乱斗'),
        (1024,'跨服竞技场'),
        (1010,'宝物预览副本'),
        (1011,'忍道・甜酸试炼'),
        (1012,'冒险试炼'),
        (1013,'宠物旅行'),
        (1014,'动感超人试炼—钻地土拨鼠'),
        (1015,'动感超人试炼—挖铲土拨鼠'),
        (1016,'动感超人试炼—挖矿土拨鼠'),
        (1017,'动感超人比赛'),
        (1020,'社团大评比')
    ) AS t(stage_type, stage_name)
),

-- 1. 活跃用户基数 (AU)
ActiveUsers AS (
    SELECT 
        v."$part_date" AS time_dimension, -- 统一改为按日
        COUNT(DISTINCT v."#account_id") AS active_user_count
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN SingaporeUsers su ON v."#user_id" = su."#user_id" -- 仅保留新加坡用户
    WHERE v."$part_event" = 'login'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1
),

-- 2. 副本战斗行为统计
StageLogs AS (
    SELECT 
        v."$part_date" AS time_dimension, -- 统一改为按日
        CAST(v.a_rst[1].key AS VARCHAR) AS stage_type,
        COUNT(1) AS fight_times,
        COUNT(DISTINCT v."#account_id") AS fight_users
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN SingaporeUsers su ON v."#user_id" = su."#user_id" -- 仅保留新加坡用户
    WHERE v."#event_name" = 'stage_fight'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1, 2
    
    UNION ALL 
    
    SELECT 
        v."$part_date" AS time_dimension, -- 统一改为按日
        CASE 
            WHEN v."#event_name" = 'match3_combo' THEN '三消'
            WHEN v."#event_name" = 'pet_travel_start' THEN '宠物旅行'
            WHEN v."#event_name" = 'board_tile_land' THEN '大富翁'
        END AS stage_type,
        COUNT(1) AS fight_times,
        COUNT(DISTINCT v."#account_id") AS fight_users
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN SingaporeUsers su ON v."#user_id" = su."#user_id" -- 仅保留新加坡用户
    WHERE v."#event_name" IN ('match3_combo','pet_travel_start','board_tile_land')
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1, 2
)

-- 3. 最终结果聚合
SELECT 
    s.time_dimension AS "时间维度",
    COALESCE(ds.stage_name, s.stage_type) AS "玩法名称",
    s.fight_users AS "参与人数",
    s.fight_times AS "参与次数",
    CAST(s.fight_times AS DOUBLE) / NULLIF(s.fight_users, 0) AS "人均参与次数",
    a.active_user_count AS "全服活跃人数",
    CAST(s.fight_users AS DOUBLE) / NULLIF(a.active_user_count, 0) AS "参与渗透率"
FROM StageLogs s
LEFT JOIN DimStage ds ON s.stage_type = CAST(ds.stage_type AS VARCHAR)
LEFT JOIN ActiveUsers a ON s.time_dimension = a.time_dimension
ORDER BY 1 DESC, 4 DESC;
