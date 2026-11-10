/*
================================================================================
Game    : Jump Assemble (众星之聚)
Report  : 4/15 测试新用户付费构成与充值档位分布 (CBT)
Description: 
    目标用户：2026-04-15 及以后注册的新用户，排除测试与水军号。
    统计指标：各充值档位下的付费用户数、人数占比、累计充值总金额(USD)、充值占比以及人均充值(ARPPU)。
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

NewUsers AS (
    SELECT 
        t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND ub.lcx_id IS NULL
    GROUP BY 1
    HAVING MAX(CASE WHEN t1.cluster_name = 'fixed_regdate' THEN t1.tag_value END) >= '2026-04-15'
),

UserCumulativeRevenue AS (
    SELECT 
        nu.lcx_id,
        COALESCE(SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1)), 0) AS total_revenue_usd
    FROM NewUsers nu
    LEFT JOIN ta.v_event_16 v ON nu.lcx_id = v."#account_id" 
        AND v."$part_event" = 'PURCHASE' 
        AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date 
        AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    GROUP BY 1
),

UserTierAssignment AS (
    SELECT 
        lcx_id,
        total_revenue_usd,
        CASE 
            WHEN total_revenue_usd = 0 THEN '0.免费用户'
            WHEN total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM UserCumulativeRevenue
),

CohortTotal AS (
    SELECT 
        COUNT(DISTINCT lcx_id) AS total_cohort_users,
        SUM(total_revenue_usd) AS total_cohort_revenue
    FROM UserCumulativeRevenue
)

SELECT 
    uta.recharge_tier AS "充值档位",
    COUNT(DISTINCT uta.lcx_id) AS "用户数",
    ROUND(COUNT(DISTINCT uta.lcx_id) * 100.0 / (SELECT total_cohort_users FROM CohortTotal), 2) AS "人数占比(%)",
    ROUND(SUM(uta.total_revenue_usd), 2) AS "累计充值(USD)",
    ROUND(SUM(uta.total_revenue_usd) * 100.0 / NULLIF((SELECT total_cohort_revenue FROM CohortTotal), 0.0), 2) AS "付费总额占比(%)",
    ROUND(AVG(NULLIF(uta.total_revenue_usd, 0.0)), 2) AS "ARPPU"
FROM UserTierAssignment uta
GROUP BY 1
ORDER BY 1 ASC;
