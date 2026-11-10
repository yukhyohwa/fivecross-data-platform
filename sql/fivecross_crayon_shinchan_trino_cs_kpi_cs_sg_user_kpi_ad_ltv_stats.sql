/*
================================================================================
Game    : Crayon Shin-chan (蜡笔小新)
Region  : TC
Table   : ta.v_event_13
Events  :
  - Active        : login
  - Purchase      : charge
  - Ad Impression : game_ad_impression
Description: 统计不同时间周期下，新用户群体带来的综合 LTV (充值收入 + 广告收入) 和总预估收益。
================================================================================
*/

WITH
-- 黑名单用户 (结合了LTV和广告逻辑中的过滤)
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),

-- 用户标签数据表 (获取固化标签)
UserProfileDetail AS (
    SELECT 
        "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_13
    WHERE cluster_name IN ('fixed_country', 'fixed_os', 'fixed_regdate')
    GROUP BY 1
),

-- LTV 扫描起始日
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

-- 每日综合收益明细 (充值收入 + 广告收入)
DailyTotalRevenue AS (
    SELECT
        s1."#user_id",
        s1."$part_date",
        SUM(
            CASE 
                WHEN s1."$part_event" = 'charge' THEN CAST(s1.pay_amount_usd AS DOUBLE)
                WHEN s1."$part_event" = 'game_ad_impression' THEN 
                    CASE WHEN s1."#os"='Android' THEN CAST(s1.value AS DOUBLE)/1000 ELSE CAST(s1.value AS DOUBLE) END
                ELSE 0.0
            END
        ) AS total_revenue_usd
    FROM ta.v_event_13 s1
    CROSS JOIN StartDate s2
    WHERE s1."$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
      AND (
          (s1."$part_event" = 'charge' AND (s1.sandbox IS NULL OR s1.sandbox = FALSE) AND (s1.is_freebuy IS NULL OR s1.is_freebuy = FALSE))
          OR
          (s1."$part_event" = 'game_ad_impression' AND CAST(s1.status AS INTEGER) = 1)
      )
    GROUP BY 1, 2
),

-- LTV MAP (计算每一天的综合收益映射)
AccountTotalLtvMap AS (
    SELECT
        s2."#user_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2."$part_date" AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.total_revenue_usd
        ) AS revenue_map
    FROM DailyTotalRevenue s1
    INNER JOIN AccountMetrics s2 ON s1."#user_id" = s2."#user_id"
    GROUP BY 1
),

-- 新用户综合 LTV
NewAccountTotalLTV AS (
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
        
        -- 计算各周期的平均综合 LTV
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
        
        -- 计算各周期的总综合收益
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
    LEFT JOIN AccountTotalLtvMap s2 ON s1."#user_id" = s2."#user_id"
    LEFT JOIN UserBlacklist s4 ON s1."#user_id" = s4."#user_id"
    WHERE s4."#user_id" IS NULL
    GROUP BY 1, 2, 3
)

-- 最终输出
SELECT
    time_dimension AS "时间周期",
    os_type AS "操作系统",
    country AS "国家/地区",
    new_account AS "新用户数",
    ltv_1 AS "综合LTV_1", ltv_2 AS "综合LTV_2", ltv_3 AS "综合LTV_3", ltv_4 AS "综合LTV_4", ltv_5 AS "综合LTV_5", ltv_6 AS "综合LTV_6", ltv_7 AS "综合LTV_7",
    ltv_14 AS "综合LTV_14", ltv_30 AS "综合LTV_30", ltv_60 AS "综合LTV_60", ltv_90 AS "综合LTV_90", ltv_180 AS "综合LTV_180", ltv_360 AS "综合LTV_360",
    revenue_1 AS "综合总收益_1", revenue_2 AS "综合总收益_2", revenue_3 AS "综合总收益_3", revenue_4 AS "综合总收益_4", revenue_5 AS "综合总收益_5", revenue_6 AS "综合总收益_6", revenue_7 AS "综合总收益_7",
    revenue_14 AS "综合总收益_14", revenue_30 AS "综合总收益_30", revenue_60 AS "综合总收益_60", revenue_90 AS "综合总收益_90", revenue_180 AS "综合总收益_180", revenue_360 AS "综合总收益_360"
FROM NewAccountTotalLTV
ORDER BY 1 DESC;
