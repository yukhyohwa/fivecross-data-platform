WITH
NuuUsers AS (
    SELECT CAST("#account_id" AS VARCHAR) AS account_id
    FROM ta.v_event_22
    WHERE "$part_event" = 'NUU'
      AND "$part_date" BETWEEN '2026-07-01' AND '2026-07-21'
      AND "#account_id" IS NOT NULL AND "#account_id" <> ''
    GROUP BY 1
),
AllNuuUsers AS (
    SELECT CAST("#account_id" AS VARCHAR) AS account_id
    FROM ta.v_event_22
    WHERE "$part_event" = 'NUU'
      AND "#account_id" IS NOT NULL AND "#account_id" <> ''
    GROUP BY 1
),
LoginHistory AS (
    SELECT DISTINCT
        CAST("#account_id" AS VARCHAR) AS account_id,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_22
    WHERE "$part_event" = 'LOGIN_SUCCESS'
      AND "$part_date" BETWEEN '2026-04-27' AND '2026-07-21'
      AND "#account_id" IS NOT NULL AND "#account_id" <> ''
),
ReturnCandidates AS (
    SELECT account_id, log_date,
           LAG(log_date) OVER (PARTITION BY account_id ORDER BY log_date) AS previous_login_date
    FROM LoginHistory
),
ReturnUsers AS (
    SELECT r.account_id
    FROM ReturnCandidates r
    LEFT JOIN AllNuuUsers n ON r.account_id = n.account_id
    WHERE n.account_id IS NULL
      AND r.log_date BETWEEN DATE '2026-07-01' AND DATE '2026-07-21'
      AND (r.previous_login_date IS NULL
           OR DATE_DIFF('day', r.previous_login_date, r.log_date) >= 60)
    GROUP BY 1
),
Cohort AS (
    SELECT account_id, 'new' AS user_type FROM NuuUsers
    UNION ALL
    SELECT account_id, 'return_60d' AS user_type FROM ReturnUsers
),
PostWindowLogins AS (
    SELECT DISTINCT CAST("#account_id" AS VARCHAR) AS account_id
    FROM ta.v_event_22
    WHERE "$part_event" = 'LOGIN_SUCCESS'
      AND "$part_date" BETWEEN '2026-07-22' AND '2026-07-28'
      AND "#account_id" IS NOT NULL AND "#account_id" <> ''
)
SELECT
    c.user_type AS "用户类型",
    COUNT(DISTINCT c.account_id) AS "目标人群",
    COUNT(DISTINCT p.account_id) AS "直接匹配后续LOGIN_SUCCESS",
    COUNT(DISTINCT c.account_id) - COUNT(DISTINCT p.account_id) AS "未匹配后续LOGIN_SUCCESS",
    ROUND(COUNT(DISTINCT p.account_id) * 100.0 / COUNT(DISTINCT c.account_id), 2) AS "后续登录匹配率(%)"
FROM Cohort c
LEFT JOIN PostWindowLogins p ON c.account_id = p.account_id
GROUP BY 1
ORDER BY 1
