/*
================================================================================
Game    : Jump Assemble (跳跃集结)
Region  : TC (Traditional Chinese)
Report  : 每日每小时累计新用户数对比（事件时间 vs 对比时间）
Description:
    统计两个时段内，每天 0~23 时各小时的累计新增用户数，用于对比两个版本/
    测试阶段的新用户增长节奏。

新用户定义：
  · fixed_regdate 有值 → 以 fixed_regdate 为注册日，落在时段内即为新用户
  · fixed_regdate IS NULL → 视为当天注册（COALESCE 为 NUU 事件的 $part_date）
    即：COALESCE(fixed_regdate, $part_date) = 当天，且有 NUU 事件

仅统计 iOS 用户（fixed_os = 'iOS'，无标签的新用户也放行）

Environment: Trino (TA) — v_event_16  表编号 16
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 两个时段的日期边界
--------------------------------------------------------------------------------
Period1Range AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
),
Period2Range AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_16
    WHERE ${PartDate:date2}
),

--------------------------------------------------------------------------------
-- 2. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 3. 用户标签（fixed_regdate + fixed_os，仅 iOS）
--    手动更新标签，HAVING 过滤 iOS，不存在标签未打的漏网情况
--------------------------------------------------------------------------------
UserProfileDetail AS (
    SELECT
        "#varchar_id"                                                           AS "#account_id",
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END)       AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END)       AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END)       AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END)       AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END)       AS fixed_regdate
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
    HAVING MAX(CASE WHEN cluster_name = 'fixed_os' THEN tag_value END) = 'iOS'
),

--------------------------------------------------------------------------------
-- 4. 新用户事件明细
--    核心逻辑：
--      COALESCE(u.fixed_regdate, e."$part_date") = e."$part_date"
--      → fixed_regdate 有值时：只有注册日 = 当天的用户才匹配
--      → fixed_regdate IS NULL 时：COALESCE fallback 到 $part_date，恒等，全部匹配
--    再限制 $part_event = 'NUU'，确保只取注册当天的首次事件
--    iOS 过滤：有标签的必须是 iOS；无标签记录的新用户放行
--------------------------------------------------------------------------------
NewUserEvents AS (
    -- 事件时间窗口（Period1）
    SELECT
        e."#account_id",
        CAST(e."$part_date" AS DATE)                                            AS reg_date,
        HOUR(e."#event_time")                                                   AS event_hour,
        '事件时间'                                                               AS period,
        p.p_start
    FROM ta.v_event_16 e
    INNER JOIN UserProfileDetail u ON e."#account_id" = u."#account_id"
    LEFT JOIN  UserBlacklist     b ON e."#account_id" = b."#account_id"
    CROSS JOIN Period1Range p
    WHERE b."#account_id" IS NULL
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(e."$part_date" AS DATE) BETWEEN p.p_start AND p.p_end
      AND LENGTH(e."#account_id") = 36
      AND CAST(COALESCE(u.fixed_regdate, CAST(CURRENT_DATE AS VARCHAR)) AS DATE)
          = CAST(e."$part_date" AS DATE)

    UNION ALL

    -- 对比时间窗口（Period2）
    SELECT
        e."#account_id",
        CAST(e."$part_date" AS DATE)                                            AS reg_date,
        HOUR(e."#event_time")                                                   AS event_hour,
        '对比时间'                                                               AS period,
        p.p_start
    FROM ta.v_event_16 e
    INNER JOIN UserProfileDetail u ON e."#account_id" = u."#account_id"
    LEFT JOIN  UserBlacklist     b ON e."#account_id" = b."#account_id"
    CROSS JOIN Period2Range p
    WHERE b."#account_id" IS NULL
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(e."$part_date" AS DATE) BETWEEN p.p_start AND p.p_end
      AND LENGTH(e."#account_id") = 36
      AND CAST(COALESCE(u.fixed_regdate, CAST(CURRENT_DATE AS VARCHAR)) AS DATE)
          = CAST(e."$part_date" AS DATE)
),

--------------------------------------------------------------------------------
-- 5. 去重：同一用户同一天取最早的 event_hour
--------------------------------------------------------------------------------
NewUserFirstHour AS (
    SELECT
        period,
        p_start,
        reg_date,
        "#account_id",
        MIN(event_hour) AS first_hour
    FROM NewUserEvents
    GROUP BY 1, 2, 3, 4
),

--------------------------------------------------------------------------------
-- 6. 每日新用户基准（当天新用户总数，不分小时）
--------------------------------------------------------------------------------
DailyBaseUsers AS (
    SELECT
        period,
        p_start,
        reg_date,
        COUNT(DISTINCT "#account_id") AS daily_new_users
    FROM NewUserFirstHour
    GROUP BY 1, 2, 3
),

--------------------------------------------------------------------------------
-- 7. 展平 0-23 小时，计算每小时累计新用户数
--------------------------------------------------------------------------------
HourlyStats AS (
    SELECT
        n.period,
        n.p_start,
        n.reg_date,
        h.hr                                                                    AS hour,
        COUNT(DISTINCT
            CASE WHEN n.first_hour <= h.hr THEN n."#account_id" END
        )                                                                       AS cumulative_new_users
    FROM NewUserFirstHour n
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1, 2, 3, 4
)

--------------------------------------------------------------------------------
-- 8. 最终输出
--------------------------------------------------------------------------------
SELECT
    s.period                                                                    AS "时段",
    s.p_start                                                                   AS "时段起始日",
    CAST(s.reg_date AS VARCHAR)                                                 AS "日期",
    DATE_DIFF('day', s.p_start, s.reg_date) + 1                                AS "第N天",
    CAST(s.hour AS VARCHAR)                                                     AS "小时",
    s.cumulative_new_users                                                      AS "累计新用户数",
    b.daily_new_users                                                           AS "当日新用户总数",
    ROUND(
        CAST(s.cumulative_new_users AS DOUBLE) / NULLIF(b.daily_new_users, 0)
    , 4)                                                                        AS "累计占比"
FROM HourlyStats s
JOIN DailyBaseUsers b
    ON  s.period   = b.period
    AND s.p_start  = b.p_start
    AND s.reg_date = b.reg_date
ORDER BY
    s.period DESC,
    s.reg_date ASC,
    s.hour ASC;
