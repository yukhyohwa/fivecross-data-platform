/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 按 role_id 单双数分组（娜美 vs 弗利札）的留存对比
Cohorts : 2026-04-15 至 2026-04-20 触发 role_create 的 iOS 用户
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 提取创角用户 (role_create) 并进行单双数分组
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT
        t.lcx_id,
        MIN(CAST("$part_date" AS DATE)) AS reg_date,
        -- 使用 MAX 取唯一的分组（如果同一个账号多次创角，只取第一个符合条件的）
        MAX(
            CASE 
                -- 提取 role_id 并转为 BIGINT，判断单双数
                WHEN CAST(json_extract_scalar(role_common, '$.role_id') AS BIGINT) % 2 = 1 THEN '娜美 (单数)'
                ELSE '弗利札 (双数)'
            END
        ) AS role_group
    FROM (
        SELECT 
            COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
            v."$part_date",
            v.role_common
        FROM ta.v_event_16 v
        WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-20'
          AND v."$part_event" = 'role_create'
          -- 保证 role_id 长度 > 2
          AND LENGTH(json_extract_scalar(v.role_common, '$.role_id')) > 2
    ) t
    -- 关联过滤 iOS 用户
    INNER JOIN user_result_cluster_16 u 
        ON t.lcx_id = u."#varchar_id"
        AND u.cluster_name = 'fixed_os' 
        AND u.tag_value = 'iOS'
    -- 排除黑名单
    LEFT JOIN UserBlacklist ub 
        ON t.lcx_id = ub.lcx_id
    WHERE ub.lcx_id IS NULL
    GROUP BY t.lcx_id
),

--------------------------------------------------------------------------------
-- 3. 提取这些用户的活跃日期
--------------------------------------------------------------------------------
UserActiveDays AS (
    SELECT 
        v."#account_id" AS lcx_id,
        ARRAY_AGG(DISTINCT CAST(v."$part_date" AS DATE)) AS active_dates
    FROM ta.v_event_16 v
    INNER JOIN NewUsers nu 
        ON nu.lcx_id = v."#account_id"
    WHERE v."$part_date" >= '2026-04-15'
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 4. 计算每个用户距离注册日的留存天数数组
--------------------------------------------------------------------------------
AccountRetention AS (
    SELECT 
        nu.lcx_id,
        nu.reg_date,
        nu.role_group,
        TRANSFORM(ARRAY_SORT(ua.active_dates), d -> DATE_DIFF('day', nu.reg_date, d)) AS return_days_array
    FROM NewUsers nu
    LEFT JOIN UserActiveDays ua ON nu.lcx_id = ua.lcx_id
)

--------------------------------------------------------------------------------
-- 5. 最终按日期和分组聚合计算留存率
--------------------------------------------------------------------------------
SELECT 
    CAST(reg_date AS VARCHAR) AS "创角日期",
    role_group AS "用户分组",
    COUNT(DISTINCT lcx_id) AS "创角人数(NUU)",
    
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "次留(%)",
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "3留(%)",
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "4留(%)",
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "5留(%)",
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "6留(%)",
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "7留(%)",
    ROUND(CAST(COUNT_IF(CONTAINS(return_days_array, 7)) AS DOUBLE) / NULLIF(COUNT(DISTINCT lcx_id), 0) * 100, 2) AS "8留(%)"
    
FROM AccountRetention
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
