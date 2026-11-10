/*
================================================================================
项目：蜡笔小新 - 广告观看转化与收益统计 (按等级分布)
描述：统计不同等级下，成功观看次数、未看完次数、人数及对应的广告收益 (USD)。
备注：包含内部及Windows测试账号的黑名单过滤。通过窗口函数获取前一条日志的 role_lev。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 获取所有广告日志以及带有 role_lev 的所有日志
AllEvents AS (
    SELECT 
        v."$part_date" AS log_date,
        v."#distinct_id",
        v."$part_event",
        v."#event_time",
        v.role_lev,
        CAST(v.config_id AS VARCHAR) AS config_id,
        CAST(v.status AS INTEGER) AS status,
        CASE WHEN "#os"='Android' THEN CAST(value AS DOUBLE)/1000 ELSE CAST(value AS DOUBLE) END AS ad_value_usd
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE "$part_date" <= '2026-05-11'
      -- 同时拉取广告日志和任何带等级的日志，用于后续补充等级
      AND (v."$part_event" = 'game_ad_impression' OR v.role_lev IS NOT NULL)
      AND ub."#user_id" IS NULL
),

-- 2. 按照用户和时间排序，将最近的一次非空 role_lev 赋给当前行
EventsWithLev AS (
    SELECT
        *,
        LAST_VALUE(role_lev) IGNORE NULLS OVER (
            PARTITION BY "#distinct_id" 
            ORDER BY "#event_time" 
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS current_role_lev
    FROM AllEvents
),

-- 3. 仅过滤出我们要分析的广告日志
AdLogs AS (
    SELECT 
        log_date,
        CASE 
            WHEN current_role_lev IS NULL THEN '未知/无等级记录'
            ELSE CAST(CAST(current_role_lev AS INTEGER) / 10 * 10 AS VARCHAR) || '-' || CAST(CAST(current_role_lev AS INTEGER) / 10 * 10 + 9 AS VARCHAR)
        END AS level_group,
        CASE 
            WHEN current_role_lev IS NULL THEN -1
            ELSE CAST(current_role_lev AS INTEGER) / 10 * 10
        END AS level_group_sort,
        config_id,
        status,
        ad_value_usd,
        "#distinct_id"
    FROM EventsWithLev
    WHERE "$part_event" = 'game_ad_impression'
),

-- 4. 统计在这段时间内，每个等级段出现过多少活跃人数（利用当天的最低和最高等级补全跨段）
UserDailyLevelRange AS (
    SELECT 
        log_date,
        "#distinct_id",
        CAST(MIN(current_role_lev) AS INTEGER) AS min_lev,
        CAST(MAX(current_role_lev) AS INTEGER) AS max_lev
    FROM EventsWithLev
    GROUP BY 1, 2
),

LevelUsersExpanded AS (
    SELECT 
        log_date,
        "#distinct_id",
        CAST(lev_group_id * 10 AS VARCHAR) || '-' || CAST(lev_group_id * 10 + 9 AS VARCHAR) AS level_group
    FROM UserDailyLevelRange
    CROSS JOIN UNNEST(SEQUENCE(min_lev / 10, max_lev / 10)) AS t(lev_group_id)
    WHERE min_lev IS NOT NULL

    UNION ALL 

    SELECT 
        log_date,
        "#distinct_id",
        '未知/无等级记录' AS level_group
    FROM UserDailyLevelRange
    WHERE min_lev IS NULL
),

LevelUsers AS (
    SELECT 
        log_date,
        level_group,
        COUNT(DISTINCT "#distinct_id") AS "到达该等级段人数"
    FROM LevelUsersExpanded
    GROUP BY 1, 2
),

-- 5. 按照填充好的等级(10级一组)进行分组统计广告数据
AdStats AS (
    SELECT 
        log_date,
        level_group,
        level_group_sort,
        COUNT(CASE WHEN status = 1 THEN 1 END) AS "成功观看次数",
        COUNT(CASE WHEN status <> 1 THEN 1 END) AS "未看完次数",
        COUNT(DISTINCT CASE WHEN status = 1 THEN "#distinct_id" END) AS "成功观看人数",
        COUNT(DISTINCT CASE WHEN status <> 1 THEN "#distinct_id" END) AS "未看完人数",
        SUM(CASE WHEN status = 1 THEN ad_value_usd ELSE 0.0 END) AS "成功观看广告费(USD)"
    FROM AdLogs
    GROUP BY log_date, level_group, level_group_sort
)

SELECT 
    a.log_date AS "日期",
    a.level_group AS "等级段(10级一组)",
    l."到达该等级段人数",
    a."成功观看次数",
    a."未看完次数",
    a."成功观看人数",
    a."未看完人数",
    a."成功观看广告费(USD)"
FROM AdStats a
LEFT JOIN LevelUsers l ON a.log_date = l.log_date AND a.level_group = l.level_group
ORDER BY a.log_date DESC, a.level_group_sort DESC;
