/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 6月24日注册用户按首日充值档位划分的后续充值统计
Description : 统计2026年6月24日注册的新增用户，根据其在6月24日首日的充值金额进行付费分档，
              并汇总其在后续天数 (6月25日、6月26日) 每天的再付费人数、再充值金额 (USD) 与转化率。
Environment : Trino (TA)
================================================================================
*/

WITH CohortUsers AS (
    -- 1. 提取固化注册日期 (fixed_regdate) 为 2026-06-24 的用户
    SELECT DISTINCT "#varchar_id" AS lid 
    FROM user_result_cluster_23 
    WHERE cluster_name = 'fixed_regdate' 
      AND tag_value = '2026-06-24'
),

FirstDayRevenue AS (
    -- 2. 计算这批用户在首日 (6/24) 的累计充值金额 (USD)
    SELECT 
        c.lid,
        COALESCE(SUM(s1.amt / COALESCE(s3.exchange, 1.0)), 0.0) AS first_day_usd
    FROM CohortUsers c
    LEFT JOIN (
        SELECT 
            "#account_id" AS lid,
            payload.curamt AS amt,
            payload.cur AS cur,
            "$part_date" AS part_date
        FROM ta.v_event_23 
        WHERE "$part_date" = '2026-06-24' 
          AND "$part_event" = 'PURCHASE'
          AND COALESCE(payload.validationtype, '') <> 'SANDBOX_RECEIPT'
    ) AS s1 ON c.lid = s1.lid
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1.part_date = s3.ex_date 
        AND s1.cur = s3.currency
    GROUP BY c.lid
),

UserRevenueTier AS (
    -- 3. 基于首日充值金额进行付费档位划分
    SELECT 
        lid,
        first_day_usd,
        CASE 
            WHEN first_day_usd = 0 THEN '0.免费用户'
            WHEN first_day_usd <= 10 THEN 'a.(0,10]'
            WHEN first_day_usd <= 50 THEN 'b.(10,50]'
            WHEN first_day_usd <= 100 THEN 'c.(50,100]'
            WHEN first_day_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS first_day_tier
    FROM FirstDayRevenue
),

CohortTierSizes AS (
    -- 4. 统计每个首日付费档位的总人数和首日总充值金额 (USD)
    SELECT 
        first_day_tier,
        COUNT(DISTINCT lid) AS tier_total_users,
        ROUND(SUM(first_day_usd), 2) AS tier_first_day_revenue
    FROM UserRevenueTier
    GROUP BY 1
),

SubsequentRevenue AS (
    -- 5. 提取 6月25日-6月26日（后续天数）的充值明细
    SELECT 
        s1.lid,
        s1.part_date,
        (s1.amt / COALESCE(s3.exchange, 1.0)) AS revenue_usd
    FROM (
        SELECT 
            "#account_id" AS lid,
            payload.curamt AS amt,
            payload.cur AS cur,
            "$part_date" AS part_date
        FROM ta.v_event_23 
        WHERE "$part_date" BETWEEN '2026-06-25' AND '2026-06-26' 
          AND "$part_event" = 'PURCHASE'
          AND COALESCE(payload.validationtype, '') <> 'SANDBOX_RECEIPT'
    ) AS s1
    INNER JOIN CohortUsers c ON s1.lid = c.lid
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1.part_date = s3.ex_date 
        AND s1.cur = s3.currency
)

-- 6. 结合首日付费档位与后续日期聚合
SELECT 
    u.first_day_tier AS "首日付费档位",
    ts.tier_total_users AS "该档位总人数",
    ts.tier_first_day_revenue AS "首日充值金额 (USD)",
    r.part_date AS "后续充值日期",
    COUNT(DISTINCT r.lid) AS "当日再付费人数",
    ROUND(SUM(r.revenue_usd), 2) AS "当日再充值金额 (USD)",
    -- 该档位在后续日期的付费转化率
    FORMAT('%.4f', COUNT(DISTINCT r.lid) * 1.0000 / ts.tier_total_users) AS "当日付费转化率"
FROM UserRevenueTier u
INNER JOIN CohortTierSizes ts ON u.first_day_tier = ts.first_day_tier
INNER JOIN SubsequentRevenue r ON u.lid = r.lid
GROUP BY 1, 2, 3, 4
ORDER BY 1 ASC, 4 ASC;
