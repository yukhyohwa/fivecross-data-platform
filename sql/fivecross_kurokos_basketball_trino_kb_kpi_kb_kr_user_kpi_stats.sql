/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 综合 KPI 统计 (基于 uuid 作为唯一用户标识)
             - 包含大盘 DAU、MAU、ARPU、ARPPU
             - 包含新用户 (基于 uuid 首次出现)
             - 包含留存 (次留、7留、30留等) 和 LTV (LTV1-360)
             - 【新增】增加了 create_os 维度进行下钻
================================================================================
*/

WITH 
-------------------------------------------------------
-- 1. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 用户-create_os 映射维表 (取用户创建角色时的首个 create_os 作为归属，使用 uuid)
-------------------------------------------------------
UuidOsMap AS (
    SELECT 
        s1.uuid,
        MIN(s1."create_os") AS create_os
    FROM ta.v_event_12 s1
    WHERE s1."$part_event" = 'new_role'
      AND "$part_date" >= '2024-01-24'
      AND s1.uuid IS NOT NULL AND s1.uuid <> ''
    GROUP BY 1
),

-------------------------------------------------------
-- 3. 用户基础表 (定义 uuid 的首次出现日期，并挂载 create_os，排除黑名单)
-------------------------------------------------------
UuidBase AS (
    SELECT 
        uuid, 
        reg_date,
        create_os
    FROM (
        SELECT 
            s1.uuid, 
            s1."$part_date" AS reg_date,
            COALESCE(o.create_os, 'Unknown') AS create_os,
            ROW_NUMBER() OVER (PARTITION BY s1.uuid ORDER BY s1."$part_date" ASC, s1."#event_time" ASC) as rn
        FROM ta.v_event_12 s1
        LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
        LEFT JOIN UuidOsMap o ON s1.uuid = o.uuid
        WHERE s1."$part_event" = 'login'
          AND "$part_date" >= '2024-01-24'
          AND b."#user_id" IS NULL
          AND s1.uuid IS NOT NULL AND s1.uuid <> ''
    ) WHERE rn = 1
),

-------------------------------------------------------
-- 4. 用户留存数组
-------------------------------------------------------
UuidRetentionArrays AS (
    SELECT 
        s1.uuid, 
        s2.reg_date,  
        s2.create_os,
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)) AS return_days_array
    FROM (
        SELECT uuid, ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_12
        WHERE "$part_event" = 'login'
        AND ${PartDate:date1}
        AND uuid IS NOT NULL AND uuid <> ''
        GROUP BY 1
    ) s1
    INNER JOIN UuidBase s2 ON s1.uuid = s2.uuid
),

-------------------------------------------------------
-- 5. 用户 LTV 映射 (直接基于 uuid)
-------------------------------------------------------
UuidLtvMap AS (
    SELECT
        s1.uuid,
        s2.create_os,
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE) 
        ) AS revenue_map
    FROM ta.v_event_12 s1
    INNER JOIN UuidBase s2 ON s1.uuid = s2.uuid
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE (
        (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
        OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
    AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    AND ${PartDate:date1}
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 6. 新用户 RR 与 LTV 聚合
-------------------------------------------------------
NewUserMetrics AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        s1.create_os,
        COUNT(DISTINCT s1.uuid) AS new_users,
        -- 留存率计算
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1.uuid), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1.uuid), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1.uuid), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 89)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1.uuid), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 179)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1.uuid), 0) AS rr_180,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 359)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1.uuid), 0) AS rr_360,
        -- LTV 计算
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 360)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_360
    FROM UuidBase s1
    LEFT JOIN UuidRetentionArrays r ON s1.uuid = r.uuid
    LEFT JOIN UuidLtvMap l ON s1.uuid = l.uuid
    WHERE s1.reg_date IN (SELECT "$part_date" FROM ta.v_event_12 WHERE ${PartDate:date1})
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 7. 整体大盘 KPI (包含 create_os 维度)
-------------------------------------------------------
OverallKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        COALESCE(o.create_os, 'Unknown') AS create_os,
        CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) AS date_range,
        
        -- A. 活跃用户：严格限制 login 事件，且剔除空值
        COUNT(DISTINCT CASE 
            WHEN s1."$part_event" = 'login' 
                 AND s1.uuid IS NOT NULL 
                 AND s1.uuid <> '' 
            THEN s1.uuid 
        END) AS active_users,
        
        -- B. 付费用户：直接基于 uuid 去重
        COUNT(DISTINCT CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            ) 
            AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            AND s1.uuid IS NOT NULL 
            AND s1.uuid <> '' 
            THEN s1.uuid 
        END) AS paying_users,
        
        -- C. 总流水
        SUM(CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            ) 
            AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN s1.pay_amount / COALESCE(ex.exchange, 1) 
            ELSE 0 
        END) AS total_revenue
    FROM ta.v_event_12 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    LEFT JOIN UuidOsMap o ON s1.uuid = o.uuid
    -- 重点：确保 exchange 表按日期和币种是唯一的，避免 Join 后流水翻倍
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    
    WHERE s1."$part_event" IN ('scroin_buy', 'srcoin_buy','charge','login')
      AND ${PartDate:date1}
      AND b."#user_id" IS NULL -- 排除黑名单
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 8. 新用户首取付费
-------------------------------------------------------
NewUserPayKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        s2.create_os,
        COUNT(DISTINCT s1.uuid) AS new_paying_users,
        SUM(s1.pay_amount / COALESCE(ex.exchange, 1)) AS new_user_revenue
    FROM ta.v_event_12 s1
    INNER JOIN UuidBase s2 ON s1.uuid = s2.uuid AND s1."$part_date" = s2.reg_date
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE (
        (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
        OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
    AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    AND ${PartDate:date1}
    GROUP BY 1, 2
)

-------------------------------------------------------
-- 9. 最终输出
-------------------------------------------------------
SELECT
    p1.time_dimension AS "时间维度",
    p1.create_os AS "create_os",
    p1.date_range AS "日期范围",
    p1.active_users AS "活跃用户数(DAU/MAU)",
    p1.paying_users AS "总付费用户数",
    ROUND(p1.total_revenue, 2) AS "总流水(USD)",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.active_users AS DOUBLE), 0), 2) AS "ARPU",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.paying_users AS DOUBLE), 0), 2) AS "ARPPU",
    
    p2.new_users AS "新增用户数",
    p5.new_paying_users AS "新增付费用户数",
    ROUND(p5.new_user_revenue, 2) AS "新增用户流水(USD)",
    CAST(ROUND(p5.new_paying_users / NULLIF(CAST(p2.new_users AS DOUBLE), 0) * 100, 2) AS VARCHAR) || '%' AS "用户首日付费率",
    
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
LEFT JOIN NewUserMetrics p2 ON p1.time_dimension = p2.time_dimension AND p1.create_os = p2.create_os
LEFT JOIN NewUserPayKPI p5 ON p1.time_dimension = p5.time_dimension AND p1.create_os = p5.create_os
ORDER BY p1.time_dimension DESC, p1.create_os ASC;