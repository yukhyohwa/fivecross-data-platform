/*
================================================================================
Game: Kuroko's Basketball (繁體黑子)
Region: TC (Traditional Chinese)
Description: 041. 每日用戶留存 (Daily Retention: New, Returning, Total)
Metrics: Day 1 (Next Day), Day 3, Day 7 Retention
================================================================================
*/

WITH FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),
DailyLogins AS (
    SELECT DISTINCT 
        "#user_id" AS user_id, 
        "$part_date" AS log_date
    FROM ta.v_event_10
    WHERE "$part_event" = 'login'
      AND "$part_date" >= '2025-12-01' -- Look back to define reg/return status
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),
UserStatus AS (
    SELECT 
        user_id,
        log_date,
        MIN(log_date) OVER (PARTITION BY user_id) AS reg_date,
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date ASC) AS prev_log_date
    FROM DailyLogins
),
Cohorts AS (
    SELECT 
        user_id,
        log_date AS cohort_date,
        CASE 
            WHEN log_date = reg_date THEN 'New User'
            WHEN date_diff('day', CAST(prev_log_date AS DATE), CAST(log_date AS DATE)) >= 30 THEN 'Return User'
        END AS user_type
    FROM UserStatus
    WHERE log_date = reg_date 
       OR date_diff('day', CAST(prev_log_date AS DATE), CAST(log_date AS DATE)) >= 30
),
ExpandedCohorts AS (
    SELECT user_id, cohort_date, user_type FROM Cohorts
    UNION ALL
    SELECT user_id, cohort_date, 'Total (New+Return)' AS user_type FROM Cohorts
),
RetentionCalculated AS (
    SELECT 
        c.cohort_date,
        c.user_type,
        COUNT(DISTINCT c.user_id) AS cohort_size,
        COUNT(DISTINCT CASE WHEN date_diff('day', CAST(c.cohort_date AS DATE), CAST(l.log_date AS DATE)) = 1 THEN l.user_id END) AS day1_active,
        COUNT(DISTINCT CASE WHEN date_diff('day', CAST(c.cohort_date AS DATE), CAST(l.log_date AS DATE)) = 2 THEN l.user_id END) AS day2_active, -- For 3rd day (Day 2 gap)
        COUNT(DISTINCT CASE WHEN date_diff('day', CAST(c.cohort_date AS DATE), CAST(l.log_date AS DATE)) = 6 THEN l.user_id END) AS day6_active,  -- For 7th day (Day 6 gap)
        COUNT(DISTINCT CASE WHEN date_diff('day', CAST(c.cohort_date AS DATE), CAST(l.log_date AS DATE)) = 13 THEN l.user_id END) AS day13_active,
        COUNT(DISTINCT CASE WHEN date_diff('day', CAST(c.cohort_date AS DATE), CAST(l.log_date AS DATE)) = 29 THEN l.user_id END) AS day29_active 
    FROM ExpandedCohorts c
    LEFT JOIN DailyLogins l ON c.user_id = l.user_id AND l.log_date > c.cohort_date
    WHERE c.cohort_date >= '2026-01-22' -- Analyze from Feb 2026
    GROUP BY 1, 2
)
SELECT 
    cohort_date AS "日期",
    user_type AS "用户类型",
    cohort_size AS "基数(人数)",
    TRY(CAST(day1_active AS DOUBLE) / cohort_size) AS "次留",
    TRY(CAST(day2_active AS DOUBLE) / cohort_size) AS "3留",
    TRY(CAST(day6_active AS DOUBLE) / cohort_size) AS "7留",
    TRY(CAST(day13_active AS DOUBLE) / cohort_size) AS "14留",
    TRY(CAST(day29_active AS DOUBLE) / cohort_size) AS "30留"
FROM RetentionCalculated
ORDER BY 1 DESC, 2 ASC;
