/*
================================================================================
项目：蜡笔小新繁体 - 各副本与玩法参与深度及渗透率
口径：以 login 的 #account_id 为活跃角色基数；战斗和玩法同样以 #account_id 去重。
      排除 internal_users、is_windows、is_water 三类测试/异常用户。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),
DimStage AS (
    SELECT * FROM (VALUES
        (1001, '主线副本'), (1002, '挑战玩具小偷'), (1003, '挑战怪物扭蛋人'),
        (1004, '竞技场'), (1005, '守护古老城市'), (1006, '守护海滩'),
        (1007, '恐龙拳手大挑战'), (1008, '影像副本'), (1009, '穿越魔法之门'),
        (1010, '宝物预览副本'), (1011, '忍道・甜酸试炼'), (1012, '冒险试炼'),
        (1013, '宠物旅行'), (1014, '动感超人试炼—钻地土拨鼠'),
        (1015, '动感超人试炼—挖铲土拨鼠'), (1016, '动感超人试炼—挖矿土拨鼠'),
        (1017, '动感超人比赛'), (1018, '挑战邪恶的兔兔玩偶'),
        (1019, '挑战邪恶喵巴士'), (1020, '社团大评比'), (1021, '积木大乱斗'),
        (1022, '花圃内pvp副本'), (1023, '切磋'), (1024, '跨服竞技场')
    ) AS t(stage_type, stage_name)
),
ActiveUsers AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        COUNT(DISTINCT v."#account_id") AS active_user_count
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."$part_event" = 'login' AND v.${PartDate:date1} AND ub.user_id IS NULL
    GROUP BY 1
),
StageLogs AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        CAST(v.a_rst[1].key AS VARCHAR) AS stage_type,
        COUNT(*) AS fight_times,
        COUNT(DISTINCT v."#account_id") AS fight_users
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."#event_name" = 'stage_fight' AND v.${PartDate:date1} AND ub.user_id IS NULL
    GROUP BY 1, 2

    UNION ALL

    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END,
        CASE WHEN v."#event_name" = 'match3_combo' THEN '三消'
             WHEN v."#event_name" = 'pet_travel_start' THEN '宠物旅行'
             WHEN v."#event_name" = 'board_tile_land' THEN '大富翁' END,
        COUNT(*), COUNT(DISTINCT v."#account_id")
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."#event_name" IN ('match3_combo', 'pet_travel_start', 'board_tile_land')
      AND v.${PartDate:date1} AND ub.user_id IS NULL
    GROUP BY 1, 2
)
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
