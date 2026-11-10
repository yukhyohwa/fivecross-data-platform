/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 在线时长三方法对比 — 选定日期 iOS 活跃用户队列（去水）
Cohort  : 由参数 ${PartDate:date1} 指定日期范围内的 iOS 活跃用户
Window  : ${PartDate:date1} 所选日期范围，所选即所得
Methods :
  1. 传统心跳法   — 相邻事件间隔 < 120s 累加，末尾事件补 3600s
                    用户标识: "#distinct_id"
  2. 修正心跳法   — 相邻事件间隔 < 120s 累加，末尾事件不补偿
                    用户标识: lcx_id (多字段 COALESCE)
  3. 数数SDK法    — 直接读取 ta_app_end 事件的 "#duration" 字段
                    用户标识: "#user_id"
Output  : 每行一天，三种方法的日人均在线时长(分钟)并排展示
Blacklist: 排除 internal_users 与 is_water
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 0. 生成所选日期序列
--------------------------------------------------------------------------------
DateRange AS (
    SELECT DISTINCT CAST("$part_date" AS DATE) AS dt
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
),

--------------------------------------------------------------------------------
-- 0b. 黑名单定义：内部测试号与水号
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 1. 目标用户队列：所选日期范围内有活跃记录的 iOS 用户（已去水）
--    三种方法各自用不同的 ID 字段，分别建立队列
--------------------------------------------------------------------------------

-- 方法1 队列：distinct_id
Cohort_M1 AS (
    SELECT DISTINCT v."#distinct_id" AS distinct_id
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id" AS VARCHAR)) = 36 THEN CAST(v."#account_id" AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND ub.lcx_id IS NULL
--      AND (
--          LOWER(os) LIKE '%ios%'
--          OR LOWER(os) LIKE '%ipados%'
--          OR "ostype" = 'iOS'
--          OR "#os"    = 'iOS'
--      )
),

-- 方法2 队列：lcx_id (多字段 COALESCE)
Cohort_M2 AS (
    SELECT DISTINCT
        COALESCE(
--            CASE WHEN LENGTH(CAST(v.lcx_id              AS VARCHAR)) = 36 THEN CAST(v.lcx_id              AS VARCHAR) END,
--            CASE WHEN LENGTH(CAST(v.lcxuserid           AS VARCHAR)) = 36 THEN CAST(v.lcxuserid           AS VARCHAR) END,
--            CASE WHEN LENGTH(CAST(v.lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.lcxsdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) AS lcx_id
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(
--            CASE WHEN LENGTH(CAST(v.lcx_id              AS VARCHAR)) = 36 THEN CAST(v.lcx_id              AS VARCHAR) END,
--            CASE WHEN LENGTH(CAST(v.lcxuserid           AS VARCHAR)) = 36 THEN CAST(v.lcxuserid           AS VARCHAR) END,
--            CASE WHEN LENGTH(CAST(v.lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.lcxsdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND COALESCE(
--          CASE WHEN LENGTH(CAST(v.lcx_id              AS VARCHAR)) = 36 THEN CAST(v.lcx_id              AS VARCHAR) END,
--          CASE WHEN LENGTH(CAST(v.lcxuserid           AS VARCHAR)) = 36 THEN CAST(v.lcxuserid           AS VARCHAR) END,
--          CASE WHEN LENGTH(CAST(v.lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.lcxsdkcommon.lcx_id AS VARCHAR) END,
          CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
          CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
      ) IS NOT NULL
--      AND (
--          LOWER(os) LIKE '%ios%'
--          OR LOWER(os) LIKE '%ipados%'
--          OR "ostype" = 'iOS'
--          OR "#os"    = 'iOS'
--      )
),

-- 方法3 队列：#user_id
Cohort_M3 AS (
    SELECT DISTINCT v."#user_id"
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id" AS VARCHAR)) = 36 THEN CAST(v."#account_id" AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND ub.lcx_id IS NULL
--      AND (
--          LOWER(os) LIKE '%ios%'
--          OR LOWER(os) LIKE '%ipados%'
--          OR "ostype" = 'iOS'
--          OR "#os"    = 'iOS'
--      )
),

--------------------------------------------------------------------------------
-- 2. 方法1：传统心跳法
--    末尾事件补 3600s，间隔 >= 120s 视为离线（置 0）
--------------------------------------------------------------------------------
M1_Gaps AS (
    SELECT
        v."#distinct_id"                                                            AS distinct_id,
        v."$part_date"                                                              AS report_date,
        CAST(
            to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
        AS INTEGER)                                                                 AS t,
        COALESCE(
            LEAD(CAST(
                to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
            AS INTEGER)) OVER (
                PARTITION BY v."#distinct_id", v."$part_date"
                ORDER BY v."#event_time"
            ),
            -- 末尾事件补 3600s
            CAST(
                to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
            AS INTEGER) + 3600
        ) AS next_t
    FROM ta.v_event_23 v
    INNER JOIN Cohort_M1 c ON v."#distinct_id" = c.distinct_id
    LEFT JOIN UserBlacklist ub
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id" AS VARCHAR)) = 36 THEN CAST(v."#account_id" AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND v."#event_name" NOT LIKE '%app%'
),

M1_Daily AS (
    SELECT
        report_date,
        COUNT(DISTINCT distinct_id)                                                 AS dau,
        SUM(CASE WHEN next_t - t < 120 THEN next_t - t ELSE 0 END)
            / NULLIF(COUNT(DISTINCT distinct_id), 0) / 60.0                        AS avg_min
    FROM M1_Gaps
    GROUP BY report_date
),

--------------------------------------------------------------------------------
-- 3. 方法2：修正心跳法
--    末尾事件不补偿（LEAD 为 NULL 时 gap = NULL，不计入），间隔 >= 120s 置 0
--------------------------------------------------------------------------------
M2_Gaps AS (
    SELECT
        COALESCE(
        --    CASE WHEN LENGTH(CAST(v.lcx_id              AS VARCHAR)) = 36 THEN CAST(v.lcx_id              AS VARCHAR) END,
        --    CASE WHEN LENGTH(CAST(v.lcxuserid           AS VARCHAR)) = 36 THEN CAST(v.lcxuserid           AS VARCHAR) END,
        --    CASE WHEN LENGTH(CAST(v.lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.lcxsdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        )                                                                           AS lcx_id,
        v."$part_date"                                                              AS report_date,
        LEAD(
            to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
        ) OVER (
            PARTITION BY v."#account_id", v."$part_date"
            ORDER BY v."#event_time"
        )
        - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
                                                                                    AS gap
    FROM ta.v_event_23 v
    INNER JOIN Cohort_M2 c
        ON COALESCE(
         --   CASE WHEN LENGTH(CAST(v.lcx_id              AS VARCHAR)) = 36 THEN CAST(v.lcx_id              AS VARCHAR) END,
         --   CASE WHEN LENGTH(CAST(v.lcxuserid           AS VARCHAR)) = 36 THEN CAST(v.lcxuserid           AS VARCHAR) END,
         --    CASE WHEN LENGTH(CAST(v.lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.lcxsdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) = c.lcx_id
    LEFT JOIN UserBlacklist ub
        ON COALESCE(
         --   CASE WHEN LENGTH(CAST(v.lcx_id              AS VARCHAR)) = 36 THEN CAST(v.lcx_id              AS VARCHAR) END,
         --   CASE WHEN LENGTH(CAST(v.lcxuserid           AS VARCHAR)) = 36 THEN CAST(v.lcxuserid           AS VARCHAR) END,
         --    CASE WHEN LENGTH(CAST(v.lcxsdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.lcxsdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND v."#event_name" NOT LIKE '%app%'
),

M2_Daily AS (
    SELECT
        report_date,
        COUNT(DISTINCT lcx_id)                                                      AS dau,
        SUM(CASE WHEN gap IS NOT NULL AND gap < 120 THEN gap ELSE 0 END)
            / NULLIF(COUNT(DISTINCT lcx_id), 0) / 60.0                             AS avg_min
    FROM M2_Gaps
    GROUP BY report_date
),

--------------------------------------------------------------------------------
-- 4. 方法3：数数SDK法
--    直接读取 ta_app_end 事件的 "#duration" 字段（单位：秒）
--------------------------------------------------------------------------------
M3_Daily AS (
    SELECT
        v."$part_date"                                                              AS report_date,
        COUNT(DISTINCT v."#user_id")                                                AS dau,
        SUM(v."#duration")
            / NULLIF(COUNT(DISTINCT v."#user_id"), 0) / 60.0                       AS avg_min
    FROM ta.v_event_23 v
    INNER JOIN Cohort_M3 c ON v."#user_id" = c."#user_id"
    LEFT JOIN UserBlacklist ub
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id" AS VARCHAR)) = 36 THEN CAST(v."#account_id" AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND v."$part_event" = 'ta_app_end'
    GROUP BY v."$part_date"
)

--------------------------------------------------------------------------------
-- 5. 最终输出：以日期序列为主表，三种方法并排
--------------------------------------------------------------------------------
SELECT
    CAST(dr.dt AS VARCHAR)                                                          AS "日期",

    -- 方法1：传统心跳法
    -- COALESCE(m1.dau,     0)                                                         AS "M1_活跃人数(传统心跳)",
    -- ROUND(COALESCE(m1.avg_min, 0), 2)                                               AS "M1_日均在线(分钟)",

    -- 方法2：修正心跳法
    COALESCE(m2.dau,     0)                                                         AS "M2_活跃人数(修正心跳) - 推荐",
    ROUND(COALESCE(m2.avg_min, 0), 2)                                               AS "M2_日均在线(分钟) - 推荐",

    -- 方法3：数数SDK法
    COALESCE(m3.dau,     0)                                                         AS "M3_活跃人数(SDK)",
    ROUND(COALESCE(m3.avg_min, 0), 2)                                               AS "M3_日均在线(分钟)"

FROM DateRange dr
LEFT JOIN M1_Daily m1 ON CAST(dr.dt AS VARCHAR) = m1.report_date
LEFT JOIN M2_Daily m2 ON CAST(dr.dt AS VARCHAR) = m2.report_date
LEFT JOIN M3_Daily m3 ON CAST(dr.dt AS VARCHAR) = m3.report_date
ORDER BY dr.dt ASC;
