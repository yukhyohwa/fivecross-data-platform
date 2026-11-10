/*
================================================================================
Game: Kuroko's Basketball (黑子的篮球)
Region: TC 
Description: 活动期间新用户留存与LTV分析 (2026-04-22 ~ 2026-04-28)
             - 新玩家数量
             - 付费率/付费留存/LTV (LTV1, 3, 7, 14, 30)
             - 活动新用户整体DAU(AU)及日收入
================================================================================
*/

WITH
-- 1. 获取所有用户的注册日期
UserBase AS (
    SELECT 
        "#user_id", 
        MIN(CAST("$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10
    WHERE "$part_event" = 'login'
    GROUP BY 1
    HAVING MIN(CAST("$part_date" AS DATE)) <= DATE '2026-04-28'
),

-------------------------------------------------------
-- 2. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-- 3. 筛选活动期间的新用户 (2026-04-22 ~ 2026-04-28)
CohortUsers AS (
    SELECT 
        "#user_id",
        reg_date
    FROM UserBase
    WHERE reg_date >= DATE '2026-04-22' 
      AND reg_date <= DATE '2026-04-28'
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

-- 4. 新用户活跃记录
UserActive AS (
    SELECT 
        s1."#user_id", 
        s2.reg_date,  
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', s2.reg_date, d)) AS return_days_array
    FROM (
        SELECT "#user_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_10
        WHERE "$part_event" = 'login'
          AND "$part_date" >= '2026-04-22'
        GROUP BY 1
    ) s1
    INNER JOIN CohortUsers s2 ON s1."#user_id" = s2."#user_id"
),

-- 5. 新用户收入记录
UserRevenue AS (
    SELECT
        s1."#user_id",
        CAST(s1."$part_date" AS DATE) AS pay_date,
        SUM(CAST(s1.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS revenue_usd
    FROM ta.v_event_10 s1
    INNER JOIN CohortUsers s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE (
        (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
        OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
    AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    AND s1."$part_date" >= '2026-04-22'
    GROUP BY 1, 2
),

-- 6. 新用户 LTV 映射
UserLtvMap AS (
    SELECT
        m."#user_id",
        MAP_AGG(
            DATE_DIFF('day', s2.reg_date, m.pay_date),
            m.revenue_usd
        ) AS revenue_map
    FROM UserRevenue m
    INNER JOIN CohortUsers s2 ON m."#user_id" = s2."#user_id"
    GROUP BY 1
),

-- 7. 活动期间新用户大盘日指标 (AU 和 日收入)
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
    INNER JOIN CohortUsers u ON v."#user_id" = u."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON v."$part_date" = ex.ex_date AND v.pay_currency = ex.currency
    WHERE v."$part_date" >= '2026-04-22'
      AND v."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
    GROUP BY 1
),

-- 8. 每日新增群体的留存和LTV统计
CohortDailyMetrics AS (
    SELECT 
        s1.reg_date,
        COUNT(DISTINCT s1."#user_id") AS new_users,
        
        -- 付费相关 (首日有付费的用户视为付费用户, 或指整个生命周期有付费)
        -- 此处以首日付费为例 (LTV0>0)，如果您需要看全体的留存，则直接算；若是付费用户的留存，可在此增加筛选
        COUNT(DISTINCT CASE WHEN MAP_KEYS(l.revenue_map) IS NOT NULL AND CONTAINS(MAP_KEYS(l.revenue_map), 0) THEN s1."#user_id" END) AS new_paying_users,

        -- 留存率 (RR_1 是次留)
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 7)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 8)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_8,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 9)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_9,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 10)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_10,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 11)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_11,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 12)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_12,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_13,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_30,

        -- LTV
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 3)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_3,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_30

    FROM CohortUsers s1
    LEFT JOIN UserActive r ON s1."#user_id" = r."#user_id"
    LEFT JOIN UserLtvMap l ON s1."#user_id" = l."#user_id"
    GROUP BY 1
)

-------------------------------------------------------
-- 9. 结果输出
-------------------------------------------------------
SELECT 
    -- 结合每日的群组数据和活动新用户的日活跃度
    CAST(COALESCE(m.reg_date, k."date") AS VARCHAR) AS "日期",
    m.new_users AS "新玩家数量",
    m.new_paying_users AS "新增付费人数",
    k.cohort_dau AS "AU(仅活动新用户)",
    ROUND(k.cohort_daily_revenue, 2) AS "日收入(仅活动新用户)",
    
    -- 留存率 (将小数转为百分比方便查阅)
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
    CAST(ROUND(m.rr_30 * 100, 2) AS VARCHAR) || '%' AS "30留",
    
    -- LTV
    ROUND(m.ltv_1, 2) AS "LTV_1",
    ROUND(m.ltv_3, 2) AS "LTV_3",
    ROUND(m.ltv_7, 2) AS "LTV_7",
    ROUND(m.ltv_14, 2) AS "LTV_14",
    ROUND(m.ltv_30, 2) AS "LTV_30"
    
FROM CohortDailyMetrics m
FULL OUTER JOIN DailyCohortKPI k ON m.reg_date = k."date"
ORDER BY 1;
