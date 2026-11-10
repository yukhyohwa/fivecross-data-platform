/*
================================================================================
Game: Saint Seiya 2 (SS2) - GL (TC & KR & SEA)
Description: Comprehensive KPI & LTV analysis script for Saint Seiya 2.
             Calculates NUU, DAU, Paying Account, Revenue, RR (1-180), and LTV (1-180).
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
      OR ("$part_date" >= '2026-01-01' AND (SELECT MIN(CAST("$part_date" AS DATE)) FROM ta.v_event_19 WHERE ${PartDate:date1}) IS NOT NULL)
),

TargetGameEvents AS (
    SELECT *
    FROM IdentifiedEvents
    WHERE game_name IN ('Saint Seiya (TC)','Saint Seiya (SEA)' )
),

-- 1. [性能优化] 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM TargetGameEvents
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 黑名单用户
UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19
    WHERE cluster_name IN ('is_water', 'internal_users')
),

-- 4. 用户标签数据表
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_19
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 5. 用户活跃序列
AccountRetentionArrays AS (
    SELECT s1."#account_id" , s2.fixed_regdate AS reg_date,  
           TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.fixed_regdate AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#account_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM TargetGameEvents v
        CROSS JOIN ScanConfig sc
        WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
          AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
        GROUP BY 1
    ) s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE CAST(s2.fixed_regdate AS DATE) >= sc.target_start_date
),

-- 6. 每日用户净收入明细 (CNY)
DailyAccountRevenue AS (
    SELECT
        v."#account_id",
        v."$part_date",
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange) AS revenue_cny
    FROM TargetGameEvents v
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND v."$part_event" IN ('PURCHASE')
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
    GROUP BY 1,2
),

-- 7. 用户 LTV 映射表
AccountLtvMap AS (
    SELECT
        s2."#account_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.fixed_regdate AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_cny                                                               
        ) AS revenue_map
    FROM DailyAccountRevenue s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE CAST(s2.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1
),

-- 8. 留存率计算指标 (补齐 RR3-RR6)
NewAccountRR AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.fixed_os ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s1.fixed_country ELSE '已合并' END country, 
        CASE WHEN ${Selector:affcode} THEN s1.fixed_affcode ELSE '已合并' END affcode,
        CASE WHEN ${Selector:store} THEN s1.fixed_store ELSE '已合并' END store,  
        COUNT(DISTINCT s1."#account_id") AS new_account,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 7)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 7)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_8,
        CAST(COUNT_IF(CONTAINS(return_days_array, 8)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_9,
        CAST(COUNT_IF(CONTAINS(return_days_array, 9)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_10,
        CAST(COUNT_IF(CONTAINS(return_days_array, 10)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_11,
        CAST(COUNT_IF(CONTAINS(return_days_array, 11)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_12,
        CAST(COUNT_IF(CONTAINS(return_days_array, 12)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_13,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 14)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_15,
        CAST(COUNT_IF(CONTAINS(return_days_array, 15)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_16,
        CAST(COUNT_IF(CONTAINS(return_days_array, 16)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_17,
        CAST(COUNT_IF(CONTAINS(return_days_array, 17)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_18,
        CAST(COUNT_IF(CONTAINS(return_days_array, 18)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_19,
        CAST(COUNT_IF(CONTAINS(return_days_array, 19)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_20,
        CAST(COUNT_IF(CONTAINS(return_days_array, 20)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_21,
        CAST(COUNT_IF(CONTAINS(return_days_array, 21)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_22,
        CAST(COUNT_IF(CONTAINS(return_days_array, 22)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_23,
        CAST(COUNT_IF(CONTAINS(return_days_array, 23)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_24,
        CAST(COUNT_IF(CONTAINS(return_days_array, 24)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_25,
        CAST(COUNT_IF(CONTAINS(return_days_array, 25)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_26,
        CAST(COUNT_IF(CONTAINS(return_days_array, 26)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_27,
        CAST(COUNT_IF(CONTAINS(return_days_array, 27)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_28,
        CAST(COUNT_IF(CONTAINS(return_days_array, 28)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_29,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 119)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_120,
        CAST(COUNT_IF(CONTAINS(return_days_array, 149)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_150,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_180
    FROM UserProfileDetail s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE s4."#account_id" IS NULL
      AND CAST(s1.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3, 4, 5
),

-- 9. 新用户 LTV 计算 (补齐 LTV4-LTV6)
NewAccountLTV AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.fixed_os ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s1.fixed_country ELSE '已合并' END country, 
        CASE WHEN ${Selector:affcode} THEN s1.fixed_affcode ELSE '已合并' END affcode,
        CASE WHEN ${Selector:store} THEN s1.fixed_store ELSE '已合并' END store, 
        COUNT(DISTINCT s1."#account_id") AS new_account,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 2)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_2,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_3,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 4)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_4,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 5)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_5,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 6)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_6,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 8)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_8,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 9)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_9,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 10)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_10,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 11)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_11,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 12)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_12,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 13)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_13,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 15)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_15,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 16)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_16,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 17)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_17,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 18)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_18,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 19)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_19,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 20)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_20,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 21)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_21,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 22)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_22,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 23)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_23,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 24)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_24,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 25)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_25,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 26)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_26,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 27)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_27,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 28)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_28,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 29)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_29,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 120)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_120,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 150)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_150,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_180
    FROM UserProfileDetail s1
    LEFT JOIN AccountLtvMap s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE s4."#account_id" IS NULL
      AND CAST(s1.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3, 4, 5
),

-- 10. 全局 KPI (集成 Selector 自适应周期)
AccountKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s4.fixed_os ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s4.fixed_country ELSE '已合并' END country, 
        CASE WHEN ${Selector:affcode} THEN s4.fixed_affcode ELSE '已合并' END affcode,
        CASE WHEN ${Selector:store} THEN s4.fixed_store ELSE '已合并' END store, 
         MAX(CONCAT(
            CAST(GREATEST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                    ELSE CAST(v."$part_date" AS DATE)
                END, 
                sc.target_start_date
            ) AS VARCHAR),
            ' ~ ',
            CAST(LEAST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', CAST(v."$part_date" AS DATE)))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', CAST(v."$part_date" AS DATE))))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE))))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                    ELSE CAST(v."$part_date" AS DATE)
                END,
                sc.target_end_date
            ) AS VARCHAR)
        )) AS date_range,
        COUNT(DISTINCT v."#account_id") AS active_account,
        COUNT(DISTINCT CASE WHEN v."$part_event" = 'PURCHASE' AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT' THEN v."#account_id" END) AS paying_account,
        SUM(CASE WHEN v."$part_event" = 'PURCHASE' AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT' THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange END) total_revenue_cny
    FROM TargetGameEvents v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserProfileDetail s4 ON v."#account_id"= s4."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    LEFT JOIN UserBlacklist s6 ON v."#account_id" = s6."#account_id"
    WHERE s6."#account_id" IS NULL
      AND v.${PartDate:date1} 
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS','PURCHASE')
      AND (v."$part_event" <> 'PURCHASE' OR JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT')
    GROUP BY 1, 2, 3, 4, 5
),

-- 11. 新用户首期转化 KPI (修复占位符字符串，确保 Join 成功)
NewAccountKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s2.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s2.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s2.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s2.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s2.fixed_os ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s2.fixed_country ELSE '已合并' END country, 
        CASE WHEN ${Selector:affcode} THEN s2.fixed_affcode ELSE '已合并' END affcode,
        CASE WHEN ${Selector:store} THEN s2.fixed_store ELSE '已合并' END store, 
        COUNT(DISTINCT CASE 
            WHEN v."$part_event" = 'PURCHASE' 
            AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
            AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'A' ) 
            )
        THEN v."#account_id" END) AS new_paying_account,
        SUM(CASE 
            WHEN v."$part_event" = 'PURCHASE' 
            AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
            AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'A' ) 
            )
        THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange END) AS new_account_revenue_cny
        
    FROM TargetGameEvents v
    INNER JOIN UserProfileDetail s2 ON v."#account_id" = s2."#account_id"
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    WHERE v.${PartDate:date1}
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS','PURCHASE')
      AND (v."$part_event" <> 'PURCHASE' OR JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT')
      AND CAST(s2.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3, 4, 5
)

-- 12. 最终报表汇总 (增加 RR3-RR6 和 LTV4-LTV6)
SELECT
    k.time_dimension AS "时间维度", 
    k.os_type, 
    k.country, 
    k.affcode, 
    k.store, 
    k.date_range  AS "日期范围",
    active_account, paying_account, total_revenue_cny,
    CAST(k.paying_account AS DOUBLE) / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS payrate,
    k.total_revenue_cny / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS arpu,
    k.total_revenue_cny / NULLIF(CAST(k.paying_account AS DOUBLE), 0.0) AS arppu,
    
    ltv.new_account, 
    p5.new_paying_account, 
    p5.new_account_revenue_cny,
    CAST(p5.new_paying_account AS DOUBLE) / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS new_account_payrate,
    p5.new_account_revenue_cny / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS new_account_arpu,
    p5.new_account_revenue_cny / NULLIF(CAST(p5.new_paying_account AS DOUBLE), 0.0) AS new_account_arppu,

    rr.rr_1, rr.rr_2, rr.rr_3, rr.rr_4, rr.rr_5, rr.rr_6, rr.rr_7, 
    rr.rr_8, rr.rr_9, rr.rr_10, rr.rr_11, rr.rr_12, rr.rr_13, rr.rr_14, rr.rr_15, rr.rr_16, rr.rr_17, rr.rr_18, rr.rr_19, rr.rr_20, rr.rr_21, rr.rr_22, rr.rr_23, rr.rr_24, rr.rr_25, rr.rr_26, rr.rr_27, rr.rr_28, rr.rr_29, rr.rr_30, rr.rr_60, rr.rr_90, rr.rr_120, rr.rr_150, rr.rr_180,
    ltv.ltv_1, ltv.ltv_2, ltv.ltv_3, ltv.ltv_4, ltv.ltv_5, ltv.ltv_6, ltv.ltv_7, 
    ltv.ltv_8, ltv.ltv_9, ltv.ltv_10, ltv.ltv_11, ltv.ltv_12, ltv.ltv_13, ltv.ltv_14, ltv.ltv_15, ltv.ltv_16, ltv.ltv_17, ltv.ltv_18, ltv.ltv_19, ltv.ltv_20, ltv.ltv_21, ltv.ltv_22, ltv.ltv_23, ltv.ltv_24, ltv.ltv_25, ltv.ltv_26, ltv.ltv_27, ltv.ltv_28, ltv.ltv_29, ltv.ltv_30, ltv.ltv_60, ltv.ltv_90, ltv.ltv_120, ltv.ltv_150, ltv.ltv_180
FROM AccountKPI k
LEFT JOIN NewAccountLTV ltv 
    ON k.time_dimension = ltv.time_dimension AND k.os_type = ltv.os_type AND k.country = ltv.country AND k.affcode = ltv.affcode AND k.store = ltv.store 
LEFT JOIN NewAccountRR rr 
    ON k.time_dimension = rr.time_dimension AND k.os_type = rr.os_type AND k.country = rr.country AND k.affcode = rr.affcode AND k.store = rr.store  
LEFT JOIN NewAccountKPI p5 
    ON k.time_dimension = p5.time_dimension AND k.os_type = p5.os_type AND k.country = p5.country AND k.affcode = p5.affcode AND k.store = p5.store 
ORDER BY 1 DESC;