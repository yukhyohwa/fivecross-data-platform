-- =================================================================================================================
-- Game: Kuroko's Basketball (South Korea)
-- Description: Monthly Whale Composition (Retained, New, Returned) and Churn Analysis (using uuid as user identifier)
-- Time Range: 2025-10 to 2026-03
-- =================================================================================================================

WITH 
-- 1. 黑名单
UserBlacklist AS (
    SELECT DISTINCT "#user_id" FROM user_result_cluster_12 WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-- 2. 统计月份范围 (我们关心的展示区间，但数据需要回溯)
MonthSpine AS (
    SELECT format_datetime(d, 'yyyy-MM') as data_month
    FROM UNNEST(sequence(DATE '2025-01-01', DATE '2026-03-01', INTERVAL '1' MONTH)) AS t(d)
),

-- 3. 用户月度基础行为 (基于 uuid)
UserMonthlyRaw AS (
    SELECT 
        s1.uuid AS user_id,
        SUBSTR(s1."$part_date", 1, 7) AS data_month,
        MAX(CASE WHEN s1."$part_event" = 'login' THEN 1 ELSE 0 END) AS is_active,
        SUM(CASE 
            WHEN ((s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL)) 
               OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy')))
              AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN s1.pay_amount / COALESCE(ex.exchange, 1) 
            ELSE 0 
        END) AS monthly_revenue
    FROM ta.v_event_12 s1
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    LEFT JOIN UserBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" <= '2026-03-31'
      AND b."#user_id" IS NULL
      AND s1.uuid IS NOT NULL AND s1.uuid <> ''
    GROUP BY 1, 2
),

-- 4. 特别修正：计算 2025-01 之前的所有历史充值 (补回丢失的 2024 年数据)
UserPreHistory AS (
    SELECT 
        user_id,
        SUM(monthly_revenue) AS historical_rev_pre_2025
    FROM UserMonthlyRaw
    WHERE data_month < '2025-01'
    GROUP BY 1
),

-- 5. 补齐矩阵 (针对 2025 年后的主轴)
UserFullGrid AS (
    SELECT 
        m.data_month,
        u.user_id,
        COALESCE(r.is_active, 0) as is_active,
        COALESCE(r.monthly_revenue, 0) as monthly_revenue
    FROM MonthSpine m
    CROSS JOIN (SELECT DISTINCT user_id FROM UserMonthlyRaw) u
    LEFT JOIN UserMonthlyRaw r ON m.data_month = r.data_month AND u.user_id = r.user_id
),

-- 6. 第一层：计算累计值 (初始消费 + 2025年后的月滚动累加)
UserMonthlyCum AS (
    SELECT 
        g.data_month,
        g.user_id,
        g.is_active,
        g.monthly_revenue,
        COALESCE(h.historical_rev_pre_2025, 0) + SUM(g.monthly_revenue) OVER (PARTITION BY g.user_id ORDER BY g.data_month) AS cum_rev_end
    FROM UserFullGrid g
    LEFT JOIN UserPreHistory h ON g.user_id = h.user_id
),

-- 7. 第二层：计算偏移值
UserMonthlyStatus AS (
    SELECT 
        data_month,
        user_id,
        is_active,
        monthly_revenue,
        cum_rev_end,
        LAG(is_active) OVER (PARTITION BY user_id ORDER BY data_month) AS was_active_prev,
        LAG(cum_rev_end) OVER (PARTITION BY user_id ORDER BY data_month) AS cum_rev_start
    FROM UserMonthlyCum
),

-- 8. 指标聚合
MonthlyMetrics AS (
    SELECT 
        data_month,
        COUNT(DISTINCT CASE WHEN is_active = 1 AND cum_rev_end >= 1000 THEN user_id END) AS "当月活跃大R总数",
        SUM(CASE WHEN is_active = 1 AND cum_rev_end >= 1000 THEN monthly_revenue ELSE 0 END) AS "总大R付费",
        COUNT(DISTINCT CASE WHEN is_active = 1 AND was_active_prev = 1 AND cum_rev_start >= 1000 THEN user_id END) AS "留存大R人数",
        SUM(CASE WHEN is_active = 1 AND was_active_prev = 1 AND cum_rev_start >= 1000 THEN monthly_revenue ELSE 0 END) AS "留存大R付费",
        COUNT(DISTINCT CASE WHEN is_active = 1 AND (cum_rev_start < 1000 OR cum_rev_start IS NULL) AND cum_rev_end >= 1000 THEN user_id END) AS "本月新晋大R人数",
        SUM(CASE WHEN is_active = 1 AND (cum_rev_start < 1000 OR cum_rev_start IS NULL) AND cum_rev_end >= 1000 THEN monthly_revenue ELSE 0 END) AS "本月新晋大R付费",
        COUNT(DISTINCT CASE WHEN is_active = 1 AND COALESCE(was_active_prev, 0) = 0 AND (cum_rev_start >= 1000) THEN user_id END) AS "流失回流大R人数",
        SUM(CASE WHEN is_active = 1 AND COALESCE(was_active_prev, 0) = 0 AND (cum_rev_start >= 1000) THEN monthly_revenue ELSE 0 END) AS "流失回流大R付费",
        COUNT(DISTINCT CASE WHEN is_active = 0 AND was_active_prev = 1 AND cum_rev_start >= 1000 THEN user_id END) AS "当月流失大R人数"
    FROM UserMonthlyStatus
    GROUP BY 1
)

-- 9. 最终报表
SELECT 
    data_month AS "统计月份",
    "总大R付费",
    "当月活跃大R总数",
    "留存大R付费",
    "留存大R人数",
    "本月新晋大R付费",
    "本月新晋大R人数",
    "流失回流大R付费",
    "流失回流大R人数",
    LAG("当月活跃大R总数", 1) OVER (ORDER BY data_month) AS "上月活跃大R基数",
    "当月流失大R人数",
    CASE 
        WHEN LAG("当月活跃大R总数", 1) OVER (ORDER BY data_month) > 0 
        THEN CAST(ROUND("当月流失大R人数" * 100.0 / LAG("当月活跃大R总数", 1) OVER (ORDER BY data_month), 2) AS VARCHAR) || '%' 
        ELSE '0.00%' 
    END AS "大R流失率"
FROM MonthlyMetrics
WHERE data_month BETWEEN '2025-09' AND '2026-03'
ORDER BY data_month;
