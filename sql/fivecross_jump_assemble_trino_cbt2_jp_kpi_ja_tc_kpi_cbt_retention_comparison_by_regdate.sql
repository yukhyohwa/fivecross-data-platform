/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 11.25-11.30 新老用户留存对比 (根据注册日期分组)
              - 新用户: 11.25-11.30 期间注册的用户
              - 老用户: 11.25 之前注册的用户
              - 计算逻辑:
                1. 新用户以其注册日为起点计算分日留存。
                2. 老用户在测试期间(11.25-11.30)每一天的活跃都作为留存起点。
                3. 加权留存展示期间整体表现。
Reference: ja_tc_user_kpi_stats.sql
Environment: Trino (TA)
================================================================================
*/

WITH
ScanConfig AS (
    SELECT 
        DATE '2025-11-25' AS test_start_date,
        DATE '2025-11-30' AS cohort_end_date,
        DATE '2025-12-02' AS scan_end_date
),

-- 1. 用户标签 & 分组定义 (使用 cluster_16)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16
    WHERE cluster_name = 'fixed_regdate'
    GROUP BY 1
),

UserGroups AS (
    SELECT 
        p."#account_id",
        p.fixed_regdate,
        CASE 
            WHEN CAST(p.fixed_regdate AS DATE) BETWEEN (SELECT test_start_date FROM ScanConfig) AND (SELECT cohort_end_date FROM ScanConfig) THEN 'New'
            WHEN CAST(p.fixed_regdate AS DATE) < (SELECT test_start_date FROM ScanConfig) THEN 'Old'
            ELSE 'Other'
        END AS user_group
    FROM UserProfileDetail p
),

-- 2. 确定分析起点 (Start Dates)
-- 逻辑：
-- 新用户：以 fixed_regdate 为准 (要求 fixed_regdate 在测试期间，且期间有活跃)
-- 老用户：以测试期间(11.25-11.30)的【首次活跃日期】作为伪注册时间 (Pseudo-regdate)
ActivationStarts AS (
    SELECT 
        "#account_id",
        MIN(start_date) AS start_date, -- 核心：取测试期间的首次登录日
        MAX(user_group) AS user_group,
        MAX(fixed_regdate) AS fixed_regdate
    FROM (
        SELECT 
            v."#account_id",
            CAST(v."$part_date" AS DATE) AS start_date,
            CASE 
                WHEN g.fixed_regdate IS NULL THEN 'Old'
                WHEN CAST(g.fixed_regdate AS DATE) BETWEEN (SELECT test_start_date FROM ScanConfig) AND (SELECT cohort_end_date FROM ScanConfig) THEN 'New'
                WHEN CAST(g.fixed_regdate AS DATE) < (SELECT test_start_date FROM ScanConfig) THEN 'Old'
                ELSE 'Other'
            END AS user_group,
            g.fixed_regdate
        FROM ta.v_event_16 v
        LEFT JOIN UserGroups g ON v."#account_id" = g."#account_id"
        WHERE v."$part_date" BETWEEN '2025-11-25' AND '2025-11-30'
          AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
    ) t
    WHERE user_group IN ('New', 'Old')
    GROUP BY 1
    HAVING 
        -- 新用户校验：首日活跃必须是注册当天 (确保是真正的拉新)
        (MAX(user_group) = 'New' AND MIN(start_date) = CAST(MAX(fixed_regdate) AS DATE))
        OR 
        -- 老用户：取测试期间任意首日作为起点
        (MAX(user_group) = 'Old')
),

-- 3. 全量活跃序列
DailyActivity AS (
    SELECT 
        "#account_id",
        ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS activity_dates
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2025-11-25' AND '2025-12-02'
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
    GROUP BY 1
),

-- 4. 计算相对留存天数
RetentionBase AS (
    SELECT
        s.user_group,
        s.start_date,
        s."#account_id",
        TRANSFORM(a.activity_dates, d -> DATE_DIFF('day', s.start_date, d)) AS relative_days
    FROM ActivationStarts s
    INNER JOIN DailyActivity a ON s."#account_id" = a."#account_id"
),

-- 5. 聚合指标 (分日 + 加权)
AggregatedMetrics AS (
    -- 分日留存
    SELECT
        user_group,
        CAST(start_date AS VARCHAR) AS date_label,
        start_date AS sort_date,
        COUNT(*) AS user_count,
        CAST(COUNT_IF(CONTAINS(relative_days, 1)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(relative_days, 2)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(relative_days, 3)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(relative_days, 4)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(relative_days, 5)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(relative_days, 6)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(relative_days, 7)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_7
    FROM RetentionBase
    GROUP BY 1, 2, 3

    UNION ALL

    -- 加权平均留存
    SELECT
        user_group,
        '11.25-11.30 加权' AS date_label,
        DATE '9999-12-31' AS sort_date,
        COUNT(*) AS user_count,
        CAST(COUNT_IF(CONTAINS(relative_days, 1)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(relative_days, 2)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(relative_days, 3)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(relative_days, 4)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(relative_days, 5)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(relative_days, 6)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(relative_days, 7)) AS DOUBLE) / NULLIF(COUNT(*), 0) AS rr_7
    FROM RetentionBase
    GROUP BY 1
)

-- 6. 最终输出
SELECT 
    user_group AS "用户类型",
    date_label AS "日期/周期",
    user_count AS "基数(Active)",
    CAST(ROUND(rr_1 * 100, 2) AS VARCHAR) || '%' AS "次留",
    CAST(ROUND(rr_2 * 100, 2) AS VARCHAR) || '%' AS "D2留存",
    CAST(ROUND(rr_3 * 100, 2) AS VARCHAR) || '%' AS "D3留存",
    CAST(ROUND(rr_4 * 100, 2) AS VARCHAR) || '%' AS "D4留存",
    CAST(ROUND(rr_5 * 100, 2) AS VARCHAR) || '%' AS "D5留存",
    CAST(ROUND(rr_6 * 100, 2) AS VARCHAR) || '%' AS "D6留存",
    CAST(ROUND(rr_7 * 100, 2) AS VARCHAR) || '%' AS "D7留存"
FROM AggregatedMetrics
ORDER BY user_group, sort_date;
