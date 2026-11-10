/*
================================================================================
Game: New Three Kingdoms (NTK) - GL
Description: Weekly & Monthly Login Days Distribution for New Three Kingdoms.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

-- 1. Weekly Login Days Distribution
WITH UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),
WeeklyLoginDays AS (
    SELECT 
        DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS login_week,
        v."#account_id" AS account_id,
        COUNT(DISTINCT v."$part_date") AS login_days
    FROM ta.v_event_19 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND v.${PartDate:date1}
      AND ub."#account_id" IS NULL
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2
)
SELECT 
    CAST(login_week AS VARCHAR) AS week_start,
    login_days,
    COUNT(DISTINCT account_id) AS account_count
FROM WeeklyLoginDays
GROUP BY 1, 2
ORDER BY 1 DESC, 2 DESC;

-- 2. Monthly Login Days Distribution
WITH UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),
MonthlyLoginDays AS (
    SELECT 
        DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS login_month,
        v."#account_id" AS account_id,
        COUNT(DISTINCT v."$part_date") AS login_days
    FROM ta.v_event_19 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND v.${PartDate:date1}
      AND ub."#account_id" IS NULL
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2
)
SELECT 
    CAST(login_month AS VARCHAR) AS month_start,
    login_days,
    COUNT(DISTINCT account_id) AS account_count
FROM MonthlyLoginDays
GROUP BY 1, 2
ORDER BY 1 DESC, 2 DESC;
