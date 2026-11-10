/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 新手引导漏斗（App 18 维表补全版）

修正：
1. 繁体 iOS 引导日志已迁回 App 18；全部平台只读取 ta.v_event_18，不再补读 App 13。
2. 引导名称统一使用繁体维表 ta_dim.dim_18_0_52779。
3. 维表按 gamer_guide_id + gamer_skip 去重，避免重复映射放大人数。
4. 未映射步骤保留，并以“步骤ID_原始ID_skip”展示，不因维表字段为 NULL 被过滤。
5. 注册/创建角色作为漏斗起点显式保留，值固定为 100%。

口径：
1. OBT 从 2026-10-14 开始；目标 cohort 为所选日期首次完成 OBT new_role 的 fc_id。
2. gamer_guide 优先使用事件自身 fc_id；缺少时依次使用 #distinct_id、
   #user_id，通过 login/new_role 映射至 fc_id。
3. 漏斗分子、分母均按 fc_id 去重；同账号多角色、多个安装 session 合并。
4. 排除 internal_users_new、is_water_new、is_windows_new。
5. OS 取账号首次 new_role 的 os；创角前 24 小时内同 session 的引导事件计入漏斗。
6. 不限制原始步骤 ID 或维表步骤顺序；所有能回连到 cohort 的引导步骤均输出。
7. 创角选择、身份映射和引导日志直接使用 v.${PartDate:date}，不生成日历或推算日期边界。
8. 不自动扩展前一天；创角前24小时规则只适用于所选日期内日志。首次 OBT 创角核验保留历史查询。
URL:https://ss-web.5xgames.com/#/tga/ide/18_5205?fromPanel=18_915
================================================================================
*/

WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN (
        'internal_users_new',
        'is_water_new',
        'is_windows_new'
    )
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

-- 日期参数只选择创角记录，不从事件或日历推算参数边界。
SelectedRegistrations AS (
    SELECT DISTINCT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'new_role'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

-- 仅对选中账号核验首次 OBT 创角，避免老账号在所选日期开新角色被当成新增。
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        COALESCE(NULLIF(TRIM(CAST(v.os AS VARCHAR)), ''), '未知') AS event_os,
        NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '') AS reg_session_id,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    INNER JOIN (SELECT DISTINCT fc_id FROM SelectedRegistrations) s
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = s.fc_id
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= '2026-10-14'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

CohortUsers AS (
    SELECT
        a.fc_id,
        a.reg_date,
        a.reg_event_time,
        a.event_os,
        a.reg_session_id
    FROM AccountRegistrationRanked a
    INNER JOIN SelectedRegistrations s
      ON a.fc_id = s.fc_id AND a.reg_event_time = s.reg_event_time
    LEFT JOIN UserBlacklist b
      ON a.fc_id = b.fc_id
    WHERE a.rn = 1
      AND b.fc_id IS NULL
),

-- 通过 login/new_role 建立 session_id（#distinct_id）到 fc_id 的唯一映射。
SessionAccountMap AS (
    SELECT TRIM(CAST(v."#distinct_id" AS VARCHAR)) AS session_id,
           MAX_BY(TRIM(CAST(v.fc_id AS VARCHAR)),
                  ROW(CAST(v."#event_time" AS TIMESTAMP), CAST(v.fc_id AS VARCHAR))) AS fc_id
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date}
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

-- iOS 部分日志的 #distinct_id 也不稳定；#user_id 仅作为最后一级身份回退。
UserAccountMap AS (
    SELECT TRIM(CAST(v."#user_id" AS VARCHAR)) AS event_user_id,
           MAX_BY(TRIM(CAST(v.fc_id AS VARCHAR)),
                  ROW(CAST(v."#event_time" AS TIMESTAMP), CAST(v.fc_id AS VARCHAR))) AS fc_id
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date}
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#user_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

-- 引导数据已迁回繁体项目；iOS、Android 均只读取 App 18。
RawGuideLogs AS (
    SELECT
        TRY_CAST(v.gamer_guide_id AS INTEGER) AS gamer_guide_id,
        COALESCE(TRY_CAST(v.gamer_skip AS INTEGER), 0) AS gamer_skip,
        NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') AS direct_fc_id,
        TRIM(CAST(v."#distinct_id" AS VARCHAR)) AS session_id,
        TRIM(CAST(v."#user_id" AS VARCHAR)) AS event_user_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time
    FROM ta.v_event_18 v
    WHERE v."$part_event" = 'gamer_guide'
      AND v.${PartDate:date}
      AND v.gamer_guide_id IS NOT NULL
),

-- 注册起点来自 cohort；引导事件按 fc_id、session、event user 顺序识别账号。
RoleGuideLogs AS (
    SELECT
        CAST(NULL AS INTEGER) AS gamer_guide_id,
        CAST(0 AS INTEGER) AS gamer_skip,
        'new_role' AS event_name,
        c.fc_id,
        c.event_os
    FROM CohortUsers c

    UNION ALL

    SELECT
        g.gamer_guide_id,
        g.gamer_skip,
        'gamer_guide' AS event_name,
        c.fc_id,
        c.event_os
    FROM RawGuideLogs g
    LEFT JOIN SessionAccountMap sm
      ON g.session_id = sm.session_id
    LEFT JOIN UserAccountMap um
      ON g.event_user_id = um.event_user_id
    LEFT JOIN (
        SELECT reg_session_id, MAX(fc_id) AS fc_id
        FROM CohortUsers
        WHERE reg_session_id IS NOT NULL
        GROUP BY 1
        HAVING COUNT(DISTINCT fc_id) = 1
    ) rs ON g.session_id = rs.reg_session_id
    INNER JOIN CohortUsers c
      ON COALESCE(
          g.direct_fc_id,
          sm.fc_id,
          um.fc_id,
          rs.fc_id
      ) = c.fc_id
    WHERE (
          g.event_time >= c.reg_event_time
          OR (
              g.event_time >= DATE_ADD('day', -1, c.reg_event_time)
              AND g.session_id = c.reg_session_id
          )
      )
),

-- App 18 繁体正式维表；先去重再关联。
GuideDim AS (
    SELECT
        TRY_CAST("gamer_guide_id@gamer_guide_id" AS INTEGER) AS gamer_guide_id,
        COALESCE(
            TRY_CAST("gamer_guide_id@gamer_skip" AS INTEGER),
            0
        ) AS gamer_skip,
        MAX(TRY_CAST("gamer_guide_id@extra_id" AS INTEGER)) AS step_order,
        MAX("gamer_guide_id@guide_name") AS guide_name
    FROM ta_dim.dim_18_0_52779
    GROUP BY 1, 2
),

MappedGuideLogs AS (
    SELECT
        l.event_os,
        l.fc_id,
        l.event_name,
        l.gamer_guide_id,
        l.gamer_skip,
        CASE
            WHEN l.event_name = 'new_role' THEN 0
            ELSE d.step_order
        END AS step_order,
        CASE
            WHEN l.event_name = 'new_role' THEN '1.注册/创建角色'
            ELSE COALESCE(
                d.guide_name,
                '步骤ID_' || CAST(l.gamer_guide_id AS VARCHAR)
                || '_' || CAST(l.gamer_skip AS VARCHAR)
            )
        END AS guide_name
    FROM RoleGuideLogs l
    LEFT JOIN GuideDim d
      ON l.gamer_guide_id = d.gamer_guide_id
     AND l.gamer_skip = d.gamer_skip
),

FunnelSteps AS (
    SELECT
        event_os,
        event_name,
        gamer_guide_id,
        gamer_skip,
        step_order,
        guide_name,
        COUNT(DISTINCT fc_id) AS funnel_counts
    FROM MappedGuideLogs
    GROUP BY 1, 2, 3, 4, 5, 6
),

CohortCounts AS (
    SELECT
        event_os,
        COUNT(DISTINCT fc_id) AS new_role_count
    FROM CohortUsers
    GROUP BY 1
)

-- 保持与原看板相同的四列输出。
SELECT
    f.event_os,
    CASE
        WHEN f.event_name = 'new_role' THEN 0
        ELSE COALESCE(f.step_order, f.gamer_guide_id)
    END AS guide_id,
    f.guide_name AS "引导步骤",
    CASE
        WHEN f.event_name = 'new_role' THEN 1.0
        ELSE f.funnel_counts * 1.0
            / NULLIF(CAST(c.new_role_count AS DOUBLE), 0)
    END AS "值"
FROM FunnelSteps f
INNER JOIN CohortCounts c
  ON f.event_os = c.event_os
ORDER BY
    CASE f.event_os
        WHEN 'iOS' THEN 1
        WHEN 'Android' THEN 2
        ELSE 3
    END,
    "值" DESC,
    guide_id,
    f.gamer_skip;
