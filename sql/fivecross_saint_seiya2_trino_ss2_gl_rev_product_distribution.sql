/*
================================================================================
Game: Saint Seiya 2 (SS2) - GL
Description: Product Purchase Distribution Analysis.
             Calculates revenue and PU for each product ID.
             Filters out internal/water users and excludes 'SANDBOX_RECEIPT' purchases.
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
    -- 1. 提取充值原始事件 (锁定 ID 19，增加沙盒过滤)
    SELECT 
        v."$part_date",
        v."#account_id",
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid') AS product_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) AS amt,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') AS cur,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.storeorderid') AS store_order_id,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.purchaseid') AS purchase_id
    FROM TargetGameEvents v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND ub."#account_id" IS NULL
),

-- 3. 关联汇率与维表，汇总商品维度收入
SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        ELSE '已合并'
    END AS time_dimension,
    s5."payload.productid@product_category" AS product_category,
    s1.product_id,
    s5."payload.productid@product_name" AS product_name,
    COUNT(DISTINCT s1."#account_id") AS pu,
    -- 净美元收入 = 原始金额 / 美元汇率
    SUM(s1.amt / s3.exchange) AS revenue_usd,
    -- 净人民币收入 = 原始金额 / 美元汇率 * 人民币汇率
    SUM(s1.amt / s3.exchange * s4.exchange) AS revenue_cny,
    CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) AS date_range
FROM PurchaseEvents s1
LEFT JOIN ta_dim.ta_exchange s3 
    ON s1."$part_date" = s3.ex_date 
    AND s1.cur = s3.currency
LEFT JOIN ta_dim.ta_exchange s4 
    ON s1."$part_date" = s4.ex_date 
    AND s4.currency = 'CNY'
LEFT JOIN ta_dim.dim_16_0_23989 s5 
    ON s1.product_id = s5."payload.productid@product_id"
GROUP BY 1, 2, 3, 4
ORDER BY 1, 6 DESC;
