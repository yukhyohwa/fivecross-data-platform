/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 2026-07-01 ~ 2026-07-14 每日各群组用户（新用户、回流90天、老用户、新+回流）的 留存 追踪
             - 使用 uuid 作为唯一标识
             - 包含 次留, 3留, 4留, 5留, 6留, 7留, 8留, 15留, 30留, 60留
             - 当前日期未成熟的留存数据会自动留空 (NULL)
================================================================================
*/

WITH Params AS (
    -- 适配 TA (数数) 自定义时间宏，在后台界面直接选择区间
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS start_date,
        MAX(CAST("$part_date" AS DATE)) AS end_date,
        -- 使用 CURRENT_DATE 动态获取当前系统日期，用来判定留存未成熟的天数并留空
        CURRENT_DATE AS data_end_date
    FROM ta.v_event_12
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
),

-- 1. 获取所有用户活跃日志 (包含 login, charge, scroin_buy, srcoin_buy)
DailyLogins AS (
    SELECT DISTINCT
        uuid AS user_id,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_12
    WHERE "$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
      AND uuid IS NOT NULL
      AND uuid <> ''
),

UserStatus AS (
    SELECT
        user_id,
        log_date,
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date) AS prev_log_date,
        MIN(log_date) OVER (PARTITION BY user_id) AS first_log_date
    FROM DailyLogins
),

-- 2. 划分每日群组类型
CohortUsers AS (
    SELECT
        user_id,
        log_date AS cohort_date,
        CASE
            WHEN log_date = first_log_date THEN 'new'
            WHEN prev_log_date IS NOT NULL AND DATE_DIFF('day', prev_log_date, log_date) >= 90 THEN 'return'
            ELSE 'old'
        END AS cohort_type
    FROM UserStatus
    CROSS JOIN Params p
    WHERE log_date BETWEEN p.start_date AND p.end_date
),

-- 3. 关联活跃天数 (计算第几天留存)
CohortRetention AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        DATE_DIFF('day', c.cohort_date, p.data_end_date) AS mature_days,
        DATE_DIFF('day', c.cohort_date, l.log_date) AS retain_day
    FROM CohortUsers c
    CROSS JOIN Params p
    LEFT JOIN DailyLogins l
        ON c.user_id = l.user_id
       AND l.log_date > c.cohort_date -- 留存只看次日及以后的活跃
       AND DATE_DIFF('day', c.cohort_date, l.log_date) <= 59
),

-- 4. 计算每个用户的各阶段留存达标情况
UserRetentionAgg AS (
    SELECT
        user_id,
        cohort_date,
        cohort_type,
        MAX(mature_days) AS mature_days,
        MAX(CASE WHEN retain_day = 1 THEN 1 ELSE 0 END) AS retain_d1,
        MAX(CASE WHEN retain_day = 2 THEN 1 ELSE 0 END) AS retain_d2,
        MAX(CASE WHEN retain_day = 3 THEN 1 ELSE 0 END) AS retain_d3,
        MAX(CASE WHEN retain_day = 4 THEN 1 ELSE 0 END) AS retain_d4,
        MAX(CASE WHEN retain_day = 5 THEN 1 ELSE 0 END) AS retain_d5,
        MAX(CASE WHEN retain_day = 6 THEN 1 ELSE 0 END) AS retain_d6,
        MAX(CASE WHEN retain_day = 7 THEN 1 ELSE 0 END) AS retain_d7,
        MAX(CASE WHEN retain_day = 14 THEN 1 ELSE 0 END) AS retain_d14,
        MAX(CASE WHEN retain_day = 29 THEN 1 ELSE 0 END) AS retain_d29,
        MAX(CASE WHEN retain_day = 59 THEN 1 ELSE 0 END) AS retain_d59
    FROM CohortRetention
    GROUP BY 1, 2, 3
),

-- 5. 聚合为按群组计算的留存总量 (这里包含新用户、回流、老用户，以及特殊组合)
CohortAggregation AS (
    -- 分别聚合新用户、回流用户、老用户
    SELECT
        cohort_date,
        cohort_type,
        COUNT(DISTINCT user_id) AS users,
        MAX(mature_days) AS mature_days,
        SUM(retain_d1) AS total_retain_d1,
        SUM(retain_d2) AS total_retain_d2,
        SUM(retain_d3) AS total_retain_d3,
        SUM(retain_d4) AS total_retain_d4,
        SUM(retain_d5) AS total_retain_d5,
        SUM(retain_d6) AS total_retain_d6,
        SUM(retain_d7) AS total_retain_d7,
        SUM(retain_d14) AS total_retain_d14,
        SUM(retain_d29) AS total_retain_d29,
        SUM(retain_d59) AS total_retain_d59
    FROM UserRetentionAgg
    GROUP BY 1, 2
    
    UNION ALL
    
    -- 聚合合并组：新用户 + 回流用户
    SELECT
        cohort_date,
        'new+return' AS cohort_type,
        COUNT(DISTINCT user_id) AS users,
        MAX(mature_days) AS mature_days,
        SUM(retain_d1) AS total_retain_d1,
        SUM(retain_d2) AS total_retain_d2,
        SUM(retain_d3) AS total_retain_d3,
        SUM(retain_d4) AS total_retain_d4,
        SUM(retain_d5) AS total_retain_d5,
        SUM(retain_d6) AS total_retain_d6,
        SUM(retain_d7) AS total_retain_d7,
        SUM(retain_d14) AS total_retain_d14,
        SUM(retain_d29) AS total_retain_d29,
        SUM(retain_d59) AS total_retain_d59
    FROM UserRetentionAgg
    WHERE cohort_type IN ('new', 'return')
    GROUP BY 1
),

-- 6. 格式化最终输出，转为百分比
FinalOutput AS (
    SELECT
        CAST(cohort_date AS VARCHAR) AS "日期",
        CASE 
            WHEN cohort_type = 'new' THEN '1.新用户'
            WHEN cohort_type = 'return' THEN '2.回流用户(90天)'
            WHEN cohort_type = 'new+return' THEN '3.新用户+回流用户'
            WHEN cohort_type = 'old' THEN '4.老用户'
        END AS "用户类型",
        users AS "人数",
        
        -- Retention (留存率)
        -- 使用 mature_days 判断是否成熟，不成熟的天数输出为 NULL
        CASE WHEN mature_days >= 1 THEN CAST(ROUND(TRY(total_retain_d1 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "次留",
        CASE WHEN mature_days >= 2 THEN CAST(ROUND(TRY(total_retain_d2 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "3留",
        CASE WHEN mature_days >= 3 THEN CAST(ROUND(TRY(total_retain_d3 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "4留",
        CASE WHEN mature_days >= 4 THEN CAST(ROUND(TRY(total_retain_d4 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "5留",
        CASE WHEN mature_days >= 5 THEN CAST(ROUND(TRY(total_retain_d5 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "6留",
        CASE WHEN mature_days >= 6 THEN CAST(ROUND(TRY(total_retain_d6 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "7留",
        CASE WHEN mature_days >= 7 THEN CAST(ROUND(TRY(total_retain_d7 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "8留",
        CASE WHEN mature_days >= 13 THEN CAST(ROUND(TRY(total_retain_d14 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "14留",
        CASE WHEN mature_days >= 29 THEN CAST(ROUND(TRY(total_retain_d29 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "30留",
        CASE WHEN mature_days >= 59 THEN CAST(ROUND(TRY(total_retain_d59 * 100.0 / NULLIF(users, 0)), 2) AS VARCHAR) || '%' END AS "60留"
    FROM CohortAggregation
)

SELECT * FROM FinalOutput
ORDER BY "日期", "用户类型";
