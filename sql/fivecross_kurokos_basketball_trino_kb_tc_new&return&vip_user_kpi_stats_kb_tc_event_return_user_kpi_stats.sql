/*
================================================================================
Game: Kuroko's Basketball (黑子的篮球)
Region: TC 
Description: 活动期间回归用户留存与收入分析 (2026-04-22 ~ 2026-04-28)
             - 回归条件：注册在活动开始前 ( < 2026-04-22 )，且活动前30日 (03-23 ~ 04-21) 未登录
             - 回归玩家数量
             - 活动回归用户整体DAU(AU)及日收入
             - 留存率分析 (无LTV)
================================================================================
*/

WITH
-- 1. 获取所有用户的注册日期 (首登日)
UserBase AS (
    SELECT 
        "#user_id", 
        MIN(CAST("$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10
    WHERE "$part_event" = 'login'
    GROUP BY 1
),

-------------------------------------------------------
-- 2. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-- 3. 找出活动前30天内(2026-03-23 ~ 2026-04-21)有登录记录的用户
RecentLogins AS (
    SELECT DISTINCT "#user_id"
    FROM ta.v_event_10
    WHERE "$part_event" = 'login'
      AND "$part_date" >= '2026-03-23'
      AND "$part_date" <= '2026-04-21'
),

-- 4. 筛选活动期间的回归用户
-- 条件：
--   a) 注册时间早于活动开始日期 (< '2026-04-22')
--   b) 活动开始前30天未登录 (不在 RecentLogins 中)
--   c) 活动期间有登录 (在 2026-04-22 ~ 2026-04-28 有登录)
CohortReturnUsers AS (
    SELECT 
        l."#user_id",
        MIN(CAST(l."$part_date" AS DATE)) AS return_date
    FROM ta.v_event_10 l
    INNER JOIN UserBase u ON l."#user_id" = u."#user_id"
    LEFT JOIN RecentLogins r ON l."#user_id" = r."#user_id"
    WHERE l."$part_event" = 'login'
      AND l."$part_date" >= '2026-04-22' 
      AND l."$part_date" <= '2026-04-28'
      AND u.reg_date < DATE '2026-04-22'
      AND r."#user_id" IS NULL
      AND l."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
),

-- 5. 回归用户后续活跃记录 (用于计算留存)
UserActive AS (
    SELECT 
        s1."#user_id", 
        s2.return_date,  
        TRANSFORM(ARRAY_SORT(s1.active_date_array), d -> DATE_DIFF('day', s2.return_date, d)) AS active_days_array
    FROM (
        SELECT "#user_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS active_date_array
        FROM ta.v_event_10
        WHERE "$part_event" = 'login'
          AND "$part_date" >= '2026-04-22'
        GROUP BY 1
    ) s1
    INNER JOIN CohortReturnUsers s2 ON s1."#user_id" = s2."#user_id"
),

-- 6. 活动期间回归用户大盘日指标 (AU 和 日收入)
DailyCohortKPI AS (
    SELECT
        CAST(v."$part_date" AS DATE) AS "date",
        COUNT(DISTINCT CASE WHEN v."$part_event" = 'login' THEN v."#user_id" END) AS cohort_dau,
        SUM(CASE 
            WHEN (
                (v."$part_event" = 'charge' AND v.pay_currency <> 'kuroko_pay' AND (v.sandbox = false OR v.sandbox IS NULL))
                OR (v."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            ) 
            AND (v.order_id NOT IN ('11') OR v.order_id IS NULL)
            THEN CAST(v.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0) 
            ELSE 0.0 
        END) AS cohort_daily_revenue
    FROM ta.v_event_10 v
    INNER JOIN CohortReturnUsers u ON v."#user_id" = u."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON v."$part_date" = ex.ex_date AND v.pay_currency = ex.currency
    WHERE v."$part_date" >= '2026-04-22'
      AND v."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
    GROUP BY 1
),

-- 7. 每日回归群体的留存统计
CohortDailyMetrics AS (
    SELECT 
        s1.return_date,
        COUNT(DISTINCT s1."#user_id") AS return_users,
        
        -- 留存率 (RR_1 是次回留存，即回归次日)
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 7)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 8)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_8,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 9)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_9,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 10)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_10,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 11)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_11,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 12)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_12,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_13,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 14)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_14,
        CAST(COUNT_IF(CONTAINS(r.active_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_30
        
    FROM CohortReturnUsers s1
    LEFT JOIN UserActive r ON s1."#user_id" = r."#user_id"
    GROUP BY 1
)

-------------------------------------------------------
-- 8. 结果输出
-------------------------------------------------------
SELECT 
    CAST(COALESCE(m.return_date, k."date") AS VARCHAR) AS "回归日期",
    m.return_users AS "回归玩家数量",
    k.cohort_dau AS "AU(仅回归用户)",
    ROUND(k.cohort_daily_revenue, 2) AS "日收入(仅回归用户)",
    
    -- 留存率
    CAST(ROUND(m.rr_1 * 100, 2) AS VARCHAR) || '%' AS "次留",
    CAST(ROUND(m.rr_2 * 100, 2) AS VARCHAR) || '%' AS "3留",
    CAST(ROUND(m.rr_3 * 100, 2) AS VARCHAR) || '%' AS "4留",
    CAST(ROUND(m.rr_4 * 100, 2) AS VARCHAR) || '%' AS "5留",
    CAST(ROUND(m.rr_5 * 100, 2) AS VARCHAR) || '%' AS "6留",
    CAST(ROUND(m.rr_6 * 100, 2) AS VARCHAR) || '%' AS "7留",
    CAST(ROUND(m.rr_7 * 100, 2) AS VARCHAR) || '%' AS "8留",
    CAST(ROUND(m.rr_8 * 100, 2) AS VARCHAR) || '%' AS "9留",
    CAST(ROUND(m.rr_9 * 100, 2) AS VARCHAR) || '%' AS "10留",
    CAST(ROUND(m.rr_10 * 100, 2) AS VARCHAR) || '%' AS "11留",
    CAST(ROUND(m.rr_11 * 100, 2) AS VARCHAR) || '%' AS "12留",
    CAST(ROUND(m.rr_12 * 100, 2) AS VARCHAR) || '%' AS "13留",
    CAST(ROUND(m.rr_13 * 100, 2) AS VARCHAR) || '%' AS "14留",
    CAST(ROUND(m.rr_14 * 100, 2) AS VARCHAR) || '%' AS "15留",
    CAST(ROUND(m.rr_30 * 100, 2) AS VARCHAR) || '%' AS "30留"
    
FROM CohortDailyMetrics m
FULL OUTER JOIN DailyCohortKPI k ON m.return_date = k."date"
ORDER BY 1;
