/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 用户周/月登录天数分布统计 (排除内部黑名单)
             1. 周统计：统计每位活跃用户在自然周内的登录天数分布。
             2. 月统计：统计每位活跃用户在自然月内的登录天数分布。
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. 内部用户名单 (黑名单)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users')
),

-- 2. 基础活跃流水 (已去重并排除黑名单)
BaseActivity AS (
    SELECT 
        CAST(v."$part_date" AS DATE) AS login_date,
        v."#account_id" AS account_id
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND ub."#account_id" IS NULL
    GROUP BY 1, 2
),

-- 3. 周维度聚合
WeeklyLoginDays AS (
    SELECT 
        DATE_TRUNC('week', login_date) AS login_week,
        account_id,
        COUNT(DISTINCT login_date) AS login_days
    FROM BaseActivity
    GROUP BY 1, 2
),

-- 4. 月维度聚合
MonthlyLoginDays AS (
    SELECT 
        DATE_TRUNC('month', login_date) AS login_month,
        account_id,
        COUNT(DISTINCT login_date) AS login_days
    FROM BaseActivity
    GROUP BY 1, 2
)

-- 5. 最终结果按需求合并或分别查询 (此处由于 Skill 通常返回一个结果集，默认展示最近的分布情况或采用 UNION 结构)
-- 建议在同一报表展示时，加一个维度区分
SELECT 
    'Weekly' AS type,
    CAST(login_week AS VARCHAR) AS period_start,
    login_days AS "登录天数",
    COUNT(DISTINCT account_id) AS "用户数"
FROM WeeklyLoginDays
GROUP BY 1, 2, 3

UNION ALL

SELECT 
    'Monthly' AS type,
    CAST(login_month AS VARCHAR) AS period_start,
    login_days AS "登录天数",
    COUNT(DISTINCT account_id) AS "用户数"
FROM MonthlyLoginDays
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 2 DESC, 3 DESC;
