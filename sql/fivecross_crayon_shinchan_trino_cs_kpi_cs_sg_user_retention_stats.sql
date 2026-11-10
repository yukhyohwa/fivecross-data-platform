WITH
-- 目前没有黑名单表格
UserBlacklist AS (
    SELECT 'test' "#user_id" 
),

-- ltv/RR 最终时间起点
StartDate AS (
    SELECT MIN("$part_date") start_date
    FROM ta.v_event_13
    WHERE (${PartDate:date1})
      AND "$part_event" = 'login'
      AND login_type = 4
),

-- 角色新增指标
DeviceMetrics AS (
    SELECT "#user_id", MIN("$part_date") "$part_date"
    FROM ta.v_event_13
    WHERE (${PartDate:date1})
      AND "$part_event" = 'new_role'
    GROUP BY 1
),

-- 角色留存/回访数组
DeviceRetentionArrays AS (
    SELECT s1."#user_id", s2."$part_date" reg_date, 
           TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2."$part_date" AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#user_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM v_event_13 s1
        CROSS JOIN StartDate s2
        WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
          AND (
            "$part_event" = 'new_role' 
            OR ("$part_event" = 'login' AND login_type = 4)
          )
        GROUP BY 1
    ) s1
    INNER JOIN DeviceMetrics s2 ON s1."#user_id" = s2."#user_id"
)

SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '0000-00-00'
    END AS time_dimension,
    COUNT(DISTINCT s1."#user_id") AS new_account,
    -- 1日留存 (Day 0 也是活跃)
    CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_1,
    -- 首周留存：前7天活跃>=3天 / 前7天活跃>=2天
    CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2), 0) AS week1_retention_rate,
    -- 次周回访：首周活跃>=3天且次周活跃>=1天 / 首周活跃>=3天
    CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3), 0) AS week2_return_rate
FROM DeviceMetrics s1
LEFT JOIN DeviceRetentionArrays s2 ON s1."#user_id" = s2."#user_id"
GROUP BY 1
ORDER BY 1 DESC