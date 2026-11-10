/*
================================================================================
Game: New Three Kingdoms (NTK) - GL
Description: Icebreaker (First Purchase) Stats analysis script for New Three Kingdoms.
             Tracks players' behavior after their first purchase ever.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH
-- 1. [新增] 黑名单用户 (19)
UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),

-- 1.5 [扫描配置]
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
),

-- 2. [用户属性] (19)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store 
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store')
    GROUP BY "#varchar_id"
),

-- 3. [角色活跃]
UserActivity AS (
    SELECT 
        v."#account_id", 
        CAST(v."$part_date" AS DATE) AS activity_date
    FROM ta.v_event_19 v
    WHERE v."$part_date" >= '2026-01-01'
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2
),

-- 4. [首付判定]
FirstPurchaseEver AS (
    SELECT 
        v."#account_id", 
        MIN(CAST(v."$part_date" AS DATE)) AS first_pay_date
    FROM ta.v_event_19 v
    WHERE v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1
),

-- 6. [破冰详情]
IceBreakerDetail AS (
    SELECT 
        v."#account_id",
        fp.first_pay_date,
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange) AS first_day_revenue_cny
    FROM ta.v_event_19 v
    INNER JOIN FirstPurchaseEver fp ON v."#account_id" = fp."#account_id" AND CAST(v."$part_date" AS DATE) = fp.first_pay_date
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE CAST(v."$part_date" AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
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
    GROUP BY 1, 2
),

-- 7. [破冰留存]
IceBreakerRetention AS (
    SELECT 
        ib."#account_id",
        ib.first_pay_date,
        COUNT_IF(ua.activity_date = DATE_ADD('day', 1, ib.first_pay_date)) AS is_ret_1,
        COUNT_IF(ua.activity_date = DATE_ADD('day', 7, ib.first_pay_date)) AS is_ret_7
    FROM IceBreakerDetail ib
    LEFT JOIN UserActivity ua ON ib."#account_id" = ua."#account_id"
    GROUP BY 1, 2
),

-- 8. [档位划分]
IceBreakerTier AS (
    SELECT 
        *,
        CASE 
            WHEN first_day_revenue_cny <= 1 THEN 'a.(0,1]'
            WHEN first_day_revenue_cny <= 10 THEN 'b.(1,10]'
            WHEN first_day_revenue_cny <= 50 THEN 'c.(10,50]'
            WHEN first_day_revenue_cny <= 100 THEN 'd.(50,100]'
            WHEN first_day_revenue_cny <= 500 THEN 'e.(100,500]'
            WHEN first_day_revenue_cny <= 1000 THEN 'f.(500,1000]'
            ELSE 'g.(1000,∞]'
        END AS recharge_tier
    FROM IceBreakerDetail
)

-- 9. [归因汇总]
SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', ib.first_pay_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', ib.first_pay_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', ib.first_pay_date) AS VARCHAR)
        ELSE '已合并'
    END AS "时间维度",
    CASE WHEN ${Selector:ostype} THEN up.fixed_os ELSE '已合并' END AS "系统类型",
    CASE WHEN ${Selector:country} THEN up.fixed_country ELSE '已合并' END AS "国家", 
    CASE WHEN ${Selector:affcode} THEN up.fixed_affcode ELSE '已合并' END AS "渠道码",
    CASE WHEN ${Selector:store} THEN up.fixed_store ELSE '已合并' END AS "商店",
    
    COUNT(DISTINCT ib."#account_id") AS "破冰人数",
    SUM(ib.first_day_revenue_cny) AS "破冰总金额_CNY",
    
    -- 档位分布
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'a.(0,1]' THEN ib."#account_id" END) AS "(0,1]人数",
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'b.(1,10]' THEN ib."#account_id" END) AS "(1,10]人数",
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'c.(10,50]' THEN ib."#account_id" END) AS "(10,50]人数",
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'd.(50,100]' THEN ib."#account_id" END) AS "(50,100]人数",
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'e.(100,500]' THEN ib."#account_id" END) AS "(100,500]人数",
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'f.(500,1000]' THEN ib."#account_id" END) AS "(500,1000]人数",
    COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'g.(1000,∞]' THEN ib."#account_id" END) AS "(1000,∞]人数",

    -- 留存
    CAST(SUM(ret.is_ret_1) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#account_id"), 0) AS "破冰次留",
    CAST(SUM(ret.is_ret_7) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#account_id"), 0) AS "破冰7留"
    
FROM IceBreakerTier ib
LEFT JOIN UserProfileDetail up ON ib."#account_id" = up."#account_id"
LEFT JOIN IceBreakerRetention ret ON ib."#account_id" = ret."#account_id" AND ib.first_pay_date = ret.first_pay_date
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC;
