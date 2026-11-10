/*
================================================================================
Game    : Kuroko's Basketball KR
Region  : KR
Purpose : Find users with no valid payment to date, no login within 1 year,
          and login level below 10 (using uuid as user identifier).
Engine  : Trino (TA)
Table   : ta.v_event_12
Output  : uuid, "#account_id", last_login_time, level, total_pay_amount_usd

Notes:
  - No payment is evaluated at uuid level: no valid charge / scroin_buy /
    srcoin_buy in history.
  - Inactive is evaluated at uuid level: latest login is older than
    CURRENT_DATE - 1 year.
  - Level is evaluated at uuid + #account_id level: latest non-null
    login.level < 10.
================================================================================
*/

WITH
LoginAccounts AS (
    SELECT
        CAST(uuid AS VARCHAR) AS user_id,
        CAST("#account_id" AS VARCHAR) AS "#account_id",
        MAX(CAST("$part_date" AS DATE)) AS last_account_login_date,
        MAX("#event_time") AS last_account_login_time,
        MAX_BY(
            TRY_CAST(level AS INTEGER),
            CASE WHEN TRY_CAST(level AS INTEGER) IS NOT NULL THEN "#event_time" END
        ) AS last_login_level
    FROM ta.v_event_12
    WHERE "$part_date" >= '2024-06-19'
      AND "$part_event" = 'login'
      AND uuid IS NOT NULL
      AND CAST(uuid AS VARCHAR) <> ''
      AND "#account_id" IS NOT NULL
      AND CAST("#account_id" AS VARCHAR) <> ''
    GROUP BY 1, 2
),

UserLoginStats AS (
    SELECT
        CAST(uuid AS VARCHAR) AS user_id,
        MAX(CAST("$part_date" AS DATE)) AS last_user_login_date,
        MAX("#event_time") AS last_user_login_time
    FROM ta.v_event_12
    WHERE "$part_date" >= '2024-06-19'
      AND "$part_event" = 'login'
      AND uuid IS NOT NULL
      AND CAST(uuid AS VARCHAR) <> ''
    GROUP BY 1
),

UserPaymentStats AS (
    SELECT
        CAST(s1.uuid AS VARCHAR) AS user_id,
        SUM(TRY_CAST(s1.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1)) AS total_pay_amount_usd
    FROM ta.v_event_12 s1
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        GROUP BY 1, 2
    ) ex
      ON s1."$part_date" = ex.ex_date
     AND s1.pay_currency = ex.currency
    WHERE s1."$part_date" >= '2024-06-19'
      AND s1.uuid IS NOT NULL
      AND CAST(s1.uuid AS VARCHAR) <> ''
      AND (
              (
                  s1."$part_event" = 'charge'
                  AND s1.pay_currency <> 'kuroko_pay'
                  AND (s1.sandbox = FALSE OR s1.sandbox IS NULL)
              )
           OR s1."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
      AND COALESCE(TRY_CAST(s1.pay_amount AS DOUBLE), 0.0) > 0
    GROUP BY 1
)

SELECT
    la.user_id AS "uuid",
    la."#account_id" AS "#account_id",
    la.last_account_login_time AS "last_login_time",
    la.last_login_level AS "level",
    ROUND(COALESCE(up.total_pay_amount_usd, 0.0), 2) AS "total_pay_amount_usd"
FROM LoginAccounts la
JOIN UserLoginStats ul
  ON la.user_id = ul.user_id
LEFT JOIN UserPaymentStats up
  ON la.user_id = up.user_id
WHERE COALESCE(up.total_pay_amount_usd, 0.0) = 0.0
  AND ul.last_user_login_date < CURRENT_DATE - INTERVAL '1' YEAR
  AND la.last_login_level < 10
ORDER BY
    la.user_id,
    la."#account_id";
