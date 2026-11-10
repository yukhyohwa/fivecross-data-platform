
/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: TC (Traditional Chinese)
Description: Comprehensive KPI Report (DAU, MAU, LTV, Retention, Revenue)
Trino Syntax
================================================================================
*/

-------------------------------------------------------
-- 1. 用户-设备映射维表 (取用户第一次登录时的设备作为归属设备)
-------------------------------------------------------
WITH UserDeviceMap AS (
    SELECT "#user_id", "#device_id"
    FROM (
        SELECT 
            "#user_id", 
            "#device_id",
            ROW_NUMBER() OVER (PARTITION BY "#user_id" ORDER BY "$part_date" ASC, "#event_time" ASC) as rn
        FROM ta.v_event_10
        WHERE "$part_event" = 'login' 
          AND "$part_date" >= '2024-01-23'
          AND "#device_id" IS NOT NULL 
          AND "#device_id" <> ''
    ) WHERE rn = 1
),

-------------------------------------------------------
-- 2. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 3. 设备基础表 (定义设备的首次出现日期，并排除黑名单用户关联的设备)
-------------------------------------------------------
DeviceBase AS (
    SELECT 
        s1."#device_id", 
        MIN(s1."$part_date") AS reg_date
    FROM ta.v_event_10 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND "$part_date" >= '2024-01-24'
      AND b."#user_id" IS NULL
      AND s1."#device_id" IS NOT NULL AND s1."#device_id" <> ''
    GROUP BY 1
),

-------------------------------------------------------
-- 4. 设备留存数组
-------------------------------------------------------
DeviceRetentionArrays AS (
    SELECT 
        s1."#device_id", 
        s2.reg_date,  
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#device_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_10
        WHERE "$part_event" = 'login'
        AND ${PartDate:date1}
        GROUP BY 1
    ) s1
    INNER JOIN DeviceBase s2 ON s1."#device_id" = s2."#device_id"
),

-------------------------------------------------------
-- 5. 设备 LTV 映射 (通过 UserDeviceMap 将付费挂载到设备上)
-------------------------------------------------------
DeviceLtvMap AS (
    SELECT
        m."#device_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE) 
        ) AS revenue_map
    FROM ta.v_event_10 s1
    INNER JOIN UserDeviceMap m ON s1."#user_id" = m."#user_id" -- 核心：映射付费到设备
    INNER JOIN DeviceBase s2 ON m."#device_id" = s2."#device_id"
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE (
        (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
        OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
    AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    AND ${PartDate:date1}
    GROUP BY 1
),

-------------------------------------------------------
-- 6. 新设备 RR 与 LTV 聚合
-------------------------------------------------------
NewDeviceMetrics AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        COUNT(DISTINCT s1."#device_id") AS new_devices,
        -- 留存率计算
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#device_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#device_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#device_id"), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 89)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#device_id"), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 179)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#device_id"), 0) AS rr_180,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 359)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#device_id"), 0) AS rr_360,
        -- LTV 计算
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 360)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_360
    FROM DeviceBase s1
    LEFT JOIN DeviceRetentionArrays r ON s1."#device_id" = r."#device_id"
    LEFT JOIN DeviceLtvMap l ON s1."#device_id" = l."#device_id"
    WHERE s1.reg_date IN (SELECT "$part_date" FROM ta.v_event_10 WHERE ${PartDate:date1})
    GROUP BY 1
),

-------------------------------------------------------
-- 7. 整体大盘 KPI (应用映射逻辑)
-------------------------------------------------------
OverallKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) AS date_range,
        
        -- A. 活跃设备：严格限制 login 事件，且剔除空值
        COUNT(DISTINCT CASE 
            WHEN s1."$part_event" = 'login' 
                 AND s1."#device_id" IS NOT NULL 
                 AND s1."#device_id" <> '' 
            THEN s1."#device_id" 
        END) AS active_devices,
        
        -- B. 付费设备：通过 UserDeviceMap 归属后的设备去重
        COUNT(DISTINCT CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            ) 
            AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN m."#device_id" 
        END) AS paying_devices,
        
        -- C. 总流水：确保 exchange 表按日期和币种是唯一的，避免 Join 后流水翻倍
        SUM(CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            ) 
            AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN s1.pay_amount / COALESCE(ex.exchange, 1) 
            ELSE 0 
        END) AS total_revenue
    FROM ta.v_event_10 s1
    LEFT JOIN UserDeviceMap m ON s1."#user_id" = m."#user_id"
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    -- 重点：确保 exchange 表按日期和币种是唯一的，避免 Join 后流水翻倍
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    
    WHERE "$part_event" IN ('scroin_buy', 'srcoin_buy','charge','login')
      AND ${PartDate:date1}
      AND b."#user_id" IS NULL -- 排除黑名单
    GROUP BY 1
),

-------------------------------------------------------
-- 8. 新设备首取付费
-------------------------------------------------------
NewDevicePayKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        COUNT(DISTINCT m."#device_id") AS new_paying_devices,
        SUM(s1.pay_amount / COALESCE(ex.exchange, 1)) AS new_device_revenue
    FROM ta.v_event_10 s1
    INNER JOIN UserDeviceMap m ON s1."#user_id" = m."#user_id"
    INNER JOIN DeviceBase s2 ON m."#device_id" = s2."#device_id" AND s1."$part_date" = s2.reg_date
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE (
        (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
        OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
    AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    AND ${PartDate:date1}
    GROUP BY 1
)

-------------------------------------------------------
-- 9. 最终输出
-------------------------------------------------------
SELECT
    p1.time_dimension AS "时间维度",
    p1.date_range AS "日期范围",
    p1.active_devices AS "活跃设备数(DAU/MAU)",
    p1.paying_devices AS "总付费设备数",
    ROUND(p1.total_revenue, 2) AS "总流水(USD)",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.active_devices AS DOUBLE), 0), 2) AS "ARPD",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.paying_devices AS DOUBLE), 0), 2) AS "ARPPD",
    
    p2.new_devices AS "新增设备数",
    p5.new_paying_devices AS "新增付费设备数",
    ROUND(p5.new_device_revenue, 2) AS "新增设备流水(USD)",
    CAST(ROUND(p5.new_paying_devices / NULLIF(CAST(p2.new_devices AS DOUBLE), 0) * 100, 2) AS VARCHAR) || '%' AS "设备首日付费率",
    
    -- 留存
    CAST(ROUND(rr_1 * 100, 2) AS VARCHAR) || '%' AS "次留",
    CAST(ROUND(rr_7 * 100, 2) AS VARCHAR) || '%' AS "7留",
    CAST(ROUND(rr_30 * 100, 2) AS VARCHAR) || '%' AS "30留",
    CAST(ROUND(rr_90 * 100, 2) AS VARCHAR) || '%' AS "90留",
    CAST(ROUND(rr_180 * 100, 2) AS VARCHAR) || '%' AS "180留",
    CAST(ROUND(rr_360 * 100, 2) AS VARCHAR) || '%' AS "360留",
    
    -- LTV
    ROUND(ltv_1, 2) AS "LTV_1",
    ROUND(ltv_7, 2) AS "LTV_7",
    ROUND(ltv_30, 2) AS "LTV_30",
    ROUND(ltv_90, 2) AS "LTV_90",
    ROUND(ltv_180, 2) AS "LTV_180",
    ROUND(ltv_360, 2) AS "LTV_360"

FROM OverallKPI p1
LEFT JOIN NewDeviceMetrics p2 ON p1.time_dimension = p2.time_dimension
LEFT JOIN NewDevicePayKPI p5 ON p1.time_dimension = p5.time_dimension
ORDER BY p1.time_dimension DESC;
