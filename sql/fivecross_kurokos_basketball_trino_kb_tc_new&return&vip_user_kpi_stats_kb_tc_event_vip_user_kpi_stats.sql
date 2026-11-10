/*
================================================================================
Game: Kuroko's Basketball (黑子的篮球)
Region: TC 
Description: 活动期间大R用户留存与收入分析 (2026-04-22 ~ 2026-04-28)
             - 大R条件：历史累计充值 (含活动期间) >= 5,000 USD 的玩家
             - 大R玩家活动期间参与数量
             - 大R用户整体DAU(AU)及日收入
             - 留存率分析 (以活动期间首次登录为基准，无LTV)
================================================================================
*/

WITH
-- 1. 筛选出全量历史充值 >= 5000 美金的大R用户
--    计算规则与日常收入统计保持一致
VipUsers AS (
    SELECT 
        v."#user_id",
        SUM(CAST(v.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS total_usd_recharge
    FROM ta.v_event_10 v
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON v."$part_date" = ex.ex_date AND v.pay_currency = ex.currency
    WHERE (
        (v."$part_event" = 'charge' AND v.pay_currency <> 'kuroko_pay' AND (v.sandbox = false OR v.sandbox IS NULL))
        OR (v."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
    AND (v.order_id NOT IN ('11') OR v.order_id IS NULL)
    GROUP BY 1
    HAVING SUM(CAST(v.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) >= 5000
),

-------------------------------------------------------
-- 2. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-- 3. 找出这些大R在活动期间(2026-04-22 ~ 2026-04-28)的首登日
CohortVipUsers AS (
    SELECT 
        l."#user_id",
        MIN(CAST(l."$part_date" AS DATE)) AS active_date
    FROM ta.v_event_10 l
    INNER JOIN VipUsers u ON l."#user_id" = u."#user_id"
    WHERE l."$part_event" = 'login'
      AND l."$part_date" >= '2026-04-22' 
      AND l."$part_date" <= '2026-04-28'
      AND l."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
),

-- 4. 大R用户后续活跃记录 (用于计算留存)
UserActive AS (
    SELECT 
        s1."#user_id", 
        s2.active_date,  
        TRANSFORM(ARRAY_SORT(s1.active_date_array), d -> DATE_DIFF('day', s2.active_date, d)) AS active_days_array
    FROM (
        SELECT "#user_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS active_date_array
        FROM ta.v_event_10
        WHERE "$part_event" = 'login'
          AND "$part_date" >= '2026-04-22'
        GROUP BY 1
    ) s1
    INNER JOIN CohortVipUsers s2 ON s1."#user_id" = s2."#user_id"
),

-- 5. 活动期间大R用户大盘日指标 (AU 和 日收入)
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
    INNER JOIN CohortVipUsers u ON v."#user_id" = u."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON v."$part_date" = ex.ex_date AND v.pay_currency = ex.currency
    WHERE v."$part_date" >= '2026-04-22'
      AND v."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
    GROUP BY 1
),

-- 6. 每日活跃大R群体的留存统计
CohortDailyMetrics AS (
    SELECT 
        s1.active_date,
        COUNT(DISTINCT s1."#user_id") AS vip_users,
        
        -- 留存率 (RR_1 是次回留存)
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
        
    FROM CohortVipUsers s1
    LEFT JOIN UserActive r ON s1."#user_id" = r."#user_id"
    GROUP BY 1
)

-------------------------------------------------------
-- 7. 结果输出
-------------------------------------------------------
SELECT 
    CAST(COALESCE(m.active_date, k."date") AS VARCHAR) AS "活动登录日期",
    m.vip_users AS "登录大R数量",
    k.cohort_dau AS "AU(仅大R)",
    ROUND(k.cohort_daily_revenue, 2) AS "日收入(仅大R)",
    
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
FULL OUTER JOIN DailyCohortKPI k ON m.active_date = k."date"
ORDER BY 1;
