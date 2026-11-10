/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 新手引导漏斗
描述：统计目标创角 cohort 的引导步骤完成率。

口径：
1. OBT 从 2026-10-14 开始；目标 cohort 为所选日期首次完成 OBT new_role 的 fc_id。
2. gamer_guide 等客户端事件缺少 fc_id 时，使用 #distinct_id 作为 session_id，
   通过 login/new_role 建立 session_id → fc_id 映射。
3. 漏斗分子和新增分母均按 fc_id 去重；同账号多角色、多个安装 session 合并。
4. 黑名单使用 #varchar_id，排除 internal_users_new、is_water_new、is_windows_new。
5. 本报表只有一个目标 cohort，不输出固定的“事件时间”维度，也不计算引导步骤对应关卡。
6. OS 直接取账号首次 new_role 记录的 os 字段；输出列名仍保留 event_os。
7. gamer_guide 可能早于 new_role；同 session 下创角前 24 小时内的引导事件计入该账号漏斗。
8. 日期参数使用 v.${PartDate:date}；日期边界从内存日历生成，不扫描事件求 MIN/MAX。
9. 映射及引导日志仅观察所选起日前一天至所选结束日；创角起点只计首次创角记录。
10. 引导维表按步骤 ID、skip 去重；漏斗分母直接取首次创角 cohort。
URL:https://ss-web.5xgames.com/#/tga/ide/18_4768?fromPanel=18_915
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

-- Selected bounds from an in-memory calendar, not event logs.
DateBounds AS (
    SELECT MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
           MAX(CAST(v."$part_date" AS DATE)) AS target_end_date
    FROM Config c
    CROSS JOIN UNNEST(
        TRANSFORM(SEQUENCE(c.obt_start_date, CURRENT_DATE, INTERVAL '1' DAY),
                  d -> CAST(d AS VARCHAR))
    ) AS v("$part_date")
    WHERE v.${PartDate:date}
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定每个 fc_id 的首次创角
--------------------------------------------------------------------------------
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
    CROSS JOIN Config c
    CROSS JOIN DateBounds r
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.target_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

CohortUsers AS (
    SELECT
        r.fc_id,
        r.reg_date,
        r.reg_event_time,
        r.event_os,
        r.reg_session_id
    FROM AccountRegistrationRanked r
    CROSS JOIN DateBounds rr
    LEFT JOIN UserBlacklist b ON r.fc_id = b.fc_id
    WHERE r.rn = 1
      AND r.reg_date BETWEEN rr.target_start_date AND rr.target_end_date
      AND b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- session_id → fc_id 映射；login/new_role 仅用于减少扫描量
--------------------------------------------------------------------------------
SessionAccountMap AS (
    SELECT TRIM(CAST(v."#distinct_id" AS VARCHAR)) AS session_id,
           MAX_BY(TRIM(CAST(v.fc_id AS VARCHAR)),
                  ROW(CAST(v."#event_time" AS TIMESTAMP), CAST(v.fc_id AS VARCHAR))) AS fc_id
    FROM ta.v_event_18 v
    CROSS JOIN DateBounds r
    WHERE v."$part_date" BETWEEN
              CAST(DATE_ADD('day', -1, r.target_start_date) AS VARCHAR)
              AND CAST(r.target_end_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 引导事件身份统一：事件自身 fc_id 优先，否则通过 session_id 映射
--------------------------------------------------------------------------------
RoleGuideLogs AS (
    SELECT
        v.gamer_guide_id,
        v.gamer_skip,
        v."$part_event",
        c.fc_id,
        c.event_os
    FROM ta.v_event_18 v
    LEFT JOIN SessionAccountMap sm
        ON TRIM(CAST(v."#distinct_id" AS VARCHAR)) = sm.session_id
    LEFT JOIN (
        SELECT reg_session_id, MAX(fc_id) AS fc_id
        FROM CohortUsers
        WHERE reg_session_id IS NOT NULL
        GROUP BY 1
        HAVING COUNT(DISTINCT fc_id) = 1
    ) rs ON TRIM(CAST(v."#distinct_id" AS VARCHAR)) = rs.reg_session_id
    INNER JOIN CohortUsers c
        ON COALESCE(NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), ''), sm.fc_id, rs.fc_id) = c.fc_id
    CROSS JOIN DateBounds r
    WHERE v."$part_event" IN ('new_role', 'gamer_guide')
      AND v."$part_date" >= CAST(DATE_ADD('day', -1, r.target_start_date) AS VARCHAR)
      AND v."$part_date" <= CAST(r.target_end_date AS VARCHAR)
      AND (
          (
              v."$part_event" = 'new_role'
              AND CAST(v."#event_time" AS TIMESTAMP) = c.reg_event_time
          )
          OR (
              v."$part_event" = 'gamer_guide'
              AND (
                  CAST(v."#event_time" AS TIMESTAMP) >= c.reg_event_time
                  OR (
                      CAST(v."#event_time" AS TIMESTAMP)
                          >= DATE_ADD('day', -1, c.reg_event_time)
                      AND NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '')
                          = c.reg_session_id
                  )
              )
          )
      )
),

FunnelSteps AS (
    SELECT
        s1.gamer_guide_id,
        s1.gamer_skip,
        s1.event_os,
        CASE
            WHEN s1."$part_event" = 'new_role' THEN '1.注册/创建角色'
            ELSE '步骤ID_' || CAST(CAST(s1.gamer_guide_id AS INTEGER) AS VARCHAR)
                 || '_' || CAST(CAST(s1.gamer_skip AS INTEGER) AS VARCHAR)
        END AS "引导步骤",
        COUNT(DISTINCT s1.fc_id) AS funnel_counts
    FROM RoleGuideLogs s1
    GROUP BY 1, 2, 3, 4
),

CohortCounts AS (
    SELECT event_os, COUNT(DISTINCT fc_id) AS new_role_count
    FROM CohortUsers
    GROUP BY 1
),

-- One dimension row per normalized guide ID and skip key.
GuideDim AS (
    SELECT
        CAST(TRY_CAST("gamer_guide_id@gamer_guide_id" AS INTEGER) AS VARCHAR)
            AS "gamer_guide_id@gamer_guide_id",
        CAST(TRY_CAST("gamer_guide_id@gamer_skip" AS INTEGER) AS VARCHAR)
            AS "gamer_guide_id@gamer_skip",
        MAX("gamer_guide_id@extra_id") AS "gamer_guide_id@extra_id",
        MAX("gamer_guide_id@guide_name") AS "gamer_guide_id@guide_name"
    FROM ta_dim.dim_18_0_52779
    GROUP BY 1, 2
)

SELECT
    p1.event_os,
    p3."gamer_guide_id@extra_id" AS guide_id,
    COALESCE(p3."gamer_guide_id@guide_name", p1."引导步骤") AS "引导步骤",
    p1.funnel_counts * 1.0 / NULLIF(CAST(p2.new_role_count AS DOUBLE), 0) AS "值"
FROM FunnelSteps p1
LEFT JOIN CohortCounts p2
    ON p1.event_os = p2.event_os
LEFT JOIN GuideDim p3
    ON CAST(CAST(p1.gamer_guide_id AS INTEGER) AS VARCHAR)
       = CAST(CAST(p3."gamer_guide_id@gamer_guide_id" AS INTEGER) AS VARCHAR)
   AND CAST(CAST(p1.gamer_skip AS INTEGER) AS VARCHAR)
       = CAST(CAST(p3."gamer_guide_id@gamer_skip" AS INTEGER) AS VARCHAR)
WHERE COALESCE(p3."gamer_guide_id@guide_name", p1."引导步骤") NOT IN ('步骤ID_2_0', '步骤ID_0_0')
ORDER BY
    p1.funnel_counts DESC,
    p3."gamer_guide_id@extra_id",
    p1.gamer_skip;
