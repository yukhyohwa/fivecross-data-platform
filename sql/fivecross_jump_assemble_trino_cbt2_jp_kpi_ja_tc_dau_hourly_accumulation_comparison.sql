/*
================================================================================
Game    : Jump Assemble (跳跃集结)
Region  : TC (Traditional Chinese)
Report  : 每日每小时累计 DAU 对比（事件时间 vs 对比时间）
Description:
    统计两个时段内，每天 0~23 时各小时的累计活跃用户数（DAU），
    用于对比两个版本/测试阶段的用户活跃增长节奏。

DAU 定义：当天有 NUU 或 LOGIN_SUCCESS 事件的去重用户数
仅统计 iOS 用户（通过 fixed_os 标签过滤）

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
-- 3. iOS 用户白名单（通过 fixed_os 标签过滤）
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
-- 4. 活跃事件明细（事件时间 + 对比时间，各自扫描对应窗口）
--------------------------------------------------------------------------------
ActiveEvents AS (
    -- 事件时间窗口（Period1）
    SELECT
        e."#account_id",
        CAST(e."$part_date" AS DATE)    AS act_date,
        HOUR(e."#event_time")           AS event_hour,
        '事件时间'                       AS period,
        p.p_start
    FROM ta.v_event_16 e
    INNER JOIN UserProfileDetail u ON e."#account_id" = u."#account_id"
    LEFT JOIN  UserBlacklist b     ON e."#account_id" = b."#account_id"
    CROSS JOIN Period1Range p
    WHERE b."#account_id" IS NULL
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(e."$part_date" AS DATE) BETWEEN p.p_start AND p.p_end
      AND LENGTH(e."#account_id") = 36

    UNION ALL

    -- 对比时间窗口（Period2）
    SELECT
        e."#account_id",
        CAST(e."$part_date" AS DATE)    AS act_date,
        HOUR(e."#event_time")           AS event_hour,
        '对比时间'                       AS period,
        p.p_start
    FROM ta.v_event_16 e
    INNER JOIN UserProfileDetail u ON e."#account_id" = u."#account_id"
    LEFT JOIN  UserBlacklist b     ON e."#account_id" = b."#account_id"
    CROSS JOIN Period2Range p
    WHERE b."#account_id" IS NULL
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(e."$part_date" AS DATE) BETWEEN p.p_start AND p.p_end
      AND LENGTH(e."#account_id") = 36
),

--------------------------------------------------------------------------------
-- 5. 去重：同一用户同一天取最早的 event_hour
--------------------------------------------------------------------------------
UserFirstHour AS (
    SELECT
        period,
        p_start,
        act_date,
        "#account_id",
        MIN(event_hour) AS first_hour
    FROM ActiveEvents
    GROUP BY 1, 2, 3, 4
),

--------------------------------------------------------------------------------
-- 6. 每日 DAU 基准（当天活跃用户总数，不分小时）
--------------------------------------------------------------------------------
DailyDAU AS (
    SELECT
        period,
        p_start,
        act_date,
        COUNT(DISTINCT "#account_id") AS dau
    FROM UserFirstHour
    GROUP BY 1, 2, 3
),

--------------------------------------------------------------------------------
-- 7. 展平 0-23 小时，计算每小时累计 DAU
--    累计逻辑：first_hour <= h.hr 的用户都计入
--------------------------------------------------------------------------------
HourlyStats AS (
    SELECT
        u.period,
        u.p_start,
        u.act_date,
        h.hr                                                                    AS hour,
        COUNT(DISTINCT
            CASE WHEN u.first_hour <= h.hr THEN u."#account_id" END
        )                                                                       AS cumulative_dau
    FROM UserFirstHour u
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1, 2, 3, 4
)

--------------------------------------------------------------------------------
-- 8. 最终输出
--------------------------------------------------------------------------------
SELECT
    s.period                                                                    AS "时段",
    s.p_start                                                                   AS "时段起始日",
    CAST(s.act_date AS VARCHAR)                                                 AS "日期",
    DATE_DIFF('day', s.p_start, s.act_date) + 1                                AS "第N天",
    CAST(s.hour AS VARCHAR)                                                     AS "小时",
    s.cumulative_dau                                                            AS "累计DAU",
    d.dau                                                                       AS "当日DAU",
    ROUND(
        CAST(s.cumulative_dau AS DOUBLE) / NULLIF(d.dau, 0)
    , 4)                                                                        AS "累计占比"
FROM HourlyStats s
JOIN DailyDAU d
    ON  s.period   = d.period
    AND s.p_start  = d.p_start
    AND s.act_date = d.act_date
ORDER BY
    s.period DESC,
    s.act_date ASC,
    s.hour ASC;
