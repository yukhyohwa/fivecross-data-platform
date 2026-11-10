/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 6月24日注册用户后续3日充值(每日+道具细分版)
Description : 统计2026年6月24日注册的新增用户，在6月24日至6月26日期间每天购买各个道具品类 (product_category) 的人数与充值金额 (USD)。
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

PurchaseDetail AS (
    -- 2. 提取 6月24日-6月26日 期间这批用户的购买明细并折算为 USD
    SELECT 
        s1.lid,
        s1.part_date,
        COALESCE(s4."payload.productid@product_name", '未匹配道具') AS product_category,
        (s1.amt / COALESCE(s3.exchange, 1.0)) AS revenue_usd
    FROM (
        SELECT 
            "#account_id" AS lid,
            payload.curamt AS amt,
            payload.cur AS cur,
            payload.productid AS productid,
            "$part_date" AS part_date
        FROM ta.v_event_23 
        WHERE "$part_date" BETWEEN '2026-06-24' AND '2026-06-26' 
          AND "$part_event" = 'PURCHASE'
          AND COALESCE(payload.validationtype, '') <> 'SANDBOX_RECEIPT' -- 排除沙盒测试充值
    ) AS s1
    INNER JOIN CohortUsers c ON s1.lid = c.lid
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1.part_date = s3.ex_date 
        AND s1.cur = s3.currency
    LEFT JOIN ta_dim.dim_23_0_51243 s4 
        ON s1.productid = s4."payload.productid@product_id"
)

-- 3. 按充值日期 + 道具品类聚合统计
SELECT 
    part_date AS "充值日期",
    product_category AS "道具品类",
    COUNT(DISTINCT lid) AS "购买人数",
    ROUND(SUM(revenue_usd), 2) AS "充值金额 (USD)"
FROM PurchaseDetail
GROUP BY 1, 2
ORDER BY 1 ASC, 4 DESC;
