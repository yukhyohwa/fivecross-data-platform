/*
================================================================================
项目：蜡笔小新 - TC 繁体 CBT 首日 vs OBT 新手引导漏斗（仅 Android）

对比组：
1. 繁体 CBT 首日：2026-07-29，账号按 #user_id 去重。
2. 繁体 OBT：通过 ${PartDate:date} 选择创角日期范围，账号按 fc_id 去重。

口径：
1. 两组均仅保留 new_role.os = Android 的创角账号。
2. gamer_guide 客户端日志可能没有 fc_id，通过 #distinct_id 映射到对应账号。
3. CBT 使用旧黑名单 internal_users、is_windows、is_water；OBT 使用新黑名单
   internal_users_new、is_windows_new、is_water_new。
4. 分子和分母均按账号去重，同一账号重复创角或重复上报不重复计数。
5. CBT 仅统计开服首日；OBT 统计所选日期范围内首次完成 OBT 创角的账号。
6. 引导日志按每个账号的创角日统计，保证不因 OBT 选择多日而串入其他日期日志。
URL:https://ss-web.5xgames.com/#/tga/ide/18_4740?fromPanel=18_915
================================================================================
*/

WITH
Config AS (
    SELECT
        DATE '2026-07-29' AS cbt_date,
        DATE '2026-10-14' AS obt_start_date
),

-- Generate selected date bounds in memory, without scanning event logs.
OBTDateBounds AS (
    SELECT MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
           MAX(CAST(v."$part_date" AS DATE)) AS target_end_date
    FROM Config c
    CROSS JOIN UNNEST(
        TRANSFORM(SEQUENCE(c.obt_start_date, CURRENT_DATE, INTERVAL '1' DAY),
                  d -> CAST(d AS VARCHAR))
    ) AS v("$part_date")
    WHERE v.${PartDate:date}
),

CBTBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#user_id" AS VARCHAR)) AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
      AND NULLIF(TRIM(CAST("#user_id" AS VARCHAR)), '') IS NOT NULL
),

OBTBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_windows_new', 'is_water_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- CBT 首日 Android 创角账号
--------------------------------------------------------------------------------
CBTCohortRanked AS (
    SELECT
        TRIM(CAST(v."#user_id" AS VARCHAR)) AS entity_id,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v."#user_id" AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" = CAST(c.cbt_date AS VARCHAR)
      AND UPPER(TRIM(CAST(v.os AS VARCHAR))) = 'ANDROID'
      AND NULLIF(TRIM(CAST(v."#user_id" AS VARCHAR)), '') IS NOT NULL
),

CBTCohort AS (
    SELECT r.entity_id, r.reg_event_time
    FROM CBTCohortRanked r
    LEFT JOIN CBTBlacklist b ON r.entity_id = b.user_id
    WHERE r.rn = 1
      AND b.user_id IS NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定首次创角，再筛选目标日期范围内的 Android 账号
--------------------------------------------------------------------------------
OBTCohortRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS entity_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        COALESCE(NULLIF(UPPER(TRIM(CAST(v.os AS VARCHAR))), ''), 'UNKNOWN') AS event_os,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    CROSS JOIN OBTDateBounds r
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.target_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

OBTCohort AS (
    SELECT r.entity_id, r.reg_date, r.reg_event_time
    FROM OBTCohortRanked r
    CROSS JOIN OBTDateBounds rr
    LEFT JOIN OBTBlacklist b ON r.entity_id = b.fc_id
    WHERE r.rn = 1
      AND r.reg_date BETWEEN rr.target_start_date AND rr.target_end_date
      AND r.event_os = 'ANDROID'
      AND b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- CBT session_id → #user_id；login/new_role 仅用于减少扫描量
--------------------------------------------------------------------------------
CBTSessionAccountMap AS (
    SELECT
        TRIM(CAST(v."#distinct_id" AS VARCHAR)) AS session_id,
        MAX_BY(
            TRIM(CAST(v."#user_id" AS VARCHAR)),
            ROW(CAST(v."#event_time" AS TIMESTAMP), CAST(v."#user_id" AS VARCHAR))
        ) AS entity_id
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v."$part_date" = CAST(c.cbt_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v."#user_id" AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- OBT session_id → fc_id；login/new_role 仅用于减少扫描量
--------------------------------------------------------------------------------
OBTSessionAccountMap AS (
    SELECT
        TRIM(CAST(v."#distinct_id" AS VARCHAR)) AS session_id,
        MAX_BY(
            TRIM(CAST(v.fc_id AS VARCHAR)),
            ROW(CAST(v."#event_time" AS TIMESTAMP), CAST(v.fc_id AS VARCHAR))
        ) AS entity_id
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date}
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 两期首日创角与引导日志
--------------------------------------------------------------------------------
RoleGuideLogs AS (
    SELECT
        '1.繁体_CBT首日_Android' AS cohort_name,
        v.gamer_guide_id,
        v.gamer_skip,
        v."$part_event",
        c.entity_id
    FROM ta.v_event_18 v
    INNER JOIN CBTCohort c
        ON TRIM(CAST(v."#user_id" AS VARCHAR)) = c.entity_id
    CROSS JOIN Config cfg
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" = CAST(cfg.cbt_date AS VARCHAR)

    UNION ALL

    SELECT
        '1.繁体_CBT首日_Android' AS cohort_name,
        v.gamer_guide_id,
        v.gamer_skip,
        v."$part_event",
        c.entity_id
    FROM ta.v_event_18 v
    INNER JOIN CBTSessionAccountMap sm
        ON TRIM(CAST(v."#distinct_id" AS VARCHAR)) = sm.session_id
    INNER JOIN CBTCohort c
        ON sm.entity_id = c.entity_id
    CROSS JOIN Config cfg
    WHERE v."$part_event" = 'gamer_guide'
      AND v."$part_date" = CAST(cfg.cbt_date AS VARCHAR)

    UNION ALL

    SELECT
        '2.繁体_OBT_Android' AS cohort_name,
        v.gamer_guide_id,
        v.gamer_skip,
        v."$part_event",
        c.entity_id
    FROM ta.v_event_18 v
    INNER JOIN OBTCohort c
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = c.entity_id
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'new_role'
      AND CAST(v."#event_time" AS TIMESTAMP) = c.reg_event_time

    UNION ALL

    SELECT
        '2.繁体_OBT_Android' AS cohort_name,
        v.gamer_guide_id,
        v.gamer_skip,
        v."$part_event",
        c.entity_id
    FROM ta.v_event_18 v
    INNER JOIN OBTSessionAccountMap sm
        ON TRIM(CAST(v."#distinct_id" AS VARCHAR)) = sm.session_id
    INNER JOIN OBTCohort c
        ON sm.entity_id = c.entity_id
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'gamer_guide'
      AND v."$part_date" = CAST(c.reg_date AS VARCHAR)
),

--------------------------------------------------------------------------------
-- 先把原始 gamer_guide_id + gamer_skip 映射为最终逻辑步骤。
-- 维表本身先去重，避免同一映射重复放大结果。
--------------------------------------------------------------------------------
GuideDim AS (
    SELECT
        TRY_CAST("gamer_guide_id@gamer_guide_id" AS INTEGER) AS gamer_guide_id,
        TRY_CAST("gamer_guide_id@gamer_skip" AS INTEGER) AS gamer_skip,
        MAX(TRY_CAST("gamer_guide_id@extra_id" AS INTEGER)) AS step_id,
        MAX("gamer_guide_id@guide_name") AS step_name
    FROM ta_dim.dim_18_0_52779
    GROUP BY 1, 2
),

MappedGuideLogs AS (
    SELECT
        r.cohort_name,
        r."$part_event",
        r.entity_id,
        TRY_CAST(r.gamer_guide_id AS INTEGER) AS gamer_guide_id,
        TRY_CAST(r.gamer_skip AS INTEGER) AS gamer_skip,
        d.step_id,
        CASE
            WHEN r."$part_event" = 'new_role' THEN '1.注册/创建角色'
            ELSE COALESCE(
                d.step_name,
                '步骤ID_' || CAST(TRY_CAST(r.gamer_guide_id AS INTEGER) AS VARCHAR)
                || '_' || CAST(TRY_CAST(r.gamer_skip AS INTEGER) AS VARCHAR)
            )
        END AS step_name
    FROM RoleGuideLogs r
    LEFT JOIN GuideDim d
        ON TRY_CAST(r.gamer_guide_id AS INTEGER) = d.gamer_guide_id
       AND TRY_CAST(r.gamer_skip AS INTEGER) = d.gamer_skip
),

FilteredGuideLogs AS (
    SELECT *
    FROM MappedGuideLogs
    WHERE "$part_event" = 'new_role'
       OR (
            step_name NOT IN ('步骤ID_2_0', '步骤ID_0_0', '3.关闭界面')
        AND gamer_guide_id NOT IN (2049, 2050)
        -- AND (step_id <> 17 OR step_id IS NULL)
        -- AND (step_id <= 46 OR step_id IS NULL)
       )
),

--------------------------------------------------------------------------------
-- 按最终逻辑步骤重新对账号去重，避免多个原始事件映射到同一步骤后比例相加。
--------------------------------------------------------------------------------
FunnelSteps AS (
    SELECT
        cohort_name,
        step_id,
        step_name,
        COUNT(DISTINCT entity_id) AS funnel_counts,
        ARRAY_JOIN(
            ARRAY_SORT(ARRAY_DISTINCT(
                ARRAY_AGG(CAST(gamer_guide_id AS VARCHAR))
                    FILTER (WHERE gamer_guide_id IS NOT NULL)
            )),
            ','
        ) AS gamer_guide_id,
        ARRAY_JOIN(
            ARRAY_SORT(ARRAY_DISTINCT(
                ARRAY_AGG(CAST(gamer_skip AS VARCHAR))
                    FILTER (WHERE gamer_skip IS NOT NULL)
            )),
            ','
        ) AS gamer_skip
    FROM FilteredGuideLogs
    GROUP BY 1, 2, 3
),

CohortCounts AS (
    SELECT
        cohort_name,
        COUNT(DISTINCT entity_id) AS new_role_count
    FROM RoleGuideLogs
    WHERE "$part_event" = 'new_role'
    GROUP BY 1
),

FunnelResults AS (
    SELECT
        p1.cohort_name,
        p1.step_id,
        p1.step_name,
        p1.funnel_counts,
        p2.new_role_count,
        p1.funnel_counts * 1.0
            / NULLIF(CAST(p2.new_role_count AS DOUBLE), 0) AS pass_rate,
        p1.gamer_guide_id,
        p1.gamer_skip
    FROM FunnelSteps p1
    LEFT JOIN CohortCounts p2
        ON p1.cohort_name = p2.cohort_name
),

StepSort AS (
    SELECT
        step_id,
        step_name,
        MAX(CASE WHEN cohort_name = '2.繁体_OBT_Android' THEN pass_rate END) AS obt_pass_rate
    FROM FunnelResults
    GROUP BY 1, 2
)

SELECT
    r.cohort_name AS "对比组",
    r.step_id AS "步骤ID",
    r.step_name AS "引导步骤",
    r.funnel_counts AS "通过人数",
    r.new_role_count AS "创角总人数",
    r.pass_rate AS "通过率",
    s.obt_pass_rate AS "OBT排序值",
    r.gamer_guide_id,
    r.gamer_skip
FROM FunnelResults r
LEFT JOIN StepSort s
    ON r.step_id IS NOT DISTINCT FROM s.step_id
   AND r.step_name = s.step_name
WHERE s.obt_pass_rate >= 0.01
ORDER BY
    s.obt_pass_rate DESC NULLS LAST,
    COALESCE(r.step_id, 0),
    r.step_name,
    r.cohort_name;
