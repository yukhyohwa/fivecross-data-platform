WITH

--------------------------------------------------------------------------------
-- 1. 时段边界
--    CBT1 固定为 2025-11-25
--    CBT2 由参数 ${PartDate:date2} 控制
--------------------------------------------------------------------------------
Period1Range AS (
    SELECT 
        DATE '2025-11-25' AS p_start, 
        DATE '2025-11-25' AS p_end
),
Period2Range AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_16
    WHERE ${PartDate:date2}
),

--------------------------------------------------------------------------------
-- 2. 黑名单与 OS 标签
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

UserTags AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store')
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 3. 注册日获取
--------------------------------------------------------------------------------
RealRegdate_CBT1 AS (
    SELECT
        "#account_id",
        MIN("$part_date") AS real_regdate
    FROM ta.v_event_16
    WHERE "$part_date" >= '2024-01-01'
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
    GROUP BY 1
),
RealRegdate_New AS (
    SELECT
        e."#account_id",
        MIN(e."$part_date") AS real_regdate
    FROM ta.v_event_16 e
    CROSS JOIN (
        SELECT CAST(p_start AS VARCHAR) AS scan_start
        FROM Period2Range
        WHERE p_start IS NOT NULL
    ) bounds
    WHERE e."$part_date" >= bounds.scan_start
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
    GROUP BY 1
),

AllRegdate AS (
    SELECT "#account_id", real_regdate, 'CBT1' AS src FROM RealRegdate_CBT1
    UNION ALL
    SELECT "#account_id", real_regdate, 'CBT2'  AS src FROM RealRegdate_New
),

--------------------------------------------------------------------------------
-- 4. Cohort 用户集
--    满足时段且满足 OS 标签要求的用户
--------------------------------------------------------------------------------
CohortUsers AS (
    -- Period1 (CBT1): 必须是 Android
    SELECT
        r."#account_id",
        r.real_regdate    AS reg_date,
        tags.fixed_os     AS ostype,
        'CBT1'            AS period
    FROM AllRegdate r
    INNER JOIN UserTags tags ON r."#account_id" = tags."#account_id"
    LEFT JOIN UserBlacklist b ON r."#account_id" = b."#account_id"
    WHERE b."#account_id" IS NULL
      AND r.real_regdate = '2025-11-25'
      AND r.src = 'CBT1'
      AND (tags.fixed_os = 'Android' OR LOWER(tags.fixed_os) LIKE '%android%')

    UNION ALL

    -- Period2 (CBT2): 必须是 iOS
    SELECT
        r."#account_id",
        r.real_regdate    AS reg_date,
        tags.fixed_os     AS ostype,
        'CBT2'            AS period
    FROM AllRegdate r
    INNER JOIN UserTags tags ON r."#account_id" = tags."#account_id"
    LEFT JOIN UserBlacklist b ON r."#account_id" = b."#account_id"
    CROSS JOIN Period2Range p
    WHERE b."#account_id" IS NULL
      AND r.real_regdate IS NOT NULL
      AND CAST(r.real_regdate AS DATE) BETWEEN p.p_start AND p.p_end
      AND r.src = 'CBT2'
      AND (tags.fixed_os = 'iOS' OR LOWER(tags.fixed_os) LIKE '%ios%')
),

--------------------------------------------------------------------------------
-- 5. 回访行为明细
--------------------------------------------------------------------------------
UserActivity AS (
    -- CBT1 窗口
    SELECT
        s1."#account_id",
        s2.period,
        DATE '2025-11-25' AS p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers  s2 ON s1."#account_id" = s2."#account_id" AND s2.period = 'CBT1'
    WHERE s1."$part_date" BETWEEN '2025-11-25'
                               AND CAST(DATE_ADD('day', 7, DATE '2025-11-25') AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')

    UNION ALL

    -- CBT2 窗口
    SELECT
        s1."#account_id",
        s2.period,
        p.p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers  s2 ON s1."#account_id" = s2."#account_id" AND s2.period = 'CBT2'
    CROSS JOIN Period2Range p
    WHERE s1."$part_date" BETWEEN CAST(p.p_start AS VARCHAR)
                               AND CAST(DATE_ADD('day', 7, p.p_end) AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')
),

--------------------------------------------------------------------------------
-- 6. 基准用户数
--------------------------------------------------------------------------------
BaseUsers AS (
    SELECT period, COUNT(DISTINCT "#account_id") AS new_account
    FROM CohortUsers
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 7. 分时累计留存统计
--------------------------------------------------------------------------------
HourlyStats AS (
    SELECT
        a.period,
        a.p_start,
        h.hr AS hour,
        COUNT(DISTINCT
            CASE
                WHEN a.diff_day = ${Selector:retention}
                 AND a.event_hour <= h.hr
                THEN a."#account_id"
            END
        ) AS retained_users
    FROM UserActivity a
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1, 2, 3
)

--------------------------------------------------------------------------------
-- 8. 最终输出
--------------------------------------------------------------------------------
SELECT
    s.period,
    s.p_start,
    CAST(s.hour AS VARCHAR)                                      AS "hour",
    s.retained_users                                             AS "累计分时留存人数",
    b.new_account                                                AS "新增基准用户",
    CAST(s.retained_users AS DOUBLE) / NULLIF(b.new_account, 0) AS "留存率 (retention rate)"
FROM HourlyStats s
JOIN BaseUsers b ON s.period = b.period
ORDER BY s.period DESC, s.hour ASC;
