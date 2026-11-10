/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese - TW/HK/MO)
Description: 账号匹配脚本 (LCX ID -> Role ID)
             1. 关联 UserProfileDetail (来自 user_result_cluster_16) 确定的账号 ID。
             2. 通过多种可能的 ID 字段深度匹配对应之 role_id。
             3. 针对指定时间范围内的 iOS 账号记录。
Environment: Trino (TA)
================================================================================
*/

WITH

-- 1. [性能优化] 自动计算扫描边界 (基于 PartDate:date1 模板参数)
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
),

-- 2. 用户标签数据 (确定基础账号范围)
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

-- 3. 关联映射逻辑：通过扫描日志匹配 lcx_id 与 role_id
lcxidtoroleid AS (
    SELECT lcx_id, role_id
    FROM (
        SELECT 
            lcx_id, 
            role_id,
            RANK() OVER(PARTITION BY lcx_id ORDER BY "#event_time" DESC) as rank
        FROM (
            SELECT 
                -- 兼容多种历史 ID 命名方式
                CASE
                    WHEN LENGTH(CAST(lcx_id AS VARCHAR)) = 36 THEN CAST(lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST(lcxuserid AS VARCHAR)) = 36 THEN CAST(lcxuserid AS VARCHAR)
                    WHEN LENGTH(CAST(lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(lcxsdkcommon.lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST(sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(sdkcommon.lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST("#account_id" AS VARCHAR)) = 36 THEN CAST("#account_id" AS VARCHAR)
                END as lcx_id,
                -- 提取真实的 role_id 编号
                CASE 
                    WHEN rolecommon.role_id IS NOT NULL THEN CAST(rolecommon.role_id AS INTEGER)
                    WHEN LENGTH(CAST("#account_id" AS VARCHAR)) <> 36 THEN CAST("#account_id" AS INTEGER)
                    WHEN LENGTH(CAST(role_id AS VARCHAR)) > 3 THEN CAST(role_id AS INTEGER)
                    ELSE CAST(TRY(JSON_EXTRACT_SCALAR(CAST(role_common AS JSON), '$.role_id')) AS INTEGER)
                END as role_id,
                MIN("#event_time") AS "#event_time"
            FROM ta.v_event_16
            CROSS JOIN ScanConfig sc
            -- 扫描范围采用 ScanConfig 确定的动态日期，以保证环境一致性
            WHERE "$part_date" BETWEEN CAST(sc.target_start_date AS VARCHAR) AND CAST(sc.target_end_date AS VARCHAR)
            GROUP BY 1, 2
        ) s
        WHERE role_id IS NOT NULL AND lcx_id IS NOT NULL
    ) p
    WHERE p.rank = 1
)

-- 4. 最终结果：根据标签日期筛选对应的用户及其对应的角色 ID
SELECT 
    u."#account_id" AS lcx_id,
    u.fixed_regdate,
    lr.role_id
FROM UserProfileDetail u
CROSS JOIN ScanConfig sc
LEFT JOIN lcxidtoroleid lr ON u."#account_id" = lr.lcx_id
WHERE CAST(u.fixed_regdate AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
  AND u.fixed_os = 'iOS'
ORDER BY u.fixed_regdate DESC;
