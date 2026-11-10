-- 灌篮韩服玩家 100872025 点券获取与消耗日志
-- 时间范围：2026-02-03 00:00:00 ~ 2026-02-05 17:00:00
-- 优化策略：
-- 1. 2月3日-4日使用 daily_game_log (离线表)，a_rst 格式更规范，解析更准
-- 2. 2月5日(当天)使用 game_log (实时表)，确保能查到最新数据

SELECT
    user_id,
    TO_CHAR(FROM_UNIXTIME(CAST(log_t AS BIGINT)), 'yyyy-mm-dd hh:mi:ss') AS log_time,
    CASE 
        WHEN obj = 'dmp:stamps' THEN '付费点券'
        WHEN obj = 'dmp:freestamps' THEN '免费点券'
        ELSE obj 
    END AS voucher_type,
    CAST(diff AS INT) AS change_amount,
    a_typ AS action_type,
    rst AS raw_json
FROM g33002013.daily_game_log
-- 离线表的 a_rst 通常是 Array 类型，直接 EXPLODE 即可，无需正则清洗
LATERAL VIEW EXPLODE(a_rst) b AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
WHERE day BETWEEN 20260203 AND 20260204
  AND user_id = 100872025
  AND obj IN ('dmp:freestamps', 'dmp:stamps')

UNION ALL

SELECT
    user_id,
    TO_CHAR(FROM_UNIXTIME(CAST(log_t AS BIGINT)), 'yyyy-mm-dd hh:mi:ss') AS log_time,
    CASE 
        WHEN obj = 'dmp:stamps' THEN '付费点券'
        WHEN obj = 'dmp:freestamps' THEN '免费点券'
        ELSE obj 
    END AS voucher_type,
    CAST(diff AS INT) AS change_amount,
    a_typ AS action_type,
    rst AS raw_json
FROM g33002013.game_log
-- 实时表的 a_rst 是字符串且格式较乱，维持正则清洗逻辑
LATERAL VIEW EXPLODE(SPLIT(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(a_rst, '^\\[|\\]$', '')), '\\}\\s*,\\s*\\{', '};{'), ';')) b AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
WHERE dt = 20260205
  AND user_id = 100872025
  AND obj IN ('dmp:freestamps', 'dmp:stamps')
  AND FROM_UNIXTIME(CAST(log_t AS BIGINT)) <= DATETIME '2026-02-05 17:00:00'

ORDER BY log_time ASC;




------------------------------------------------------------
------------------------------------------------------------
------------------------------------------------------------
------------------------------------------------------------
------------------------------------------------------------

-- Environment: MaxCompute (ODPS)
-- Game: Slam Dunk TC (灌篮高手 繁体)
-- App ID: 23002013
-- Description: New users and 90-day returning users metrics (Size, Day 0 Revenue, LTV 1,3,7,14)
-- Date Range: 2026-01-01 to present

SET odps.sql.hive.compatible = TRUE;

WITH 
    -- Step 1: Extract daily activity and calculate gaps for return logic
    raw_activity AS (
        SELECT 
            device_id, 
            day, 
            purchase,
            reg_day,
            LAG(day, 1) OVER (PARTITION BY device_id ORDER BY day) as last_login_day
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 23002013
          AND day >= 20250901 -- Look back ~4 months to identify 90-day churn
    ),
    
    -- Step 2: Identify New and Returning (90d+) Users
    user_cohorts AS (
        SELECT
            device_id,
            day as cohort_date,
            CASE 
                WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN 'New User'
                ELSE 'Return User (90d+)'
            END as user_category
        FROM raw_activity
        WHERE day >= 20260101
          AND (
            -- Condition 1: New Registration
            CAST(reg_day AS BIGINT) = CAST(day AS BIGINT)
            OR 
            -- Condition 2: Returning after 90 days gap
            (
                CAST(reg_day AS BIGINT) < CAST(day AS BIGINT) -- Is an old user
                AND (
                    last_login_day IS NULL -- No login since at least 2025-09-01 (captures 2024 churns)
                    OR 
                    DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 'dd') > 90
                )
            )
          )
    ),

    -- Step 3: Expand to include a 'Total' category for convenience
    expanded_cohorts AS (
        SELECT device_id, cohort_date, user_category FROM user_cohorts
        UNION ALL
        SELECT device_id, cohort_date, 'Total (New+Return)' as user_category FROM user_cohorts
    )

-- Step 4: Final Aggregation (Size, Revenue, LTV)
SELECT
    t.cohort_date AS "日期",
    t.user_category AS "用户类别",
    COUNT(DISTINCT t.device_id) AS "人数",
    
    -- Day 0 Revenue (First Day Income)
    ROUND(SUM(CASE WHEN p.day = t.cohort_date THEN COALESCE(p.purchase, 0) ELSE 0 END), 2) AS "首日总收入",
    ROUND(SUM(CASE WHEN p.day = t.cohort_date THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.device_id), 2) AS "首日ARPU",

    -- LTV Calculation (Cumulative Revenue / Cohort Size)
    ROUND(SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 0 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.device_id), 2) AS "LTV1",
    ROUND(SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 2 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.device_id), 2) AS "LTV3",
    ROUND(SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 6 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.device_id), 2) AS "LTV7",
    ROUND(SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 13 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.device_id), 2) AS "LTV14"

FROM expanded_cohorts t
LEFT JOIN dm_platform.daily_lcx_user_info p 
    ON t.device_id = p.device_id 
    AND p.app_id = 23002013
    AND p.day >= t.cohort_date
GROUP BY 
    t.cohort_date, 
    t.user_category
ORDER BY 
    t.cohort_date DESC, 
    t.user_category;
