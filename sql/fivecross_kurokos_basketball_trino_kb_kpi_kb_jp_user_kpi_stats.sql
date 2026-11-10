/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 黑子JP 设备级留存与 LTV 综合报表 (Multi-Dimension KPI Report)
             1. 支持 [时间维度 / 系统 / 国家] 多维聚合
             2. 基于首次登录设备进行归因
             3. 严格排除黑名单用户 (cohort_20231116_224917, cohort_waternew)
             4. 适用于 Trino / Presto SQL (TA 系统)
================================================================================
*/

WITH 
-------------------------------------------------------
-- 1. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 统计周期起始日 (基于 ${PartDate:date1})
-------------------------------------------------------
StartDate AS (
    SELECT MIN("$part_date") AS start_date
    FROM ta.v_event_9
    WHERE ${PartDate:date1} AND "$part_event" = 'login'
),

-------------------------------------------------------
-- 3. 设备分层基础表 (定义归发日期与固化维度)
-------------------------------------------------------
DeviceMetrics AS (
    SELECT 
        "#device_id", 
        MIN("#os") AS ostype,
        MIN(
            CASE 
                WHEN "#country_code" IN ('JP') THEN '日本'
                ELSE '其他地区' 
            END
        ) AS country,
        MIN("$part_date") AS reg_date
    FROM ta.v_event_9
    WHERE "$part_event" = 'login' 
      AND "$part_date" >= '2023-11-15'
      AND "#device_id" IS NOT NULL AND "#device_id" <> ''
    GROUP BY 1
),

-------------------------------------------------------
-- 4. 设备全量维度 (用于活跃/付费设备的实时挂载)
-------------------------------------------------------
AllDeviceMetrics AS (
    SELECT 
        "#device_id",
        ARRAY_SORT(ARRAY_AGG("#os"))[1] AS ostype,
        ARRAY_SORT(ARRAY_AGG(
            CASE 
                WHEN "#country_code" IN ('JP') THEN '日本'
                ELSE '其他地区' 
            END
        ))[1] AS country
    FROM ta.v_event_9
    WHERE "$part_date" >= '2023-11-15' 
      AND "$part_event" = 'login' 
      AND "#device_id" IS NOT NULL
    GROUP BY 1
),

-------------------------------------------------------
-- 5. 用户-设备第一次映射 (用于付费归属)
-------------------------------------------------------
UserToFirstDevice AS (
    SELECT "#user_id", (ARRAY_AGG("#device_id" ORDER BY "$part_date" ASC, "#event_time" ASC))[1] AS first_device_id
    FROM ta.v_event_9
    WHERE "$part_date" >= '2023-11-15' AND "#event_name" = 'login' AND "#device_id" IS NOT NULL
    GROUP BY 1
),

-------------------------------------------------------
-- 6. 设备留存统计
-------------------------------------------------------
DeviceRetentionArrays AS (
    SELECT 
        s1."#device_id", 
        s2.reg_date,  
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#device_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_9 s1
        WHERE s1."$part_date" >= '2023-11-15'
          AND s1."$part_event" = 'login' AND s1."#device_id" IS NOT NULL
        GROUP BY 1
    ) s1
    INNER JOIN DeviceMetrics s2 ON s1."#device_id" = s2."#device_id"
),

-------------------------------------------------------
-- 7. 新设备留存聚合 (核心指标)
-------------------------------------------------------
NewDeviceRR AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.ostype ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END AS country, 
        COUNT(DISTINCT s1."#device_id") AS new_devices,
        -- 留存率
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / NULLIF(CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / NULLIF(CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / NULLIF(CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE), 0) AS rr_180,
        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE) / NULLIF(CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE), 0) AS rr_360
    FROM DeviceMetrics s1
    LEFT JOIN DeviceRetentionArrays s2 ON s1."#device_id" = s2."#device_id"
    WHERE s1.reg_date IN (SELECT "$part_date" FROM ta.v_event_9 WHERE ${PartDate:date1})
    GROUP BY 1, 2, 3
),

-------------------------------------------------------
-- 8. 设备 LTV 逻辑 (映射付费到设备)
-------------------------------------------------------
DeviceLtvMap AS (
    SELECT
        m.first_device_id AS "#device_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE) 
        ) AS revenue_map
    FROM ta.v_event_9 s1
    INNER JOIN UserToFirstDevice m ON s1."#user_id" = m."#user_id"
    INNER JOIN DeviceMetrics s2 ON m.first_device_id = s2."#device_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_event" = 'charge' 
      AND (s1.sandbox = false OR s1.sandbox IS NULL)
      AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    GROUP BY 1
),

-------------------------------------------------------
-- 9. 新设备 LTV 聚合
-------------------------------------------------------
NewDeviceLTV AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.ostype ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END AS country, 
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (s, x) -> s + x, s -> s), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (s, x) -> s + x, s -> s), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (s, x) -> s + x, s -> s), 0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (s, x) -> s + x, s -> s), 0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (s, x) -> s + x, s -> s), 0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (s, x) -> s + x, s -> s), 0)) AS DOUBLE) AS ltv_360
    FROM DeviceMetrics s1
    LEFT JOIN DeviceLtvMap s2 ON s1."#device_id" = s2."#device_id"
    WHERE s1.reg_date IN (SELECT "$part_date" FROM ta.v_event_9 WHERE ${PartDate:date1})
    GROUP BY 1, 2, 3
),

-------------------------------------------------------
-- 10. 整体大盘 KPI (应用多维逻辑)
-------------------------------------------------------
DeviceKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} AND s4.ostype IS NOT NULL THEN s4.ostype ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} AND s4.country IS NOT NULL THEN s4.country ELSE '已合并' END AS country, 
        CONCAT(MIN(s1."$part_date"), ' to ', MAX(s1."$part_date")) AS date_range,
        COUNT(DISTINCT CASE WHEN s1."$part_event" = 'login' THEN s1."#device_id" END) AS active_devices,
        COUNT(DISTINCT CASE WHEN s1."$part_event" = 'charge' THEN s1."#user_id" END) AS paying_users,
        SUM(CASE WHEN s1."$part_event" = 'charge' THEN s1.pay_amount / COALESCE(ex.exchange, 1) ELSE 0 END) AS total_revenue
    FROM ta.v_event_9 s1
    LEFT JOIN UserToFirstDevice s_ufd ON s1."#user_id" = s_ufd."#user_id"
    LEFT JOIN AllDeviceMetrics s4 ON COALESCE(s1."#device_id", s_ufd.first_device_id) = s4."#device_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" IN ('charge', 'login')
      AND (s1."$part_event" <> 'charge' OR ( (s1.sandbox = false OR s1.sandbox IS NULL) AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL) ))
      AND b."#user_id" IS NULL
      AND ${PartDate:date1}
    GROUP BY 1, 2, 3
),

-------------------------------------------------------
-- 11. 新设备首日 KPI
-------------------------------------------------------
NewDeviceKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s2.ostype ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN s2.country ELSE '已合并' END AS country, 
        COUNT(DISTINCT s1."#user_id") AS new_paying_users,
        SUM(s1.pay_amount / COALESCE(ex.exchange, 1)) AS new_device_revenue
    FROM ta.v_event_9 s1
    INNER JOIN UserToFirstDevice s_ufd ON s1."#user_id" = s_ufd."#user_id"
    INNER JOIN DeviceMetrics s2 ON s_ufd.first_device_id = s2."#device_id" AND s1."$part_date" = s2.reg_date
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'charge'
      AND (s1.sandbox = false OR s1.sandbox IS NULL)
      AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
      AND b."#user_id" IS NULL
      AND ${PartDate:date1}
    GROUP BY 1, 2, 3  
) 

-------------------------------------------------------
-- 12. 最终汇总输出
-------------------------------------------------------
SELECT
    p1.time_dimension AS "时间维度",
    p1.os_type AS "系统",
    p1.country AS "国家",
    p1.date_range AS "日期范围",
    
    p1.active_devices AS "活跃设备数(DAU)",
    p1.paying_users AS "总付费用户数",
    ROUND(p1.total_revenue, 2) AS "总流水(USD)",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.active_devices AS DOUBLE), 0), 2) AS "ARPD",
    
    p2_rr.new_devices AS "新增设备数",
    p5.new_paying_users AS "新增付费用户数数",
    ROUND(p5.new_device_revenue, 2) AS "新增用户流水(USD)",
    CAST(ROUND(p3.rr_1 * 100, 2) AS VARCHAR) || '%' AS "次留",
    CAST(ROUND(p3.rr_7 * 100, 2) AS VARCHAR) || '%' AS "7留",
    CAST(ROUND(p3.rr_30 * 100, 2) AS VARCHAR) || '%' AS "30留",
    
    ROUND(p2_ltv.ltv_1, 2) AS "LTV_1",
    ROUND(p2_ltv.ltv_7, 2) AS "LTV_7",
    ROUND(p2_ltv.ltv_30, 2) AS "LTV_30",
    ROUND(p2_ltv.ltv_90, 2) AS "LTV_90"

FROM DeviceKPI p1
LEFT JOIN NewDeviceRR p3 ON p1.time_dimension = p3.time_dimension AND p1.os_type = p3.os_type AND p1.country = p3.country 
LEFT JOIN NewDeviceLTV p2_ltv ON p1.time_dimension = p2_ltv.time_dimension AND p1.os_type = p2_ltv.os_type AND p1.country = p2_ltv.country 
LEFT JOIN (SELECT time_dimension, os_type, country, new_devices FROM NewDeviceRR) p2_rr 
    ON p1.time_dimension = p2_rr.time_dimension AND p1.os_type = p2_rr.os_type AND p1.country = p2_rr.country
LEFT JOIN NewDeviceKPI p5 ON p1.time_dimension = p5.time_dimension AND p1.os_type = p5.os_type AND p1.country = p5.country

ORDER BY p1.time_dimension DESC;
