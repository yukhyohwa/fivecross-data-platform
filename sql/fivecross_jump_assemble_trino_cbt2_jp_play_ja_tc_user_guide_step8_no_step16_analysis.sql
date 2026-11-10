/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese - TW/HK/MO)
Description: 引导流失用户分析 (卡在步骤 8 以后，未完成步骤 16)
             1. 目标人群：符合之前定义的 iOS 注册账号。
             2. 判定标准：触发过 guide_id = 8 (点击开始引导战斗)，
                         但从未触发过 guide_id = 16 (引导流程完成)。
Environment: Trino (TA)
================================================================================
*/

WITH

-- 1. [性能优化] 自动计算扫描边界 (基于 PartDate:date1)
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
),

-- 2. 用户标签数据 (确定 iOS 账号范围)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os' THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 3. 关联映射逻辑：获取账号对应的角色 ID
lcxidtoroleid AS (
    SELECT lcx_id, role_id
    FROM (
        SELECT 
            lcx_id, 
            role_id,
            RANK() OVER(PARTITION BY lcx_id ORDER BY "#event_time" DESC) as rank
        FROM (
            SELECT 
                CASE
                    WHEN LENGTH(CAST(lcx_id AS VARCHAR)) = 36 THEN CAST(lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST(lcxuserid AS VARCHAR)) = 36 THEN CAST(lcxuserid AS VARCHAR)
                    WHEN LENGTH(CAST(lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(lcxsdkcommon.lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST(sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(sdkcommon.lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST("#account_id" AS VARCHAR)) = 36 THEN CAST("#account_id" AS VARCHAR)
                END as lcx_id,
                CASE 
                    WHEN rolecommon.role_id IS NOT NULL THEN CAST(rolecommon.role_id AS VARCHAR)
                    WHEN LENGTH(CAST("#account_id" AS VARCHAR)) <> 36 THEN CAST("#account_id" AS VARCHAR)
                    WHEN LENGTH(CAST(role_id AS VARCHAR)) > 3 THEN CAST(role_id AS VARCHAR)
                    ELSE TRY(json_extract_scalar(role_common, '$.role_id'))
                END as role_id,
                "#event_time"
            FROM ta.v_event_16
            CROSS JOIN ScanConfig sc
            WHERE "$part_date" BETWEEN CAST(sc.target_start_date AS VARCHAR) AND CAST(sc.target_end_date AS VARCHAR)
        ) s
        WHERE role_id IS NOT NULL AND lcx_id IS NOT NULL
    ) p
    WHERE p.rank = 1
),

-- 4. 基础用户集 (iOS 注册)
Populations AS (
    SELECT 
        u."#account_id" AS lcx_id,
        lr.role_id
    FROM UserProfileDetail u
    CROSS JOIN ScanConfig sc
    LEFT JOIN lcxidtoroleid lr ON u."#account_id" = lr.lcx_id
    WHERE CAST(u.fixed_regdate AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
      AND u.fixed_os = 'iOS'
),

-- 5. 扫描引导步骤触发情况
GuideProgress AS (
    SELECT 
        lcx_id,
        MAX(CASE WHEN guide_id = 8 THEN 1 ELSE 0 END) AS has_step_8,
        MAX(CASE WHEN guide_id = 16 THEN 1 ELSE 0 END) AS has_step_16
    FROM (
        SELECT 
            CASE
                WHEN LENGTH(CAST(lcx_id AS VARCHAR)) = 36 THEN CAST(lcx_id AS VARCHAR)
                WHEN LENGTH(CAST(lcxuserid AS VARCHAR)) = 36 THEN CAST(lcxuserid AS VARCHAR)
                WHEN LENGTH(CAST(lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(lcxsdkcommon.lcx_id AS VARCHAR)
                WHEN LENGTH(CAST(sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(sdkcommon.lcx_id AS VARCHAR)
                WHEN LENGTH(CAST("#account_id" AS VARCHAR)) = 36 THEN CAST("#account_id" AS VARCHAR)
                WHEN LENGTH(CAST(json_extract_scalar(fc_sdk_common, '$.lcx_id') AS VARCHAR)) = 36 THEN json_extract_scalar(fc_sdk_common, '$.lcx_id')
            END as lcx_id,
            guide_id
        FROM ta.v_event_16
        CROSS JOIN ScanConfig sc
        WHERE "$part_date" >= CAST(sc.target_start_date AS VARCHAR) -- 从注册当期开始扫
          AND "$part_event" IN ('role_guide_before','role_guide','force_guide')
    ) s
    GROUP BY 1
) ,

DimDevices AS (
    SELECT lcx_id, "#device_id"
    FROM (
        SELECT 
            lcx_id, 
            "#device_id",
            RANK() OVER(PARTITION BY lcx_id ORDER BY "#event_time" DESC) as rank
        FROM (
            SELECT 
                CASE
                    WHEN LENGTH(CAST(lcx_id AS VARCHAR)) = 36 THEN CAST(lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST(lcxuserid AS VARCHAR)) = 36 THEN CAST(lcxuserid AS VARCHAR)
                    WHEN LENGTH(CAST(lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(lcxsdkcommon.lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST(sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(sdkcommon.lcx_id AS VARCHAR)
                    WHEN LENGTH(CAST("#account_id" AS VARCHAR)) = 36 THEN CAST("#account_id" AS VARCHAR)
                END as lcx_id,"#device_id","#event_time"
            FROM ta.v_event_16
            CROSS JOIN ScanConfig sc
            WHERE "$part_date" BETWEEN '2025-11-24' AND '2026-04-16'
        ) s
        WHERE lcx_id IS NOT NULL AND "#device_id" IS NOT NULL
    ) p
    WHERE p.rank = 1
)
-- 6. 最终提取：完成过 8 且没有完成过 16 的用户
SELECT 
    p.lcx_id,
    p.role_id,
    d."#device_id"
FROM Populations p
JOIN GuideProgress g ON p.lcx_id = g.lcx_id
LEFT JOIN DimDevices d ON p.lcx_id = d.lcx_id
WHERE g.has_step_8 = 1 
  AND g.has_step_16 = 0;

