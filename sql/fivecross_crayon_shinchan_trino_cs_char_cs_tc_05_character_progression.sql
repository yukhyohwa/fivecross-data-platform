/*
================================================================================
蜡笔小新繁体 CBT - 玩家当前最高主线关卡分布
关卡 ID 使用 stage_fight.a_rst[1].id；关卡名称关联繁体维表。
================================================================================
*/
WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),
StageLogs AS (
    SELECT
        v."#account_id" AS account_id,
        TRY_CAST(v.a_rst[1].id AS BIGINT) AS stage_id
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."#event_name" = 'stage_fight'
      AND CAST(v.a_rst[1].key AS INTEGER) = 1001
      AND v."$part_date" BETWEEN '{{START_DATE}}' AND '{{END_DATE}}'
      AND ub.user_id IS NULL
      AND v."#account_id" IS NOT NULL
      AND v.a_rst[1].id IS NOT NULL
    GROUP BY 1, 2
),
UserMaxStage AS (
    SELECT account_id, MAX(stage_id) AS max_stage_id
    FROM StageLogs
    GROUP BY 1
),
StageDistribution AS (
    SELECT
        m.max_stage_id,
        COALESCE(d."stage_id@stage_name_show", CAST(m.max_stage_id AS VARCHAR)) AS stage_name,
        COUNT(DISTINCT m.account_id) AS users
    FROM UserMaxStage m
    LEFT JOIN ta_dim.dim_18_0_52765 d
      ON m.max_stage_id = d."stage_id@stage_id"
    GROUP BY 1, 2
)
SELECT
    '小新繁体CBT' AS "对比组",
    max_stage_id AS "最高关卡ID",
    stage_name AS "最高关卡名称",
    users AS "用户数",
    ROUND(users * 100.0 / NULLIF(SUM(users) OVER (), 0), 2) AS "占比(%)"
FROM StageDistribution
ORDER BY "最高关卡ID";
