/*
================================================================================
Game: Crayon Shin-chan (蜡笔小新) - SG/Global (Event 13)
Description: Comprehensive KPI & LTV analysis script.
             Calculates NUU, DAU, Paying Account, Revenue (USD), RR (1-180), and LTV (1-180).
             Includes custom attribution logic from ta_app_start and new_role.
             Filters out Windows users (is_windows) from user_result_cluster_13.
Environment: Trino
Table: ta.v_event_13
================================================================================
*/

WITH
-- 1. [性能优化] 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_13
    WHERE ${PartDate:date1} AND "$part_event" IN ('new_role', 'login')
),

-- 2. 黑名单用户 (排除 Windows 模拟器等)
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

-- 3. 用户基础标签与归属 (整合 ta_app_start 逻辑)
UserAttribution AS (
    SELECT 
        "#user_id",
        "#os" AS os_type,
        country_name,
        ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time" DESC) as rank
    FROM (
        SELECT 
            "#user_id", 
            "#os",
            "#event_time",
            CASE 
                WHEN "#country_code" IN ('HK', 'MO', 'TW') THEN "#province"
                WHEN "#country_code" = 'CN' THEN '中国大陆'
                ELSE "#country" 
            END AS country_name
        FROM ta.v_event_13
        WHERE "$part_date" >= '2025-11-24' -- 蜡笔小新上线或关注的起始点
          AND "$part_event" = 'ta_app_start'
    )
),

UserAttributionFinal AS (
    SELECT "#user_id", os_type, country_name
    FROM UserAttribution
    WHERE rank = 1
),

-- 4. 用户注册信息 (以 new_role 为准)
AccountMetrics AS (
    SELECT
        v."#user_id",
        COALESCE(ua.os_type, '未知') AS os_type,
        COALESCE(ua.country_name, '未知') AS country,
        MIN(v."$part_date") AS reg_date
    FROM ta.v_event_13 v
    LEFT JOIN UserAttributionFinal ua ON v."#user_id" = ua."#user_id"
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= '2025-11-24'
    GROUP BY 1, 2, 3
),

-- 5. 用户活跃序列 (用于留存计算)
AccountRetentionArrays AS (
    SELECT 
        s1."#user_id", 
        s2.reg_date,  
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#user_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_13 v
        CROSS JOIN ScanConfig sc
        WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
          AND v."$part_event" IN ('new_role', 'login')
        GROUP BY 1
    ) s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
),

-- 6. 每日用户收入明细 (USD)
DailyAccountRevenue AS (
    SELECT
        v."#user_id",
        v."$part_date",
        SUM(pay_amount_usd) AS revenue_usd
    FROM ta.v_event_13 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND v."$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    GROUP BY 1, 2
),

-- 7. 用户 LTV 映射表
AccountLtvMap AS (
    SELECT
        s2."#user_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_usd
        ) AS revenue_map
    FROM DailyAccountRevenue s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
    GROUP BY 1
),

-- 8. 留存率计算
NewAccountRR AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.os_type ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END country, 
        COUNT(DISTINCT s1."#user_id") AS new_account,
        -- 常用留存天数
        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_180
    FROM AccountMetrics s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN UserBlacklist s4 ON s1."#user_id" = s4."#user_id"
    CROSS JOIN ScanConfig sc
    WHERE s4."#user_id" IS NULL
      AND CAST(s1.reg_date AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3
),

-- 9. 新用户 LTV 计算
NewAccountLTV AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.os_type ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END country, 
        COUNT(DISTINCT s1."#user_id") AS new_account,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_180
    FROM AccountMetrics s1
    LEFT JOIN AccountLtvMap s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN UserBlacklist s4 ON s1."#user_id" = s4."#user_id"
    CROSS JOIN ScanConfig sc
    WHERE s4."#user_id" IS NULL
      AND CAST(s1.reg_date AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3
),

-- 10. 全局 KPI
AccountKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN ua.os_type ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN ua.country_name ELSE '已合并' END country, 
        CONCAT(MIN(v."$part_date"), ' ~ ', MAX(v."$part_date")) AS date_range,
        COUNT(DISTINCT v."#user_id") AS active_account,
        COUNT(DISTINCT CASE WHEN v."$part_event" = 'charge' THEN v."#user_id" END) AS paying_account,
        SUM(CASE WHEN v."$part_event" = 'charge' THEN pay_amount_usd ELSE 0 END) AS total_revenue_usd
    FROM ta.v_event_13 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserAttributionFinal ua ON v."#user_id" = ua."#user_id"
    LEFT JOIN UserBlacklist s6 ON v."#user_id" = s6."#user_id"
    WHERE s6."#user_id" IS NULL
      AND v.${PartDate:date1} 
      AND v."$part_event" IN ('new_role', 'login', 'charge')
      AND (v."$part_event" <> 'charge' OR ((sandbox IS NULL OR sandbox = FALSE) AND (is_freebuy IS NULL OR is_freebuy = FALSE)))
    GROUP BY 1, 2, 3
),

-- 11. 新用户首期转化 KPI
NewAccountPayMetrics AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.os_type ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END country, 
        COUNT(DISTINCT CASE 
            WHEN v."$part_event" = 'charge' 
            AND (sandbox IS NULL OR sandbox = FALSE)
            AND (is_freebuy IS NULL OR is_freebuy = FALSE)
            AND v."$part_date" = s1.reg_date -- 仅统计注册首日转化，若需统计首期可根据 timetype 调整
        THEN v."#user_id" END) AS new_paying_account,
        SUM(CASE 
            WHEN v."$part_event" = 'charge' 
            AND (sandbox IS NULL OR sandbox = FALSE)
            AND (is_freebuy IS NULL OR is_freebuy = FALSE)
            AND v."$part_date" = s1.reg_date
        THEN pay_amount_usd ELSE 0 END) AS new_account_revenue_usd
    FROM ta.v_event_13 v
    INNER JOIN AccountMetrics s1 ON v."#user_id" = s1."#user_id"
    WHERE v.${PartDate:date1}
      AND v."$part_event" IN ('new_role', 'login', 'charge')
    GROUP BY 1, 2, 3
)

-- 12. 最终报表汇总
SELECT
    k.time_dimension AS "时间维度", 
    k.os_type, 
    k.country, 
    k.date_range AS "日期范围",
    k.active_account AS "活跃用户", 
    k.paying_account AS "付费人数", 
    k.total_revenue_usd AS "总收入(USD)",
    CAST(k.paying_account AS DOUBLE) / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "付费率",
    k.total_revenue_usd / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "ARPU",
    k.total_revenue_usd / NULLIF(CAST(k.paying_account AS DOUBLE), 0.0) AS "ARPPU",
    
    ltv.new_account AS "新增用户", 
    p.new_paying_account AS "新增付费人数", 
    p.new_account_revenue_usd AS "新增首日收入",
    CAST(p.new_paying_account AS DOUBLE) / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增付费率",
    
    rr.rr_2 AS "次留", rr.rr_3 AS "3留", rr.rr_4 AS "4留", rr.rr_5 AS "5留",rr.rr_6 AS "6留",rr.rr_7 AS "7留", rr.rr_14 AS "14留", rr.rr_30 AS "30留",
    ltv.ltv_1, ltv.ltv_7, ltv.ltv_14, ltv.ltv_30, ltv.ltv_60, ltv.ltv_90, ltv.ltv_180
FROM AccountKPI k
LEFT JOIN NewAccountLTV ltv ON k.time_dimension = ltv.time_dimension AND k.os_type = ltv.os_type AND k.country = ltv.country
LEFT JOIN NewAccountRR rr ON k.time_dimension = rr.time_dimension AND k.os_type = rr.os_type AND k.country = rr.country
LEFT JOIN NewAccountPayMetrics p ON k.time_dimension = p.time_dimension AND k.os_type = p.os_type AND k.country = p.country
ORDER BY 1 DESC;
