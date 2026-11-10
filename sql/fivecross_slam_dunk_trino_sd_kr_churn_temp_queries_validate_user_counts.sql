/*
================================================================================
验证SQL: 韩服 7月 新用户 / 回流用户 基数核查
目标: 确认 sd_kr_churn 系列 SQL 中人群定义是否正确
================================================================================
*/

WITH

-- ① 7.1-7.21 全量活跃 UV (用 NUU / LOGIN_SUCCESS 合集)
TotalActiveUV AS (
    SELECT
        COUNT(DISTINCT CAST("#account_id" AS VARCHAR)) AS total_active_uv
    FROM ta.v_event_22
    WHERE "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND "$part_date" >= '2026-07-01'
      AND "$part_date" <= '2026-07-21'
      AND "#account_id" IS NOT NULL
      AND "#account_id" <> ''
),

-- ② NUU 首次在 7.1-7.21 的新用户数 (排除历史老用户)
NUU_FirstTime AS (
    SELECT
        CAST("#account_id" AS VARCHAR) AS account_id,
        MIN(CAST("$part_date" AS DATE)) AS first_nuu_date
    FROM ta.v_event_22
    WHERE "$part_event" = 'NUU'
      AND "#account_id" IS NOT NULL
      AND "#account_id" <> ''
    GROUP BY 1
),

NewUsers AS (
    SELECT COUNT(*) AS new_user_count
    FROM NUU_FirstTime
    WHERE first_nuu_date BETWEEN DATE '2026-07-01' AND DATE '2026-07-21'
),

-- ③ 7.1-7.21 活跃 UV，且其 NUU 日期不在窗口内（老用户）
OldActiveUsers AS (
    SELECT DISTINCT CAST(v."#account_id" AS VARCHAR) AS account_id
    FROM ta.v_event_22 v
    LEFT JOIN NUU_FirstTime n ON CAST(v."#account_id" AS VARCHAR) = n.account_id
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND v."$part_date" >= '2026-07-01'
      AND v."$part_date" <= '2026-07-21'
      AND v."#account_id" IS NOT NULL
      AND v."#account_id" <> ''
      AND (n.first_nuu_date IS NULL OR n.first_nuu_date < DATE '2026-07-01')
),

-- ④ 对这批老用户，往前最多扫 180 天的登录日志，计算 prev_log_date
OldUserLoginHistory AS (
    SELECT DISTINCT
        CAST("#account_id" AS VARCHAR) AS account_id,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_22
    WHERE "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND "$part_date" >= '2026-01-01'   -- 往前追溯 ~6 个月
      AND "$part_date" <= '2026-07-21'
      AND "#account_id" IS NOT NULL
      AND "#account_id" <> ''
),

OldUserWithPrev AS (
    SELECT
        h.account_id,
        h.log_date,
        LAG(h.log_date, 1) OVER (PARTITION BY h.account_id ORDER BY h.log_date) AS prev_log_date,
        MIN(h.log_date) OVER (PARTITION BY h.account_id) AS first_seen_date
    FROM OldUserLoginHistory h
    INNER JOIN OldActiveUsers o ON h.account_id = o.account_id
),

-- ⑤ 按不同回流天数阈值统计人数（30天 / 60天 / 90天 / 只看7月内活跃首次出现）
ReturnUserBreakdown AS (
    SELECT
        account_id,
        MAX(CASE WHEN log_date BETWEEN DATE '2026-07-01' AND DATE '2026-07-21' THEN log_date END) AS july_first_login,
        MAX(CASE WHEN log_date < DATE '2026-07-01' THEN log_date END) AS last_login_before_july
    FROM OldUserWithPrev
    GROUP BY account_id
),

ReturnUserStats AS (
    SELECT
        COUNT(*) AS old_active_total,
        COUNT(CASE WHEN last_login_before_july IS NULL THEN 1 END) AS no_history_before_july,
        COUNT(CASE WHEN last_login_before_july IS NOT NULL
                    AND DATE_DIFF('day', last_login_before_july, july_first_login) >= 30 THEN 1 END) AS return_30d,
        COUNT(CASE WHEN last_login_before_july IS NOT NULL
                    AND DATE_DIFF('day', last_login_before_july, july_first_login) >= 60 THEN 1 END) AS return_60d,
        COUNT(CASE WHEN last_login_before_july IS NOT NULL
                    AND DATE_DIFF('day', last_login_before_july, july_first_login) >= 90 THEN 1 END) AS return_90d,
        MIN(DATE_DIFF('day', last_login_before_july, july_first_login)) AS min_gap_days,
        MAX(DATE_DIFF('day', last_login_before_july, july_first_login)) AS max_gap_days,
        APPROX_PERCENTILE(
            DATE_DIFF('day', last_login_before_july, july_first_login), 0.5
        ) AS median_gap_days
    FROM ReturnUserBreakdown
    WHERE july_first_login IS NOT NULL
      AND last_login_before_july IS NOT NULL
)

-- ============================================================
-- 最终输出: 汇总各维度人数
-- ============================================================
SELECT
    'A. 7.1-7.21 全量活跃UV' AS metric,
    CAST((SELECT total_active_uv FROM TotalActiveUV) AS VARCHAR) AS value

UNION ALL SELECT
    'B. 新用户 (NUU首次在7.1-7.21)',
    CAST((SELECT new_user_count FROM NewUsers) AS VARCHAR)

UNION ALL SELECT
    'C. 老用户活跃总数 (非首次NUU)',
    CAST((SELECT old_active_total FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'D. 老用户中: 7月前无登录记录 (6个月内)',
    CAST((SELECT no_history_before_july FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'E. 回流用户 ≥30天 (7月前有记录)',
    CAST((SELECT return_30d FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'F. 回流用户 ≥60天 ✅当前SQL使用',
    CAST((SELECT return_60d FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'G. 回流用户 ≥90天',
    CAST((SELECT return_90d FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'H. 老用户距上次登录 最小间隔(天)',
    CAST((SELECT min_gap_days FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'I. 老用户距上次登录 最大间隔(天)',
    CAST((SELECT max_gap_days FROM ReturnUserStats) AS VARCHAR)

UNION ALL SELECT
    'J. 老用户距上次登录 中位数间隔(天)',
    CAST((SELECT median_gap_days FROM ReturnUserStats) AS VARCHAR)
