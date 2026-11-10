WITH
-- 1. [性能优化] 自动计算扫描边界 (基于所选日期范围)
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 黑名单用户 (包含内部用户和水军)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 3. 用户标签数据表 (核心加速方案：Pivot 标签表)
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

-- 4. 目标新增用户集 (从标签表取 NUU 核心属性，并排除黑名单)
DeviceMetrics AS (
    SELECT 
        u."#account_id", 
        u.fixed_os AS ostype, 
        u.fixed_regdate AS "$part_date"
    FROM UserProfileDetail u
    LEFT JOIN UserBlacklist b ON u."#account_id" = b."#account_id"
    WHERE b."#account_id" IS NULL
      AND u.fixed_regdate IS NOT NULL
      AND CAST(u.fixed_regdate AS DATE) BETWEEN (SELECT target_start_date FROM ScanConfig) AND (SELECT target_end_date FROM ScanConfig)
),

-- 5. 回访行为聚合 (计算相对于注册日的天数偏移)
DeviceRetentionArrays AS (
    SELECT 
        s1."#account_id", 
        s2."$part_date" reg_date, 
        s2.ostype, 
        TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2."$part_date" AS DATE), d)) AS return_days_array
    FROM (
        SELECT "#account_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_16
        WHERE "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
          -- 扫描范围：从最早注册日算起，直到最新行为
          AND CAST("$part_date" AS DATE) >= (SELECT target_start_date FROM ScanConfig)
        GROUP BY 1
    ) s1
    INNER JOIN DeviceMetrics s2 ON s1."#account_id" = s2."#account_id"
)

-- 6. 最终指标统计
SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '0000-00-00'
    END AS time_dimension,
    ${Selector:ostype} os_type,
    COUNT(DISTINCT s1."#account_id") AS new_account,
    -- 留存/回访率计算逻辑
    CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_1,
    CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2), 0) week1_retention_rate,
    CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3), 0) week2_return_rate
FROM DeviceMetrics s1
LEFT JOIN DeviceRetentionArrays s2 ON s1."#account_id" = s2."#account_id"
GROUP BY 1, 2
