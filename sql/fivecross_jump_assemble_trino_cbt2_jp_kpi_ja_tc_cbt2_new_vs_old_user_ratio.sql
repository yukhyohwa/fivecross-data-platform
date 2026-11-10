/*
================================================================================
Game    : Jump Assemble (众星之聚)
Region  : TC (Traditional Chinese - TW/HK/MO)
Report  : CBT2 新用户 vs 老用户占比
Tag     : ja_tc  cbt2

时段：CBT2  2026-04-15 ~ 2026-04-23

注册日期说明：
  · 注册日 = 该账号 NUU 事件发生的日期（MIN($part_date) WHERE $part_event='NUU'）
  · 无 NUU 记录的账号视为老用户（regday = NULL → 归入 old）

定义：
  · 新用户（当日）= regday = 当日日期（当天触发 NUU）
  · 老用户（当日）= regday < 当日日期 或 无 NUU 记录
  · 新用户（汇总）= regday 在 2026-04-15 ~ 2026-04-23 内
  · 老用户（汇总）= regday < '2026-04-15' 或 无 NUU 记录

输出结构（两段 UNION）：
  · Part 1：每日明细行（row_type = 'daily'）
  · Part 2：CBT2 整体汇总行（row_type = 'summary'）

Environment: Trino (TA) — v_event_16  表编号 16
================================================================================
*/

WITH

-- ──────────────────────────────────────────────────────────────
-- 1. 黑名单（排除内部 / 水军账号）
-- ──────────────────────────────────────────────────────────────
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- ──────────────────────────────────────────────────────────────
-- 2. iOS 用户白名单（CBT2 只统计 iOS）
-- ──────────────────────────────────────────────────────────────
UserProfile AS (
    SELECT
        "#varchar_id"                                                            AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END)        AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END)        AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END)        AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END)        AS fixed_store
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store')
    GROUP BY "#varchar_id"
    HAVING MAX(CASE WHEN cluster_name = 'fixed_os' THEN tag_value END) = 'iOS'
),

-- ──────────────────────────────────────────────────────────────
-- 2. 用户注册日期 = NUU 事件发生的日期
--    · 有 NUU 记录 → regday = NUU 的 $part_date
--    · 无 NUU 记录 → regday = NULL → 归入老用户
-- ──────────────────────────────────────────────────────────────
UserRegday AS (
    SELECT
        "#account_id",
        "$part_date" AS regday
    FROM ta.v_event_16
    WHERE "$part_event" = 'NUU'
      AND LENGTH("#account_id") = 36
),

-- ──────────────────────────────────────────────────────────────
-- 4. CBT2 期间每日活跃账号（NUU + LOGIN_SUCCESS，去重，仅 iOS）
-- ──────────────────────────────────────────────────────────────
DailyActive AS (
    SELECT DISTINCT
        v."$part_date"  AS part_date,
        v."#account_id" AS account_id
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist bl ON v."#account_id" = bl."#account_id"
    INNER JOIN UserProfile up
            ON v."#account_id"= up.lcx_id
    WHERE bl."#account_id" IS NULL
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND LENGTH(v."#account_id") = 36
),

-- ──────────────────────────────────────────────────────────────
-- 5. 关联注册日期，标记新 / 老用户（按日粒度）
--    · new : regday = part_date（当天触发 NUU）
--    · old : regday < part_date 或 无 NUU 记录（regday IS NULL）
-- ──────────────────────────────────────────────────────────────
DailyClassified AS (
    SELECT
        a.part_date,
        a.account_id,
        CASE
            WHEN r.regday = a.part_date  THEN 'new'
            WHEN r.regday < a.part_date  THEN 'old'
            ELSE                              'old'   -- 无 NUU 记录，视为老用户
        END AS user_type
    FROM DailyActive a
    LEFT JOIN UserRegday r ON a.account_id = r."#account_id"
    WHERE 1=1
),

-- ──────────────────────────────────────────────────────────────
-- 6. 每日汇总（新 / 老 / 合计 人数 + 占比）
-- ──────────────────────────────────────────────────────────────
DailyStats AS (
    SELECT
        part_date,
        COUNT(DISTINCT account_id)                                           AS total_users,
        COUNT(DISTINCT CASE WHEN user_type = 'new' THEN account_id END)     AS new_users,
        COUNT(DISTINCT CASE WHEN user_type = 'old' THEN account_id END)     AS old_users
    FROM DailyClassified
    GROUP BY 1
),

-- ──────────────────────────────────────────────────────────────
-- 7. CBT2 整体汇总（去重：同一用户只计一次）
--    · 新用户汇总 = fixed_regdate 在 CBT2 范围内
--    · 老用户汇总 = fixed_regdate 在 CBT2 开始前
-- ──────────────────────────────────────────────────────────────
PeriodAll AS (
    SELECT DISTINCT account_id, user_type FROM DailyClassified
),

PeriodStats AS (
    SELECT
        COUNT(DISTINCT account_id)                                           AS total_users,
        COUNT(DISTINCT CASE WHEN user_type = 'new' THEN account_id END)     AS new_users,
        COUNT(DISTINCT CASE WHEN user_type = 'old' THEN account_id END)     AS old_users
    FROM PeriodAll
)

-- ══════════════════════════════════════════════════════════════
-- 最终输出：每日明细 UNION 汇总行
-- ══════════════════════════════════════════════════════════════

-- Part 1：每日
SELECT
    'daily'                                                                  AS "汇总类型",
    part_date                                                                AS "日期",
    total_users                                                              AS "活跃用户数",
    new_users                                                                AS "新用户数",
    old_users                                                                AS "老用户数",
    ROUND(CAST(new_users AS DOUBLE) / NULLIF(total_users, 0), 4)            AS "新用户占比",
    ROUND(CAST(old_users AS DOUBLE) / NULLIF(total_users, 0), 4)            AS "老用户占比"
FROM DailyStats

UNION ALL

-- Part 2：CBT2 汇总（整体去重人头）
SELECT
    'summary'                                                                AS "汇总类型",
    '2026-04-15 ~ 2026-04-23'                                               AS "日期",
    total_users                                                              AS "活跃用户数",
    new_users                                                                AS "新用户数",
    old_users                                                                AS "老用户数",
    ROUND(CAST(new_users AS DOUBLE) / NULLIF(total_users, 0), 4)            AS "新用户占比",
    ROUND(CAST(old_users AS DOUBLE) / NULLIF(total_users, 0), 4)            AS "老用户占比"
FROM PeriodStats

ORDER BY 1 DESC, 2 ASC;
