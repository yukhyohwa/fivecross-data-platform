/* 
================================================================================
项目：Jump Assemble (众星之聚) - TC CBT2
描述：首日时长与次日留存的关系 (心跳法改进版 - 纯 #user_id 标识)
     使用数数自带的 #user_id，对 4/15 活跃的 iOS 用户进行时长分段，并计算次日(4/16)的留存率。
================================================================================
*/
WITH TargetUsers AS (
    -- 1. 定义目标人群：4月15日出现过的活跃用户 (iOS)
    SELECT 
        DISTINCT "#user_id",
        "$part_date" AS target_date
    FROM ta.v_event_16
    WHERE "$part_date" = '2026-04-15'
      AND (LOWER(os) LIKE '%ios%' OR LOWER(os) LIKE '%ipados%' OR "ostype" = 'iOS' OR "#os" = 'iOS')
),

-- 2. 提取这些用户 4/15 的事件并计算相邻时间差 (心跳法改进版)
UserLogs AS (
    SELECT 
        v."#user_id",
        tu.target_date,
        to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) AS t,
        LEAD(to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))) OVER (
            PARTITION BY v."#user_id", v."$part_date"
            ORDER BY v."#event_time"
        ) 
        - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) AS gap
    FROM ta.v_event_16 v
    INNER JOIN TargetUsers tu ON v."#user_id" = tu."#user_id" AND v."$part_date" = tu.target_date
    WHERE v."#event_name" NOT LIKE '%app%'
),

-- 3. 汇总每人的首日总时长 (秒，间隔 < 120秒才计入)
UserDuration AS (
    SELECT 
        "#user_id",
        target_date,
        SUM(CASE WHEN gap < 120 THEN gap ELSE 0 END) AS total_seconds
    FROM UserLogs
    GROUP BY 1, 2
),

-- 4. 时长分段
UserDurationGroup AS (
    SELECT 
        "#user_id",
        target_date,
        total_seconds,
        CASE 
            WHEN total_seconds < 300 THEN '01_0-5min'
            WHEN total_seconds >= 300 AND total_seconds < 600 THEN '02_5-10min'
            WHEN total_seconds >= 600 AND total_seconds < 900 THEN '03_10-15min'
            WHEN total_seconds >= 900 AND total_seconds < 1800 THEN '04_15-30min'
            WHEN total_seconds >= 1800 AND total_seconds < 3600 THEN '05_30-60min'
            WHEN total_seconds >= 3600 AND total_seconds < 7200 THEN '06_60-120min'
            WHEN total_seconds >= 7200 THEN '07_120min以上'
            ELSE '08_未知(可能为0)'
        END AS duration_group
    FROM UserDuration
),

-- 5. 次日留存判定 (4/16 是否活跃)
RetainedUsers AS (
    SELECT 
        DISTINCT v."#user_id",
        tu.target_date
    FROM ta.v_event_16 v
    INNER JOIN TargetUsers tu ON v."#user_id" = tu."#user_id"
    WHERE CAST(v."$part_date" AS DATE) = DATE_ADD('day', 1, CAST(tu.target_date AS DATE))
)

-- 6. 最终汇总输出
SELECT 
    dg.duration_group AS "首日时长区间",
    COUNT(DISTINCT dg."#user_id") AS "首日活跃人数",
    COUNT(DISTINCT ru."#user_id") AS "次日留存人数",
    CAST(COUNT(DISTINCT ru."#user_id") AS DOUBLE) / COUNT(DISTINCT dg."#user_id") AS "次日留存率"
FROM UserDurationGroup dg
LEFT JOIN RetainedUsers ru ON dg."#user_id" = ru."#user_id" AND dg.target_date = ru.target_date
GROUP BY 1
ORDER BY 1 ASC;
