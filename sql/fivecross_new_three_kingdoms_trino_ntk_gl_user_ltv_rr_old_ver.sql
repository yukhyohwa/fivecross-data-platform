WITH
-- 1. 黑名单用户 (目前的定义为有过免费代币消耗记录的用户，可根据业务调整)
UserBlacklist AS (
    SELECT "lcxuserid" "#account_id"
    FROM ta.v_event_19 v
    WHERE v."$part_date" >= '2026-02-01'
    AND v."$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
    AND ABS(v.freeamount) > 0
    AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1
),

-- 3. 用户标签数据表 (聚合用户属性)
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

-- 4. 统计起始日期
StartDate AS (
    SELECT MIN("$part_date") start_date
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'LOGIN_SUCCESS'
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
),

-- 5. 用户留存天数序列
AccountRetentionArrays AS (
    SELECT s1."#account_id" , s2.fixed_regdate AS reg_date,  
           TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.fixed_regdate AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#account_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_19 v
        CROSS JOIN StartDate s2
        WHERE v."$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
          AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
          AND (
               v.applicationid IN ('65002004') 
            OR v.productid IN ('65002004') 
            OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
            OR substring(v.affcode, -8) IN ('65002004') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
          )
        GROUP BY 1
    ) s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    WHERE s2.fixed_regdate >= '2026-02-01'
),

-- 6. 各维度留存率计算
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
        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_180,
        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_360,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2), 0) week1_retention_rate,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3), 0) week2_return_rate
    FROM UserProfileDetail s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    WHERE s4."#account_id" IS NULL
      AND s1.fixed_regdate >= '2026-02-01'
    GROUP BY 1, 2, 3, 4, 5
),

-- 7. 每日用户净收入明细 (CNY)
DailyAccountRevenue AS (
    SELECT
        s1."#account_id",
        s1."$part_date",
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange) AS revenue_cny
    FROM ta.v_event_19 s1
    LEFT JOIN ta_dim.ta_exchange s5 ON s1."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON s1."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    CROSS JOIN StartDate s2
    WHERE s1."$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
      AND s1."$part_event" IN ('PURCHASE')
      AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND (
           s1.applicationid IN ('65002004') 
        OR s1.productid IN ('65002004') 
        OR regexp_extract(s1.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(s1.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1,2
),

-- 8. 用户 LTV 映射表
AccountLtvMap AS (
    SELECT
        s2."#account_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.fixed_regdate AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_cny                                                               
        ) AS revenue_map
    FROM DailyAccountRevenue s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    WHERE s2.fixed_regdate >= '2026-02-01'
    GROUP BY 1
),

-- 9. 新用户 LTV 计算
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
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 2)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_2,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_3,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 4)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_4,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 5)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_5,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 6)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_6,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_360,

        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_1,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 2)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_2,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_3,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 4)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_4,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 5)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_5,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 6)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_6,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_7,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_14,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_30,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_60,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_90,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_180,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS revenue_360
    FROM UserProfileDetail s1
    LEFT JOIN AccountLtvMap s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    WHERE s4."#account_id" IS NULL
      AND s1.fixed_regdate >= '2026-02-01'
    GROUP BY 1, 2, 3, 4, 5
),

-- 10. 全局 KPI (CNY)
AccountKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s4.fixed_os ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s4.fixed_country ELSE '已合并' END country, 
        CASE WHEN ${Selector:affcode} THEN s4.fixed_affcode ELSE '已合并' END affcode,
        CASE WHEN ${Selector:store} THEN s4.fixed_store ELSE '已合并' END store, 
        CONCAT(MIN(s1."$part_date"), '-', MAX(s1."$part_date")) date_range,
        COUNT(DISTINCT s1."#account_id") AS active_account,
        COUNT(DISTINCT CASE WHEN "$part_event" IN ('PURCHASE') AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT' THEN s1."#account_id" END) AS paying_account,
        SUM(CASE WHEN "$part_event" IN ('PURCHASE') AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT' THEN CAST(JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange END) total_revenue_cny
    FROM ta.v_event_19 s1
    LEFT JOIN UserProfileDetail s4 ON s1."#account_id"= s4."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON s1."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON s1."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    LEFT JOIN UserBlacklist s6 ON s1."#account_id" = s6."#account_id"
    WHERE s6."#account_id" IS NULL
      AND s1.${PartDate:date1} 
      AND "$part_event" IN ('LOGIN_SUCCESS','PURCHASE')
      AND (
           s1.applicationid IN ('65002004') 
        OR s1.productid IN ('65002004') 
        OR regexp_extract(s1.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(s1.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2, 3, 4, 5
),

-- 11. 新用户 KPI (CNY)
NewAccountKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s2.fixed_os ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s2.fixed_country ELSE '已合并' END country, 
        CASE WHEN ${Selector:affcode} THEN s2.fixed_affcode ELSE '已合并' END affcode,
        CASE WHEN ${Selector:store} THEN s2.fixed_store ELSE '已合并' END store, 
        COUNT(DISTINCT CASE 
            WHEN "$part_event" IN ('PURCHASE') 
            AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
            AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'A' ) 
            )
        THEN s1."#account_id" END) AS new_paying_account,

        SUM(CASE 
            WHEN "$part_event" IN ('PURCHASE') 
            AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
            AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2.fixed_regdate AS DATE))) OR
                (${Selector:timetype} = 'A'  ) 
            )
        THEN CAST(JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange END) AS new_account_revenue_cny
        
    FROM ta.v_event_19 s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON s1."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON s1."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    WHERE s4."#account_id" IS NULL
      AND s2.fixed_regdate >= '2026-02-01'
      AND s1.${PartDate:date1}
      AND "$part_event" IN ('LOGIN_SUCCESS','PURCHASE') 
      AND (
           s1.applicationid IN ('65002004') 
        OR s1.productid IN ('65002004') 
        OR regexp_extract(s1.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(s1.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(s1.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2, 3, 4, 5
) 

-- 12. 最终报表汇总
SELECT
    p1.time_dimension, p1.os_type, p1.country, p1.affcode, p1.store, p1.date_range,
    active_account, paying_account, total_revenue_cny,
    paying_account / CAST(active_account AS DOUBLE) payrate,
    total_revenue_cny / CAST(active_account AS DOUBLE) arpu,
    total_revenue_cny / CAST(paying_account AS DOUBLE) arppu,
    p2.new_account, p5.new_paying_account, p5.new_account_revenue_cny,
    p5.new_paying_account / CAST(p2.new_account AS DOUBLE) new_account_payrate,
    p5.new_account_revenue_cny / p2.new_account new_account_arpu,
    p5.new_account_revenue_cny / p5.new_paying_account new_account_arppu,
    rr_1,rr_2,rr_3,rr_4,rr_5,rr_6,rr_7,rr_14,rr_30,rr_60,rr_90,rr_180,rr_360,
    week1_retention_rate, week2_return_rate,
    ltv_1,ltv_2,ltv_3,ltv_4,ltv_5,ltv_6,ltv_7,ltv_14,ltv_30,ltv_60,ltv_90,ltv_180,ltv_360
FROM AccountKPI p1
LEFT JOIN NewAccountLTV p2 
ON p1.time_dimension = p2.time_dimension AND p1.os_type = p2.os_type AND p1.country = p2.country AND p1.affcode = p2.affcode AND p1.store = p2.store 
LEFT JOIN NewAccountRR p3 
ON p1.time_dimension = p3.time_dimension AND p1.os_type = p3.os_type AND p1.country = p3.country AND p1.affcode = p3.affcode AND p1.store = p3.store  
LEFT JOIN NewAccountKPI p5 
ON p1.time_dimension = p5.time_dimension AND p1.os_type = p5.os_type AND p1.country = p5.country AND p1.affcode = p5.affcode AND p1.store = p5.store 
ORDER BY 1 DESC, 2, 3;
