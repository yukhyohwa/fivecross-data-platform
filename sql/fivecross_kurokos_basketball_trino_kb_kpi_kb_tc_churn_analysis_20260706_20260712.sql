/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Churn Analysis for 07/06~07/12. 
             Analyzes users active in 07/01~07/05, classifies them into groups
             (07/01 New, Other New, Return, Active), and checks if they churned
             (no login) in 07/06~07/12.
================================================================================
*/

WITH 
Params AS (
    SELECT 
        DATE '2026-07-01' AS active_start,
        DATE '2026-07-05' AS active_end,
        DATE '2026-07-06' AS churn_check_start,
        DATE '2026-07-12' AS churn_check_end
),

DailyLogins AS (
    SELECT DISTINCT
        "#user_id" AS user_id,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_12
    WHERE "$part_event" = 'login'
      AND "$part_date" >= '2023-01-01'
      AND "$part_date" <= '2026-07-12'
      AND "#user_id" IS NOT NULL
),

UserFirstLog AS (
    SELECT 
        user_id,
        MIN(log_date) AS first_log_date
    FROM DailyLogins
    GROUP BY user_id
),

-- 提取在 07/01 ~ 07/05 期间活跃过的用户
BaseActiveUsers AS (
    SELECT 
        user_id,
        MIN(log_date) AS first_active_date_in_period
    FROM DailyLogins
    CROSS JOIN Params p
    WHERE log_date BETWEEN p.active_start AND p.active_end
    GROUP BY user_id
),

-- 找到这些用户在 07/01~07/05 首次登录前的上一次登录时间（用于判断是否为回流）
UserPrevLog AS (
    SELECT 
        b.user_id,
        MAX(l.log_date) AS prev_log_date
    FROM BaseActiveUsers b
    LEFT JOIN DailyLogins l ON b.user_id = l.user_id AND l.log_date < b.first_active_date_in_period
    GROUP BY b.user_id
),

-- 对活跃用户进行群体分类
UserGroups AS (
    SELECT 
        b.user_id,
        f.first_log_date,
        p.prev_log_date,
        b.first_active_date_in_period,
        CASE
            WHEN f.first_log_date = DATE '2026-07-01' THEN '1. 07/01 新增玩家'
            WHEN f.first_log_date BETWEEN DATE '2026-07-02' AND DATE '2026-07-05' THEN '2. 07/02~07/05 新增玩家'
            WHEN p.prev_log_date IS NOT NULL AND DATE_DIFF('day', p.prev_log_date, b.first_active_date_in_period) >= 14 THEN '3. 回归玩家(>=14天未登录)'
            WHEN p.prev_log_date IS NOT NULL AND DATE_DIFF('day', p.prev_log_date, b.first_active_date_in_period) >= 7 THEN '4. 回归玩家(7~13天未登录)'
            ELSE '5. 活跃老玩家'
        END AS user_group
    FROM BaseActiveUsers b
    JOIN UserFirstLog f ON b.user_id = f.user_id
    JOIN UserPrevLog p ON b.user_id = p.user_id
),

-- 检查他们在 07/06 ~ 07/12 期间是否流失（没有任何登录记录则视为流失）
ChurnCheck AS (
    SELECT 
        u.user_id,
        u.user_group,
        CASE 
            WHEN MAX(l.log_date) IS NULL THEN 1 -- 流失
            ELSE 0 -- 留存
        END AS is_churned
    FROM UserGroups u
    CROSS JOIN Params p
    LEFT JOIN DailyLogins l 
        ON u.user_id = l.user_id 
       AND l.log_date BETWEEN p.churn_check_start AND p.churn_check_end
    GROUP BY u.user_id, u.user_group
)

SELECT 
    user_group AS "玩家群体",
    COUNT(*) AS "在 07/01~07/05 活跃总人数",
    SUM(is_churned) AS "在 07/06~07/12 期间流失人数",
    COUNT(*) - SUM(is_churned) AS "在 07/06~07/12 期间留存人数",
    ROUND(CAST(SUM(is_churned) AS DOUBLE) / COUNT(*) * 100, 2) AS "流失率(%)"
FROM ChurnCheck
GROUP BY user_group
ORDER BY user_group;
