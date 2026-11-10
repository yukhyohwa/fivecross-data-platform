/*
================================================================================
Game    : Crayon Shin-chan (蜡笔小新)
Region  : TC
Table   : ta.v_event_13
Events  :
  - Active  : login
  - New User: new_role
  - Purchase: charge (pay_amount_usd, already USD, no exchange needed)
================================================================================
*/

WITH
-- 黑名单用户
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

-- 用户标签数据表
UserProfileDetail AS (
    SELECT 
        CAST("#varchar_id" AS DOUBLE) AS "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_13
    WHERE cluster_name IN ('fixed_country', 'fixed_os', 'fixed_regdate')
    GROUP BY 1
),

-- 筛选日期范围
DimDate AS (
    SELECT DISTINCT "$part_date"
    FROM ta.v_event_13
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('login')
),

-- LTV/RR 扫描起始日
StartDate AS (
    SELECT MIN("$part_date") start_date
    FROM ta.v_event_13
    WHERE ${PartDate:date1}
      AND "$part_event" = 'login'
),

-- 新用户基础信息（依赖 UserProfileDetail 固化标签）
AccountMetrics AS (
    SELECT
        "#user_id",
        COALESCE(fixed_os, '未知') AS ostype,
        COALESCE(fixed_country, '未知') AS country,
        fixed_regdate AS "$part_date"
    FROM UserProfileDetail
    WHERE fixed_regdate IS NOT NULL
      AND fixed_regdate IN (SELECT DISTINCT "$part_date" FROM ta.v_event_13 WHERE ${PartDate:date1})
),

-- 全量用户维度（用于大盘 KPI 关联）
ALLAccountMetrics AS (
    SELECT
        "#user_id",
        COALESCE(fixed_os, '未知') AS ostype,
        COALESCE(fixed_country, '未知') AS country
    FROM UserProfileDetail
),

-- 留存数组
AccountRetentionArrays AS (
    SELECT
        s1."#user_id",
        s2."$part_date" reg_date,
        TRANSFORM(
            ARRAY_SORT(s1.return_date_array),
            d -> DATE_DIFF('day', CAST(s2."$part_date" AS DATE), d)
        ) AS return_days_array
    FROM (
        SELECT
            "#user_id",
            ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_13 s1
        CROSS JOIN StartDate s2
        WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
          AND "$part_event" IN ('new_role', 'login')
        GROUP BY 1
    ) s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
),

-- 新用户留存率
NewAccountRR AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day',     CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week',    CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month',   CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype}   THEN s1.ostype  ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country}  THEN s1.country ELSE '已合并' END country,
        COUNT(DISTINCT s1."#user_id") AS new_account,
        CAST(COUNT_IF(CONTAINS(return_days_array, 0))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6))   AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13))  AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29))  AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59))  AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89))  AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_180,
        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#user_id") AS DOUBLE) AS rr_360,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3) AS DOUBLE)
            / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2), 0) week1_retention_rate,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3
                  AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE)
            / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3), 0) week2_return_rate
    FROM AccountMetrics s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN UserBlacklist s4          ON s1."#user_id" = s4."#user_id"
    WHERE s4."#user_id" IS NULL
    GROUP BY 1, 2, 3
),

-- 每日付费明细（pay_amount_usd 已是 USD，无需汇率）
DailyAccountRevenue AS (
    SELECT
        "#user_id",
        "$part_date",
        SUM(pay_amount_usd) AS revenue_usd
    FROM ta.v_event_13 s1
    CROSS JOIN StartDate s2
    WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
      AND "$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    GROUP BY 1, 2
),

-- LTV MAP
AccountLtvMap AS (
    SELECT
        s2."#user_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2."$part_date" AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_usd
        ) AS revenue_map
    FROM DailyAccountRevenue s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
    GROUP BY 1
),

-- 新用户 LTV
NewAccountLTV AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day',     CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week',    CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month',   CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype}  THEN s1.ostype  ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END country,
        COUNT(DISTINCT s1."#user_id") AS new_account,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 2)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_2,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_3,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 4)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_4,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 5)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_5,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 6)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_6,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_360,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_1,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 2)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_2,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_3,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 4)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_4,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 5)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_5,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 6)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_6,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)),   0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_7,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_14,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_30,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_60,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)),  0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_90,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_180,
        CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_360
    FROM AccountMetrics s1
    LEFT JOIN AccountLtvMap s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN UserBlacklist s4 ON s1."#user_id" = s4."#user_id"
    WHERE s4."#user_id" IS NULL
    GROUP BY 1, 2, 3
),

-- 整体大盘 KPI
AccountKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day',     CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week',    CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month',   CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype}  THEN s4.ostype  ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s4.country ELSE '已合并' END country,
        CONCAT(MIN(s1."$part_date"), '-', MAX(s1."$part_date")) date_range,
        COUNT(DISTINCT s1."#user_id")                                        AS active_account,
        COUNT(DISTINCT CASE WHEN "$part_event" = 'charge' THEN s1."#user_id" END) AS paying_account,
        SUM(CASE WHEN "$part_event" = 'charge' THEN pay_amount_usd ELSE 0 END)  AS total_revenue
    FROM ta.v_event_13 s1
    LEFT JOIN ALLAccountMetrics s4 ON s1."#user_id" = s4."#user_id"
    LEFT JOIN UserBlacklist     s6 ON s1."#user_id" = s6."#user_id"
    WHERE s6."#user_id" IS NULL
      AND s1.${PartDate:date1}
      AND ("$part_event" = 'login' OR ("$part_event" = 'charge' AND (sandbox IS NULL OR sandbox = FALSE) AND (is_freebuy IS NULL OR is_freebuy = FALSE)))
    GROUP BY 1, 2, 3
),

-- 新用户首期付费
NewAccountKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day',     CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week',    CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month',   CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '0000-00-00'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype}  THEN s2.ostype  ELSE '已合并' END os_type,
        CASE WHEN ${Selector:country} THEN s2.country ELSE '已合并' END country,
        COUNT(DISTINCT CASE
            WHEN "$part_event" = 'charge' AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day',     CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('day',     CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week',    CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('week',    CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month',   CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('month',   CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'A')
            ) THEN s1."#user_id" END)                                        AS new_paying_account,
        SUM(CASE
            WHEN "$part_event" = 'charge' AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day',     CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('day',     CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week',    CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('week',    CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month',   CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('month',   CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'A')
            ) THEN pay_amount_usd ELSE 0 END)                                   AS new_account_revenue
    FROM ta.v_event_13 s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN  UserBlacklist  s4 ON s1."#user_id" = s4."#user_id"
    WHERE s4."#user_id" IS NULL
      AND s1.${PartDate:date1}
      AND ("$part_event" = 'login' OR ("$part_event" = 'charge' AND (sandbox IS NULL OR sandbox = FALSE) AND (is_freebuy IS NULL OR is_freebuy = FALSE)))
    GROUP BY 1, 2, 3
)

-- 最终输出
SELECT
    p1.time_dimension,
    p1.os_type,
    p1.country,
    p1.date_range,
    active_account,
    paying_account,
    total_revenue,
    paying_account / CAST(active_account AS DOUBLE)  payrate,
    total_revenue  / CAST(active_account AS DOUBLE)  arpu,
    total_revenue  / CAST(paying_account AS DOUBLE)  arppu,
    p2.new_account,
    p5.new_paying_account,
    p5.new_account_revenue,
    p5.new_paying_account / CAST(p2.new_account AS DOUBLE) new_account_payrate,
    p5.new_account_revenue / p2.new_account                new_account_arpu,
    p5.new_account_revenue / p5.new_paying_account         new_account_arppu,
    rr_1, rr_2, rr_3, rr_4, rr_5, rr_6, rr_7,
    rr_14, rr_30, rr_60, rr_90, rr_180, rr_360,
    week1_retention_rate, week2_return_rate,
    ltv_1, ltv_2, ltv_3, ltv_4, ltv_5, ltv_6, ltv_7,
    ltv_14, ltv_30, ltv_60, ltv_90, ltv_180, ltv_360
FROM AccountKPI p1
LEFT JOIN NewAccountLTV p2
    ON p1.time_dimension = p2.time_dimension
   AND p1.os_type = p2.os_type AND p1.country = p2.country
LEFT JOIN NewAccountRR p3
    ON p1.time_dimension = p3.time_dimension
   AND p1.os_type = p3.os_type AND p1.country = p3.country
LEFT JOIN NewAccountKPI p5
    ON p1.time_dimension = p5.time_dimension
   AND p1.os_type = p5.os_type AND p1.country = p5.country;
