/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese - TW/HK/MO)
Description: 核心 KPI 报表 (LTV, 留存, 收入) - 使用【用户标签】加速方案
             1. 使用 UserProfileDetail (来自 user_result_cluster_16) 确定注册日期、维度。
             2. 包含 LTV (1-30) 和 留存 (次留-30留) 以及 一阶/二阶登录比率。
             3. 周期自适应：支持日、周、月维度聚合。
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. [性能优化] 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 黑名单用户 (集成日期过滤)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 3. 用户标签数据表 (核心加速方案)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 4. 用户活跃序列
AccountRetentionArrays AS (
    SELECT s1."#account_id" , s2.fixed_regdate AS reg_date,  
           TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2.fixed_regdate AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#account_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_16 v
        CROSS JOIN ScanConfig sc
        WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
          AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
        GROUP BY 1
    ) s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE CAST(s2.fixed_regdate AS DATE) >= sc.target_start_date
),

-- 5. 每日用户净收入明细 (USD)
DailyAccountRevenue AS (
    SELECT
        v."#account_id",
        v."$part_date",
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1)) AS revenue_usd
    FROM ta.v_event_16 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND v."$part_event" IN ('PURCHASE')
      AND v.payload.validationtype <>'SANDBOX_RECEIPT'
    GROUP BY 1,2
),

-- 6. 用户 LTV 映射表
AccountLtvMap AS (
    SELECT
        s2."#account_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.fixed_regdate AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_usd                                                               
        ) AS revenue_map
    FROM DailyAccountRevenue s1
    INNER JOIN UserProfileDetail s2 ON s1."#account_id" = s2."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE CAST(s2.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1
),

-- 7. 留存率计算指标
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
        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_180,
        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE) / NULLIF(COUNT(DISTINCT s1."#account_id"), 0) AS rr_360,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2), 0) week1_retention_rate,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3), 0) week2_return_rate
    FROM UserProfileDetail s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE s4."#account_id" IS NULL
      AND CAST(s1.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3, 4, 5
),

-- 8. 新用户 LTV 计算
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
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_360
    FROM UserProfileDetail s1
    LEFT JOIN AccountLtvMap s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE s4."#account_id" IS NULL
      AND CAST(s1.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3, 4, 5
),

-- 9. 全局 KPI
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
        SUM(CASE WHEN v."$part_event" = 'PURCHASE' AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT' THEN (CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)) / COALESCE(s5.exchange, 1) END) total_revenue_usd
    FROM ta.v_event_16 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserProfileDetail s4 ON v."#account_id"= s4."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN UserBlacklist s6 ON v."#account_id" = s6."#account_id"
    WHERE s6."#account_id" IS NULL
      AND v.${PartDate:date1} 
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS','PURCHASE')
      AND (v."$part_event" <> 'PURCHASE' OR JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT')
    GROUP BY 1, 2, 3, 4, 5
),

-- 10. 新用户首期转化 KPI
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
        THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) END) AS new_account_revenue_usd
        
    FROM ta.v_event_16 v
    INNER JOIN UserProfileDetail s2 ON v."#account_id" = s2."#account_id"
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    WHERE v.${PartDate:date1}
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS','PURCHASE')
      AND (v."$part_event" <> 'PURCHASE' OR JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT')
      AND CAST(s2.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1, 2, 3, 4, 5
)

-- 11. 最终报表汇总
SELECT
    k.time_dimension AS "时间维度", 
    k.os_type AS "OS", 
    k.country AS "地区", 
    k.affcode AS "渠道", 
    k.store AS "商店", 
    k.date_range AS "日期范围",
    active_account AS "活跃账号", 
    paying_account AS "付费账号", 
    ROUND(total_revenue_usd, 2) AS "总流水(USD)",
    CAST(k.paying_account AS DOUBLE) / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "付费率",
    k.total_revenue_usd / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "ARPU",
    k.total_revenue_usd / NULLIF(CAST(k.paying_account AS DOUBLE), 0.0) AS "ARPPU",
    
    ltv.new_account AS "新增账号", 
    p5.new_paying_account AS "新增付费账号", 
    ROUND(p5.new_account_revenue_usd, 2) AS "新增当日流水(USD)",
    p5.new_account_revenue_usd / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增ARPU",
    p5.new_account_revenue_usd / NULLIF(CAST(p5.new_paying_account AS DOUBLE), 0.0) AS "新增ARPPU",
    CAST(p5.new_paying_account AS DOUBLE) / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增付费率",

    rr.rr_2 AS "次留", rr.rr_3 AS "D3留存", rr.rr_4 AS "D4留存", rr.rr_5 AS "D5留存", rr.rr_6 AS "D6留存", rr.rr_7 AS "D7留存", rr.rr_14 AS "D14留存", rr.rr_30 AS "D30留存", rr.rr_60 AS "D60留存", rr.rr_90 AS "D90留存", rr.rr_180 AS "D180留存", rr.rr_360 AS "D360留存",
    rr.week1_retention_rate AS "一阶登陆比率", rr.week2_return_rate AS "二阶登陆比率",
    ltv.ltv_1 AS "LTV_1", ltv.ltv_2 AS "LTV_2", ltv.ltv_3 AS "LTV_3", ltv.ltv_4 AS "LTV_4", ltv.ltv_5 AS "LTV_5", ltv.ltv_6 AS "LTV_6", ltv.ltv_7 AS "LTV_7", ltv.ltv_14 AS "LTV_14", ltv.ltv_30 AS "LTV_30", ltv.ltv_60 AS "LTV_60", ltv.ltv_90 AS "LTV_90", ltv.ltv_180 AS "LTV_180", ltv.ltv_360 AS "LTV_360"
FROM AccountKPI k
LEFT JOIN NewAccountLTV ltv 
    ON k.time_dimension = ltv.time_dimension AND k.os_type = ltv.os_type AND k.country = ltv.country AND k.affcode = ltv.affcode AND k.store = ltv.store 
LEFT JOIN NewAccountRR rr 
    ON k.time_dimension = rr.time_dimension AND k.os_type = rr.os_type AND k.country = rr.country AND k.affcode = rr.affcode AND k.store = rr.store  
LEFT JOIN NewAccountKPI p5 
    ON k.time_dimension = p5.time_dimension AND k.os_type = p5.os_type AND k.country = p5.country AND k.affcode = p5.affcode AND k.store = p5.store 
ORDER BY 1 DESC;
