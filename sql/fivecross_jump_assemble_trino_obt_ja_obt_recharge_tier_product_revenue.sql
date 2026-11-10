/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 道具购买与付费档位聚合 (美元)
Description: 统计各活跃用户的累计充值金额(美元)，对其进行付费分档，并汇总到用户-道具粒度。
             输出各道具在不同付费档位下的用户数、总美元收入及占比。
Environment: Trino (TA)
================================================================================
*/

WITH ActiveUsers AS (
    -- 1. 取统计周期内活跃用户
    SELECT DISTINCT "#account_id" AS lid 
    FROM ta.v_event_23 
    WHERE "$part_date" BETWEEN '2026-06-24' AND '2026-06-24' 
      AND "$part_event" = 'LOGIN_SUCCESS' 
),
PurchaseDetail AS (
    -- 2. 充值明细：补充 purchaseid，并关联道具名，统一转换为美元
    SELECT 
        s1.lid,
        s1.productid,
        COALESCE(s4."payload.productid@product_name", '未匹配道具') AS product_category,
        (s1.amt / s3.exchange) AS revenue_usd
    FROM (
        SELECT 
            "#account_id" AS lid,
            payload.curamt AS amt,
            payload.cur AS cur,
            payload.productid AS productid,
            "$part_date" 
        FROM ta.v_event_23 
        WHERE "$part_date" BETWEEN '2026-06-24' AND '2026-06-24' 
          AND "$part_event" = 'PURCHASE'
    ) AS s1
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1."$part_date" = s3.ex_date 
        AND s1.cur = s3.currency
    LEFT JOIN ta_dim.dim_23_0_51243 s4 
        ON s1.productid = s4."payload.productid@product_id"
),
UserRevenue AS (
    -- 3. 计算每个活跃用户的累计充值金额，用于付费分档
    SELECT 
        t.lid,
        COALESCE(SUM(p.revenue_usd), 0) AS revenue_usd
    FROM ActiveUsers t
    LEFT JOIN PurchaseDetail p ON t.lid = p.lid
    GROUP BY t.lid
),
UserRevenueTier AS (
    -- 4. 对每个用户的累计金额进行分档（以美元为单位）
    SELECT 
        lid,
        revenue_usd,
        CASE 
            WHEN revenue_usd = 0 THEN '0.免费用户'
            WHEN revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS pay_tier
    FROM UserRevenue
),
UserProductRevenue AS (
    -- 5. 汇总到用户-道具粒度，未付费用户保留为“未付费”
    SELECT 
        t.lid,
        COALESCE(p.product_category, '未付费') AS product_category,
        COALESCE(SUM(p.revenue_usd), 0) AS product_revenue_usd
    FROM ActiveUsers t
    LEFT JOIN PurchaseDetail p ON t.lid = p.lid
    GROUP BY 1, 2
)
-- 6. 道具名与付费档位聚合
SELECT 
    p.product_category AS "道具名",
    u.pay_tier AS "付费档位",
    COUNT(DISTINCT p.lid) AS "用户数",
    -- 计算该道具在该档位内的总充值金额 (美元)
    FORMAT('%.2f', SUM(p.product_revenue_usd)) AS "该道具该档位总美元收入",
    FORMAT('%.4f', COUNT(DISTINCT p.lid) * 1.0000 / (SELECT COUNT(*) FROM ActiveUsers)) AS "人数占比"
FROM UserProductRevenue p
INNER JOIN UserRevenueTier u ON p.lid = u.lid
GROUP BY 1, 2
ORDER BY 1 ASC, 2 ASC;
