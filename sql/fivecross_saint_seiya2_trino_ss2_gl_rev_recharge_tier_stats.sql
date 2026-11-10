/*
================================================================================
Game: Saint Seiya 2 (SS2) - GL
Description: Daily User Recharge Tier Distribution.
             Categorizes users by their TOTAL daily net revenue (CNY) into tiers.
             Allows analyzing the distribution of small vs large spenders.
             Strictly excludes 'SANDBOX_RECEIPT' purchases.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH IdentifiedEvents AS (
    SELECT 
        v.*,
        CASE 
            WHEN 
               applicationid IN ('23000113','seiya30tw') 
            OR productid IN ('23000113','seiya30tw') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('23000113')
            OR substring(affcode, -8) IN ('23000113') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('23000113','seiya30tw')
            THEN 'Saint Seiya (TC)' 
            WHEN 
               applicationid IN ('60000001') 
            OR productid IN ('60000001') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('60000001')
            OR substring(affcode, -8) IN ('60000001') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('60000001')
            THEN 'Saint Seiya (SEA)' 
            WHEN 
               applicationid IN ('65002004') 
            OR productid IN ('65002004') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002004')
            OR substring(affcode, -8) IN ('65002004') 
            OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('65002004')
            THEN 'Three Kingdoms' 
            WHEN 
               applicationid IN ('65002005') 
            OR productid IN ('65002005') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002005')
            OR substring(affcode, -8) IN ('65002005') 
            OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('65002005')
            THEN 'Captain Tsubasa' 
            ELSE 'UNKNOWN' 
        END AS game_name
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1}
),

TargetGameEvents AS (
    SELECT *
    FROM IdentifiedEvents
    WHERE game_name IN ('Saint Seiya (TC)','Saint Seiya (SEA)' )
),

UserBlacklist AS (
    -- [新增] 黑名单用户，排除水军、测试等
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),
PurchaseEvents AS (
    -- 1. 提取充值原始事件 (增加沙盒过滤)
    SELECT 
        v."$part_date" AS log_date,
        v."#account_id" AS account_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) AS amt,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') AS cur,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.purchaseid') AS purchase_id
    FROM TargetGameEvents v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND ub."#account_id" IS NULL
),

DailyUserRevenue AS (
    -- 3. 计算每位用户每日的净充值总额 (折合 CNY)
    SELECT 
        s1.log_date,
        s1.account_id,
        SUM(s1.amt / s3.exchange * s4.exchange) AS daily_revenue_cny
    FROM PurchaseEvents s1
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1.log_date = s3.ex_date 
        AND s1.cur = s3.currency
    LEFT JOIN ta_dim.ta_exchange s4 
        ON s1.log_date = s4.ex_date 
        AND s4.currency = 'CNY' 
    GROUP BY 1, 2
),

TierAssignment AS (
    -- 4. 根据“当日净充值总额 (CNY)”进行档位划分
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

-- 5. 按时间维度和档位进行汇总
SELECT 
    log_date,
    recharge_tier,
    COUNT(DISTINCT account_id) AS pu,
    SUM(daily_revenue_cny) AS revenue_cny
FROM TierAssignment
GROUP BY 1, 2
ORDER BY 1, 2;
