/*
================================================================================
蜡笔小新 - 新手引导漏斗对比 (新加坡 OBT1 vs 新加坡 OBT2 vs 繁体)
说明：
1. 新加坡 OBT1：开服首日 (2026-05-08) 仅限新加坡国家
2. 新加坡 OBT2：开服首日 (2026-06-15) 仅限新加坡国家
3. 小新繁体：项目 v_event_18，支持通过数数后台时间宏 ${PartDate:date1} 筛选首日/日期
================================================================================
*/

WITH
-- 1. 黑名单
UserBlacklist13 AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),
UserBlacklist18 AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 2. 新加坡用户标签 (筛选国家)
UserProfileDetail13 AS (
    SELECT 
        "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_os' THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_13
    WHERE cluster_name IN ('fixed_country', 'fixed_os', 'fixed_regdate')
    GROUP BY 1
),

-- 3. 对比目标用户群 (分3组: 新加坡 OBT1, 新加坡 OBT2, 小新繁体)
CohortUsers AS (
    -- 组1：新加坡 OBT1 开服首日 (2026-05-08)
    SELECT 
        '1.新加坡_OBT1' AS cohort_name,
        e."#user_id" AS user_id,
        e."#distinct_id" AS distinct_id,
        e."$part_date" AS role_date,
        13 AS app_id
    FROM ta.v_event_13 e
    JOIN UserProfileDetail13 up 
        ON e."#user_id" = up."#user_id"
    WHERE e."$part_event" = 'new_role'
      AND CAST(e."#event_time" AS VARCHAR) >= '2026-05-08 21:30:00'
      AND up.fixed_country = '新加坡'
      AND e."$part_date" = '2026-05-08'
    GROUP BY 1, 2, 3, 4, 5

    UNION ALL

    -- 组2：新加坡 OBT2 开服首日 (2026-06-15)
    SELECT 
        '2.新加坡_OBT2' AS cohort_name,
        e."#user_id" AS user_id,
        e."#distinct_id" AS distinct_id,
        e."$part_date" AS role_date,
        13 AS app_id
    FROM ta.v_event_13 e
    JOIN UserProfileDetail13 up 
        ON e."#user_id" = up."#user_id"
    WHERE e."$part_event" = 'new_role'
      AND up.fixed_country = '新加坡'
      AND e."$part_date" = '2026-06-15'
    GROUP BY 1, 2, 3, 4, 5

    UNION ALL

    -- 组3：小新繁体 (v_event_18，可通过数数后台 ${PartDate:date1} 筛选日期)
    SELECT 
        '3.小新繁体' AS cohort_name,
        e."#user_id" AS user_id,
        e."#distinct_id" AS distinct_id,
        e."$part_date" AS role_date,
        18 AS app_id
    FROM ta.v_event_18 e
    WHERE e."$part_event" = 'new_role'
      AND (${PartDate:date1})
    GROUP BY 1, 2, 3, 4, 5
),

-- 4. 引导日志提取：仅统计创角当天
RoleGuideLogs AS (
    -- 项目13 日志 (新加坡 OBT1 & OBT2)
    SELECT 
        s2.cohort_name,
        s1.gamer_guide_id,
        s1.gamer_skip,
        s1."$part_event",
        s2.user_id,
        s2.distinct_id
    FROM ta.v_event_13 s1
    INNER JOIN (SELECT * FROM CohortUsers WHERE app_id = 13) s2 
        ON s1."#distinct_id" = s2.distinct_id
    LEFT JOIN UserBlacklist13 s3 
        ON s2.user_id = s3.user_id
    WHERE s3.user_id IS NULL
      AND s1."$part_event" IN ('new_role', 'gamer_guide')
      AND s1."$part_date" = s2.role_date

    UNION ALL

    -- 项目18 日志 (小新繁体)
    SELECT 
        s2.cohort_name,
        s1.gamer_guide_id,
        s1.gamer_skip,
        s1."$part_event",
        s2.user_id,
        s2.distinct_id
    FROM ta.v_event_18 s1
    INNER JOIN (SELECT * FROM CohortUsers WHERE app_id = 18) s2 
        ON s1."#distinct_id" = s2.distinct_id
    LEFT JOIN UserBlacklist18 s3 
        ON s2.user_id = s3.user_id
    WHERE s3.user_id IS NULL
      AND s1."$part_event" IN ('new_role', 'gamer_guide')
      AND s1."$part_date" = s2.role_date
),

-- 5. 使用特定用户的时间线预估每个引导步骤对应的关卡
GuideStageMapping AS (
    WITH UserTimeline AS (
        SELECT 
            "$part_event" AS event_name,
            "#event_time" AS event_time,
            CAST(CAST(gamer_guide_id AS INTEGER) AS VARCHAR) || '_' || CAST(CAST(gamer_skip AS INTEGER) AS VARCHAR) AS guide_id,
            ds."stage_id@stage_name_real" AS stage_name,
            SUM(CASE WHEN "$part_event" = 'stage_fight' THEN 1 ELSE 0 END) OVER (ORDER BY "#event_time") AS stage_grp
        FROM ta.v_event_13 v
        LEFT JOIN ta_dim.dim_13_0_18203 ds 
            ON CAST(v.stage_id AS BIGINT) = ds."stage_id@stage_id"
        WHERE v."$part_date" IN ('2026-05-08', '2026-05-09')
          AND v."#distinct_id" = '953f5d69-cf31-4e31-8979-bfd10abd1280'
          AND (
              v."$part_event" = 'gamer_guide' 
              OR (v."$part_event" = 'stage_fight' AND v.a_rst[1].key = '1001')
          )
    ),
    StageGroups AS (
        SELECT 
            stage_grp, 
            MAX(stage_name) AS last_stage_name
        FROM UserTimeline
        WHERE event_name = 'stage_fight'
        GROUP BY stage_grp
    )
    SELECT 
        u.guide_id,
        MAX(s.last_stage_name) AS est_stage_name
    FROM UserTimeline u
    LEFT JOIN StageGroups s 
        ON u.stage_grp = s.stage_grp
    WHERE u.event_name = 'gamer_guide' 
      AND u.guide_id IS NOT NULL
    GROUP BY u.guide_id
)

-- 6. 结果计算与漏斗展示
SELECT 
    p1.cohort_name AS "对比组",
    p3."gamer_guide_id@extra_id" AS "步骤ID",
    COALESCE(p3."gamer_guide_id@guide_name", p1."引导步骤") AS "引导步骤",
    gsm.est_stage_name AS "预估所处关卡",
    p1.funnel_counts AS "通过人数",
    p2.new_role_count AS "创角总人数",
    p1.funnel_counts * 1.0 / NULLIF(CAST(p2.new_role_count AS DOUBLE), 0) AS "通过率"
FROM (
    SELECT 
        s1.cohort_name,
        s1.gamer_guide_id,
        s1.gamer_skip,
        CASE 
            WHEN s1."$part_event" = 'new_role' THEN '1.注册/创建角色'
            ELSE '步骤ID_' || CAST(CAST(s1.gamer_guide_id AS INTEGER) AS VARCHAR) || '_' || CAST(CAST(s1.gamer_skip AS INTEGER) AS VARCHAR)
        END AS "引导步骤",
        COUNT(DISTINCT distinct_id) AS funnel_counts
    FROM RoleGuideLogs s1 
    GROUP BY 1, 2, 3, 4
) p1
LEFT JOIN (
    SELECT 
        s1.cohort_name,
        COUNT(DISTINCT distinct_id) AS new_role_count 
    FROM RoleGuideLogs s1 
    WHERE "$part_event" = 'new_role'  
    GROUP BY 1
) p2 
    ON p1.cohort_name = p2.cohort_name
LEFT JOIN ta_dim.dim_13_0_18504 p3 
    ON CAST(CAST(p1.gamer_guide_id AS INTEGER) AS VARCHAR) = CAST(CAST(p3."gamer_guide_id@gamer_guide_id" AS INTEGER) AS VARCHAR) 
   AND CAST(CAST(p1.gamer_skip AS INTEGER) AS VARCHAR) = CAST(CAST(p3."gamer_guide_id@gamer_skip" AS INTEGER) AS VARCHAR)
LEFT JOIN GuideStageMapping gsm 
    ON CAST(CAST(p1.gamer_guide_id AS INTEGER) AS VARCHAR) || '_' || CAST(CAST(p1.gamer_skip AS INTEGER) AS VARCHAR) = gsm.guide_id
WHERE COALESCE(p3."gamer_guide_id@guide_name", p1."引导步骤") NOT IN ('步骤ID_2_0', '步骤ID_0_0')
  AND (p3."gamer_guide_id@extra_id" <= 44 OR p3."gamer_guide_id@extra_id" IS NULL)
  AND (p3."gamer_guide_id@extra_id" <> 17 OR p3."gamer_guide_id@extra_id" IS NULL)
ORDER BY 
    p1.cohort_name, 
    COALESCE(p3."gamer_guide_id@extra_id", 0), 
    p1.gamer_skip;
