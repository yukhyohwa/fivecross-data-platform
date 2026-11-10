WITH 
-------------------------------------------------------
-- 1. 时间范围锚点 (仅保留事件时间)
-------------------------------------------------------
StartDate AS (
    SELECT MIN("$part_date") start_date
    FROM ta.v_event_5
    WHERE ${PartDate:date1}
      AND "$part_event" = 'login'
),

-------------------------------------------------------
-- 2. 新用户基础表 (定义用户的首登日期)
-------------------------------------------------------
AccountMetrics AS (
    SELECT 
        "#user_id", 
        MIN("$part_date") AS reg_date
    FROM ta.v_event_5
    WHERE "$part_date" >= '2020-01-01' -- 扫描历史确保新用户判定的准确性
      AND "$part_event" = 'login'
    GROUP BY 1
),

-------------------------------------------------------
-- 3. 留存数据构建 (按天偏移量生成的数组)
-------------------------------------------------------
AccountRetentionArrays AS (
    SELECT 
        s1."#user_id", 
        s2.reg_date,  
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#user_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_5 s1
        CROSS JOIN StartDate s2
        WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
          AND "$part_event" = 'login'
        GROUP BY 1
    ) s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
),

-------------------------------------------------------
-- 4. 新用户留存率 (RR) 聚合
-------------------------------------------------------
NewAccountRR AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        COUNT(DISTINCT s1."#user_id") AS new_account,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#user_id"), 0) AS rr_30
    FROM AccountMetrics s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#user_id" = s2."#user_id"
    WHERE s1.reg_date IN (SELECT "$part_date" FROM ta.v_event_5 WHERE ${PartDate:date1})
    GROUP BY 1
),

-------------------------------------------------------
-- 5. LTV 基础映射 (直接取日元 order_balance_price)
-------------------------------------------------------
AccountLtvMap AS (
    SELECT
        s2."#user_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.order_balance_price AS DOUBLE) 
        ) AS revenue_map
    FROM ta.v_event_5 s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
    WHERE s1."$part_event" = 'order_finish'
    GROUP BY 1
),

-------------------------------------------------------
-- 6. 新用户 LTV 聚合
-------------------------------------------------------
NewAccountLTV AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_3,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE) AS ltv_30
    FROM AccountMetrics s1
    LEFT JOIN AccountLtvMap s2 ON s1."#user_id" = s2."#user_id"
    WHERE s1.reg_date IN (SELECT "$part_date" FROM ta.v_event_5 WHERE ${PartDate:date1})
    GROUP BY 1
),

-------------------------------------------------------
-- 7. 整体活跃与流水 KPI (大盘数据)
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
        COUNT(DISTINCT CASE WHEN "$part_event" = 'login' THEN s1."#user_id" END) AS active_account,
        COUNT(DISTINCT CASE WHEN "$part_event" = 'order_finish' THEN s1."#user_id" END) AS paying_account,
        SUM(CASE WHEN "$part_event" = 'order_finish' THEN CAST(s1.order_balance_price AS DOUBLE) ELSE 0 END) AS total_revenue
    FROM ta.v_event_5 s1
    WHERE ${PartDate:date1}
      AND s1."$part_event" IN ('login', 'order_finish')
    GROUP BY 1
),

-------------------------------------------------------
-- 8. 新用户付费指标 (当日新增当日付费)
-------------------------------------------------------
NewAccountPayKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            ELSE '0000-00-00'
        END AS time_dimension,
        COUNT(DISTINCT CASE WHEN s1."$part_event" = 'order_finish' AND s1."$part_date" = s2.reg_date THEN s1."#user_id" END) AS new_paying_account,
        SUM(CASE WHEN s1."$part_event" = 'order_finish' AND s1."$part_date" = s2.reg_date THEN CAST(s1.order_balance_price AS DOUBLE) ELSE 0 END) AS new_account_revenue
    FROM ta.v_event_5 s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
    WHERE ${PartDate:date1}
      AND s1."$part_event" IN ('login', 'order_finish')
    GROUP BY 1
)



-------------------------------------------------------
-- 9. 最终结果合并
-------------------------------------------------------

SELECT
    p1.time_dimension AS "时间维度",
    p1.date_range AS "日期范围",
    p1.active_account AS "DAU/MAU",
    p1.paying_account AS "总付费人数",
    ROUND(p1.total_revenue, 2) AS "总流水(JPY)",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.active_account AS DOUBLE), 0),2) AS "ARPU(JPY)",
    ROUND(p1.total_revenue / NULLIF(CAST(p1.paying_account AS DOUBLE), 0),2)  AS "ARPPU(JPY)",
    
    p2.new_account AS "新增人数",
    p5.new_paying_account AS "新增付费人数",
    ROUND(p5.new_account_revenue, 2) AS "新增流水(JPY)",
    CAST(ROUND(p5.new_paying_account / NULLIF(CAST(p2.new_account AS DOUBLE), 0) * 100, 2) AS VARCHAR) || '%' AS "新增付费率",
    
    -- 使用 CAST( ... AS VARCHAR) 确保可以与 '%' 拼接
    CAST(ROUND(rr_1 * 100, 2) AS VARCHAR) || '%' AS "次留",
    CAST(ROUND(rr_3 * 100, 2) AS VARCHAR) || '%' AS "3留",
    CAST(ROUND(rr_7 * 100, 2) AS VARCHAR) || '%' AS "7留",
    CAST(ROUND(rr_14 * 100, 2) AS VARCHAR) || '%' AS "14留",
    CAST(ROUND(rr_30 * 100, 2) AS VARCHAR) || '%' AS "30留",
    
    -- LTV 指标保持数字类型
    ROUND(ltv_1, 2) AS "LTV_1(JPY)",
    ROUND(ltv_3, 2) AS "LTV_3(JPY)",
    ROUND(ltv_7, 2) AS "LTV_7(JPY)",
    ROUND(ltv_14, 2) AS "LTV_14(JPY)",
    ROUND(ltv_30, 2) AS "LTV_30(JPY)"

FROM OverallKPI p1
LEFT JOIN NewAccountRR p2 ON p1.time_dimension = p2.time_dimension
LEFT JOIN NewAccountLTV p3 ON p1.time_dimension = p3.time_dimension
LEFT JOIN NewAccountPayKPI p5 ON p1.time_dimension = p5.time_dimension
ORDER BY p1.time_dimension;