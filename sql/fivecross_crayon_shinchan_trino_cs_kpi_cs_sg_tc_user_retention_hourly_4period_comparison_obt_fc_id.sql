/*
================================================================================
项目：蜡笔小新 - 四个对比组的新增用户分时留存对比
1. 新加坡 OBT1：2026-05-08 创角，仅 Android（沿用所提供 SQL 的平台筛选）
2. 新加坡 OBT2：2026-06-15 创角，仅 Android
3. 小新CBT：2026-07-29 创角（CBT 开服首日，继续使用 #user_id）
4. 小新繁体OBT：2026-10-14 起，通过 ${PartDate:date1} 选择创角日期，使用 fc_id

活跃回访使用 login；${Selector:retention} 为留存天数，例如 1 表示 D1。
多日 cohort 按各自创角日计算 Dn，再按小时汇总；当日未结束时结果为实时值。

OBT 口径：
1. 从 2026-10-14 起，在完整 OBT 历史中确定每个 fc_id 的首次 new_role。
2. 同一个 fc_id 的多个角色只计为一个新增账号；无 OBT 创角记录的 login 不计入留存。
3. OBT 黑名单直接使用 user_result_cluster_18 的 #varchar_id，标签为
   internal_users_new、is_water_new、is_windows_new。
4. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/
WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

PeriodTCRange AS (
    SELECT
        MIN(CAST(v."$part_date" AS DATE)) AS p_start,
        MAX(CAST(v."$part_date" AS DATE)) AS p_end
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
),

UserBlacklist13 AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

UserBlacklist18CBT AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),

AccountBlacklist18OBT AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

UserProfileDetail13 AS (
    SELECT
        "#user_id",
        MAX(CASE WHEN cluster_name = 'fixed_os' THEN tag_value END) AS fixed_os
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_os'
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 新加坡两组与小新 CBT 沿用原 #user_id 口径
--------------------------------------------------------------------------------
LegacyCohortUsers AS (
    SELECT
        TRIM(CAST(e."#user_id" AS VARCHAR)) AS user_key,
        CAST(e."$part_date" AS DATE) AS reg_date,
        CAST(NULL AS TIMESTAMP) AS reg_event_time,
        CASE e."$part_date"
            WHEN '2026-05-08' THEN '1.新加坡_OBT1'
            WHEN '2026-06-15' THEN '2.新加坡_OBT2'
        END AS period,
        CAST(e."$part_date" AS DATE) AS p_start,
        13 AS app_id,
        'user_id' AS identity_type
    FROM ta.v_event_13 e
    JOIN UserProfileDetail13 up ON e."#user_id" = up."#user_id"
    LEFT JOIN UserBlacklist13 b ON e."#user_id" = b."#user_id"
    WHERE e."$part_event" = 'new_role'
      -- AND up.fixed_os = 'Android'
      AND e."$part_date" IN ('2026-05-08', '2026-06-15')
      AND b."#user_id" IS NULL
      AND NULLIF(TRIM(CAST(e."#user_id" AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6, 7

    UNION ALL

    SELECT
        TRIM(CAST(e."#user_id" AS VARCHAR)) AS user_key,
        CAST(e."$part_date" AS DATE) AS reg_date,
        CAST(NULL AS TIMESTAMP) AS reg_event_time,
        '3.小新繁体CBT' AS period,
        DATE '2026-07-29' AS p_start,
        18 AS app_id,
        'user_id' AS identity_type
    FROM ta.v_event_18 e
    LEFT JOIN UserBlacklist18CBT b ON e."#user_id" = b."#user_id"
    WHERE e."$part_event" = 'new_role'
      AND e."$part_date" = '2026-07-29'
      AND b."#user_id" IS NULL
      AND NULLIF(TRIM(CAST(e."#user_id" AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6, 7
),

--------------------------------------------------------------------------------
-- 小新繁体 OBT：不能先按报表日期截断创角历史，否则老账号再次创角会被重复计入
--------------------------------------------------------------------------------
OBTRegistrationRanked AS (
    SELECT
        TRIM(CAST(e.fc_id AS VARCHAR)) AS user_key,
        CAST(e."$part_date" AS DATE) AS reg_date,
        CAST(e."#event_time" AS TIMESTAMP) AS reg_event_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(e.fc_id AS VARCHAR))
            ORDER BY e."#event_time" ASC NULLS LAST,
                     CAST(e."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 e
    CROSS JOIN Config c
    CROSS JOIN PeriodTCRange p
    WHERE e."$part_event" = 'new_role'
      AND e."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND e."$part_date" <= CAST(p.p_end AS VARCHAR)
      AND NULLIF(TRIM(CAST(e.fc_id AS VARCHAR)), '') IS NOT NULL
),

OBTCohortUsers AS (
    SELECT
        r.user_key,
        r.reg_date,
        r.reg_event_time,
        '4.小新繁体OBT' AS period,
        p.p_start,
        18 AS app_id,
        'fc_id' AS identity_type
    FROM OBTRegistrationRanked r
    CROSS JOIN PeriodTCRange p
    LEFT JOIN AccountBlacklist18OBT b ON r.user_key = b.fc_id
    WHERE r.rn = 1
      AND r.reg_date BETWEEN p.p_start AND p.p_end
      AND b.fc_id IS NULL
),

CohortUsers AS (
    SELECT * FROM LegacyCohortUsers
    UNION ALL
    SELECT * FROM OBTCohortUsers
),

UserActivity AS (
    -- 新加坡 OBT1/OBT2：按 #user_id 关联目标 Dn 的 login。
    SELECT
        s2.user_key,
        s2.period,
        s2.p_start,
        HOUR(CAST(s1."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_13 s1
    JOIN CohortUsers s2
      ON s2.app_id = 13
     AND s2.identity_type = 'user_id'
     AND TRIM(CAST(s1."#user_id" AS VARCHAR)) = s2.user_key
     AND s1."$part_date" = CAST(DATE_ADD('day', ${Selector:retention}, s2.reg_date) AS VARCHAR)
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" IN (
          CAST(DATE_ADD('day', ${Selector:retention}, DATE '2026-05-08') AS VARCHAR),
          CAST(DATE_ADD('day', ${Selector:retention}, DATE '2026-06-15') AS VARCHAR)
      )

    UNION ALL

    -- 小新 CBT：App 18 中继续按 #user_id 关联。
    SELECT
        s2.user_key,
        s2.period,
        s2.p_start,
        HOUR(CAST(s1."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_18 s1
    JOIN CohortUsers s2
      ON s2.app_id = 18
     AND s2.identity_type = 'user_id'
     AND TRIM(CAST(s1."#user_id" AS VARCHAR)) = s2.user_key
     AND s1."$part_date" = CAST(DATE_ADD('day', ${Selector:retention}, s2.reg_date) AS VARCHAR)
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" = CAST(
          DATE_ADD('day', ${Selector:retention}, DATE '2026-07-29') AS VARCHAR
      )

    UNION ALL

    -- 小新繁体 OBT：App 18 中按 fc_id 关联各创角日对应的目标 Dn。
    SELECT
        s2.user_key,
        s2.period,
        s2.p_start,
        HOUR(CAST(s1."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_18 s1
    JOIN CohortUsers s2
      ON s2.app_id = 18
     AND s2.identity_type = 'fc_id'
     AND TRIM(CAST(s1.fc_id AS VARCHAR)) = s2.user_key
     AND s1."$part_date" = CAST(DATE_ADD('day', ${Selector:retention}, s2.reg_date) AS VARCHAR)
     AND CAST(s1."#event_time" AS TIMESTAMP) >= s2.reg_event_time
    CROSS JOIN PeriodTCRange p
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" BETWEEN
          CAST(DATE_ADD('day', ${Selector:retention}, p.p_start) AS VARCHAR)
          AND CAST(DATE_ADD('day', ${Selector:retention}, p.p_end) AS VARCHAR)
),

BaseUsers AS (
    SELECT period, p_start, COUNT(DISTINCT user_key) AS new_account
    FROM CohortUsers
    GROUP BY 1, 2
),

HourlyStats AS (
    -- 从新增基准展开小时，即使没有回访也输出 0 留存。
    SELECT
        b.period,
        b.p_start,
        h.hr AS hour,
        b.new_account,
        COUNT(DISTINCT a.user_key) AS retained_users
    FROM BaseUsers b
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    LEFT JOIN UserActivity a
      ON a.period = b.period
     AND a.p_start = b.p_start
     AND a.event_hour <= h.hr
    GROUP BY 1, 2, 3, 4
)

SELECT
    period AS "对比阶段",
    CAST(p_start AS VARCHAR) AS "阶段起始日期",
    CAST(hour AS VARCHAR) AS "hour",
    retained_users AS "累计分时留存人数",
    new_account AS "新增基准用户",
    CAST(retained_users AS DOUBLE) / NULLIF(new_account, 0) AS "留存率 (retention rate)"
FROM HourlyStats
ORDER BY period ASC, CAST(hour AS INTEGER) ASC;
