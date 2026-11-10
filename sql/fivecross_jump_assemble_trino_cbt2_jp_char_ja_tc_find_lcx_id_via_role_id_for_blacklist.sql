/*
================================================================================
Game: Jump Assemble (众星之聚)
Description: 账号反查脚本 (Role ID -> LCX ID)
             - 场景：通过已知的游戏内角色 ID (role_id) 反查其平台 ID (lcx_id)
             - 用途：配合“添加黑名单”、“数据封禁”或“特定账号分析”
Environment: Trino (TA)
================================================================================
*/

WITH ScanConfig AS (
    -- 扫描范围：根据环境需要调整日期（默认为 OBT 至今）
    SELECT 
        '2026-04-15' AS target_start_date,
        '2026-04-23' AS target_end_date
),

RoleMapping AS (
    SELECT lcx_id, role_id
    FROM (
        SELECT 
            lcx_id, 
            role_id,
            ROW_NUMBER() OVER(PARTITION BY lcx_id ORDER BY last_time DESC) as rank
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
                MAX("#event_time") AS last_time
            FROM ta.v_event_16
            CROSS JOIN ScanConfig sc
            WHERE "$part_date" BETWEEN sc.target_start_date AND sc.target_end_date
            GROUP BY 1, 2
        ) s
        WHERE role_id IS NOT NULL AND lcx_id IS NOT NULL
    ) p
    WHERE p.rank = 1
)

SELECT 
    role_id AS "角色ID",
    lcx_id AS "平台ID (lcx_id)"
FROM RoleMapping
WHERE role_id IN (
    9251191, 9251801, 9251137, 9251189, 9251228, 
    12145, 9252246, 9251685, 9252290, 9251161, 
    9251151, 9251166, 9251163, 9251146, 9251181, 
    9251138, 9251158, 9251157, 9251133, 9251162, 
    9251171, 9251173, 9251159, 9251154, 9251160, 
    9251193, 9251180, 9251167, 9251153, 9251169, 
    9251156, 9251464, 9251184, 9251165, 9254452, 
    9252480, 9251637, 9251303, 9251470
);
