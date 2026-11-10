/*
================================================================================
Game: New Three Kingdoms (NTK) - GL
Description: Daily User Recharge Tier Distribution.
             Categorizes users by their TOTAL daily net revenue (CNY) into tiers.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),

PurchaseEvents AS (
    SELECT 
        v."$part_date" AS log_date,
        v."#account_id" AS account_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) AS amt,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') AS cur,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.purchaseid') AS purchase_id
    FROM ta.v_event_19 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND ub."#account_id" IS NULL
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
),

DailyUserRevenue AS (
    SELECT 
        s1.log_date,
        s1.account_id,
        SUM(s1.amt / s3.exchange * s4.exchange) AS daily_revenue_cny
    FROM PurchaseEvents s1
    LEFT JOIN ta_dim.ta_exchange s3 ON s1.log_date = s3.ex_date AND s1.cur = s3.currency
    LEFT JOIN ta_dim.ta_exchange s4 ON s1.log_date = s4.ex_date AND s4.currency = 'CNY' 
    GROUP BY 1, 2
),

TierAssignment AS (
    SELECT 
        log_date,
        account_id,
        daily_revenue_cny,
        CASE 
            WHEN daily_revenue_cny <= 1 THEN 'a.(0,1]'
            WHEN daily_revenue_cny <= 10 THEN 'b.(1,10]'
            WHEN daily_revenue_cny <= 50 THEN 'c.(10,50]'
            WHEN daily_revenue_cny <= 100 THEN 'd.(50,100]'
            WHEN daily_revenue_cny <= 500 THEN 'e.(100,500]'
            WHEN daily_revenue_cny <= 1000 THEN 'f.(500,1000]'
            ELSE 'g.(1000,∞]'
        END AS recharge_tier
    FROM DailyUserRevenue
)

SELECT 
    log_date,
    recharge_tier,
    COUNT(DISTINCT account_id) AS pu,
    SUM(daily_revenue_cny) AS revenue_cny
FROM TierAssignment
GROUP BY 1, 2
ORDER BY 1, 2;
