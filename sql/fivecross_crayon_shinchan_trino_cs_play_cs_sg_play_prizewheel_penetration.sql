/*
================================================================================
项目：蜡笔小新 - 转盘活动 (prizewheel) 渗透率与参与深度统计
指标：参与人数、转盘总次数、人均次数、活跃人数(AU)、参与率 (Penetration)
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 转盘行为统计
PrizewheelLogs AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        SUM(COALESCE(v.len, 1)) AS total_draw_times,
        COUNT(DISTINCT v."#account_id") AS draw_user_count
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" = 'prizewheel'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1
),

-- 2. 活跃用户基数 (AU)
ActiveUsers AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        COUNT(DISTINCT v."#account_id") AS active_user_count
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" = 'login' -- 使用登录事件作为活跃判定
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1
)

-- 3. 结果汇总
SELECT 
    p.time_dimension AS "时间维度",
    p.draw_user_count AS "转盘参与人数",
    p.total_draw_times AS "转盘总次数",
    CAST(p.total_draw_times AS DOUBLE) / NULLIF(p.draw_user_count, 0) AS "人均转盘次数",
    a.active_user_count AS "活跃人数(AU)",
    CAST(p.draw_user_count AS DOUBLE) / NULLIF(a.active_user_count, 0) AS "转盘渗透率"
FROM PrizewheelLogs p
LEFT JOIN ActiveUsers a ON p.time_dimension = a.time_dimension
ORDER BY 1 DESC;
