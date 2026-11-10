/*
================================================================================
Dashboard : 暴扣JP_看板 · 每日分R登录人数
Project   : 街篮日服 (ThinkingData Project ID 5, UTC+9)
Engine    : Trino

Dynamic parameters
  1. ${PartDate:login_date}
     Login date range. Returns one row per login date in this range.
  2. ${PartDate:pay_date}
     Payment date range. Each user's completed orders in this range are summed
     in JPY and used to assign the R tier for every login date.

Definitions
  - Login user: DISTINCT #user_id with event = login.
  - Spend: SUM(order_balance_price) with event = order_finish.
  - R tier: selected payment-range cumulative spend, not lifetime spend as of
    each login date.
  - The 30,000-59,999 JPY tier is included to avoid an unassigned gap between
    10,000-29,999 and 60,000-99,999.

Validated source tables
  - ta.v_event_5
  - ta.user_result_cluster_5 (not used until a Street Rivals JP blacklist is
    explicitly confirmed)
================================================================================
*/

WITH
DailyLogins AS (
    SELECT
        CAST(v."$part_date" AS DATE) AS login_date,
        CAST(v."#user_id" AS VARCHAR) AS user_id
    FROM ta.v_event_5 v
    WHERE v."$part_event" = 'login'
      AND ${PartDate:login_date}
      AND v."#user_id" IS NOT NULL
      AND CAST(v."#user_id" AS VARCHAR) <> ''
    GROUP BY 1, 2
),

LoginUsers AS (
    SELECT DISTINCT user_id
    FROM DailyLogins
),

UserSpendInSelectedRange AS (
    SELECT
        CAST(v."#user_id" AS VARCHAR) AS user_id,
        SUM(COALESCE(TRY_CAST(v.order_balance_price AS DOUBLE), 0)) AS cumulative_spend_jpy
    FROM ta.v_event_5 v
    INNER JOIN LoginUsers u
        ON CAST(v."#user_id" AS VARCHAR) = u.user_id
    WHERE v."$part_event" = 'order_finish'
      AND ${PartDate:pay_date}
    GROUP BY 1
),

DailyLoginRtiers AS (
    SELECT
        l.login_date,
        l.user_id,
        COALESCE(s.cumulative_spend_jpy, 0) AS cumulative_spend_jpy,
        CASE
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 1000000 THEN '1000000+'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 500000  THEN '500000-999999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 200000  THEN '200000-499999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 100000  THEN '100000-199999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 60000   THEN '60000-99999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 30000   THEN '30000-59999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 10000   THEN '10000-29999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 5000    THEN '5000-9999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 2000    THEN '2000-4999'
            WHEN COALESCE(s.cumulative_spend_jpy, 0) >= 1       THEN '1-1999'
            ELSE '0'
        END AS r_tier
    FROM DailyLogins l
    LEFT JOIN UserSpendInSelectedRange s
        ON l.user_id = s.user_id
)

SELECT
    login_date AS "日期",
    COUNT(DISTINCT CASE WHEN r_tier = '1000000+'      THEN user_id END) AS "100万以上",
    COUNT(DISTINCT CASE WHEN r_tier = '500000-999999' THEN user_id END) AS "50万~99万",
    COUNT(DISTINCT CASE WHEN r_tier = '200000-499999' THEN user_id END) AS "20万~49万",
    COUNT(DISTINCT CASE WHEN r_tier = '100000-199999' THEN user_id END) AS "10万~19万",
    COUNT(DISTINCT CASE WHEN r_tier = '60000-99999'   THEN user_id END) AS "6万~9万",
    COUNT(DISTINCT CASE WHEN r_tier = '30000-59999'   THEN user_id END) AS "3万~5万",
    COUNT(DISTINCT CASE WHEN r_tier = '10000-29999'   THEN user_id END) AS "1万~2万",
    COUNT(DISTINCT CASE WHEN r_tier = '5000-9999'     THEN user_id END) AS "5000~9999",
    COUNT(DISTINCT CASE WHEN r_tier = '2000-4999'     THEN user_id END) AS "2000~4999",
    COUNT(DISTINCT CASE WHEN r_tier = '1-1999'        THEN user_id END) AS "1~1999",
    COUNT(DISTINCT CASE WHEN r_tier = '0'             THEN user_id END) AS "0",
    COUNT(DISTINCT user_id) AS "总登录人数"
FROM DailyLoginRtiers
GROUP BY 1
ORDER BY 1 DESC;
