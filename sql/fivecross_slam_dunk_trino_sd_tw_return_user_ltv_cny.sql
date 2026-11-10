/*
===============================================================================
Game: Slam Dunk TC
Description: 90-day return-user daily KPI and LTV in CNY.

Definitions:
- Return user: active on the day and has no login on D-90 through D-1.
- New users (activity date = registration date) are excluded from return users.
- Return revenue / LTV cohort keeps the validated purchase-based classification.
- LTV1 = D0; LTV2 = D0-D1; ...; LTV30 = D0-D29.
===============================================================================
*/

WITH
ScanConfig AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_20
    WHERE ${PartDate:date1}
      AND "$part_event" = 'PURCHASE'
),

UserProfile AS (
    SELECT
        "#varchar_id" AS "#account_id",
        CAST(
            MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END)
            AS DATE
        ) AS reg_date
    FROM user_result_cluster_20
    WHERE cluster_name = 'fixed_regdate'
    GROUP BY 1
),

UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_20
    WHERE cluster_name IN (
        'cohort_20231116_224917',
        'cohort_waternew',
        'is_water',
        'internal_users'
    )
),

-- Login history used to determine whether users were active in the prior 90 days.
UserDailyLogin AS (
    SELECT
        v."#account_id",
        CAST(v."$part_date" AS DATE) AS login_date
    FROM ta.v_event_20 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub
        ON v."#account_id" = ub."#account_id"
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(v."$part_date" AS DATE)
          BETWEEN DATE_ADD('day', -90, sc.target_start_date)
              AND sc.target_end_date
      AND ub."#account_id" IS NULL
    GROUP BY 1, 2
),

-- Deduplicate exchange-rate rows to prevent revenue multiplication on joins.
ExchangeRates AS (
    SELECT
        ex_date,
        currency,
        MAX(exchange) AS exchange
    FROM ta_dim.ta_exchange
    GROUP BY 1, 2
),

-- CNY revenue = source-currency amount / source-currency exchange * CNY exchange.
AllPurchaseEvents AS (
    SELECT
        v."#account_id",
        CAST(v."$part_date" AS DATE) AS purchase_date,
        CAST(
            JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt')
            AS DOUBLE
        ) / NULLIF(s5.exchange, 0) * s_cny.exchange AS revenue_cny
    FROM ta.v_event_20 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub
        ON v."#account_id" = ub."#account_id"
    LEFT JOIN ExchangeRates s5
        ON v."$part_date" = s5.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ExchangeRates s_cny
        ON v."$part_date" = s_cny.ex_date
       AND s_cny.currency = 'CNY'
    WHERE v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype')
          <> 'SANDBOX_RECEIPT'
      AND CAST(v."$part_date" AS DATE)
          BETWEEN sc.target_start_date
              AND DATE_ADD('day', 29, sc.target_end_date)
      AND ub."#account_id" IS NULL
),

TargetPurchaseEvents AS (
    SELECT p.*
    FROM AllPurchaseEvents p
    CROSS JOIN ScanConfig sc
    WHERE p.purchase_date BETWEEN sc.target_start_date AND sc.target_end_date
),

-- Users who logged in during D-90 through D-1 are old users on the purchase day.
UsersWithLoginInPrevious90Days AS (
    SELECT DISTINCT
        p."#account_id",
        p.purchase_date
    FROM TargetPurchaseEvents p
    INNER JOIN UserDailyLogin l
        ON p."#account_id" = l."#account_id"
       AND l.login_date BETWEEN DATE_ADD('day', -90, p.purchase_date)
                            AND DATE_ADD('day', -1, p.purchase_date)
),

-- Preserve the established daily revenue classification.
PurchaseClassification AS (
    SELECT
        p."#account_id",
        p.purchase_date,
        p.revenue_cny,
        CASE
            WHEN up.reg_date = p.purchase_date THEN 'new_user'
            WHEN old."#account_id" IS NOT NULL THEN 'old_user'
            ELSE 'return_user'
        END AS user_type
    FROM TargetPurchaseEvents p
    LEFT JOIN UserProfile up
        ON p."#account_id" = up."#account_id"
    LEFT JOIN UsersWithLoginInPrevious90Days old
        ON p."#account_id" = old."#account_id"
       AND p.purchase_date = old.purchase_date
),

-- The validated cohort used for return revenue and LTV: return-classified payers.
ReturnCohorts AS (
    SELECT DISTINCT
        "#account_id",
        purchase_date AS return_date
    FROM PurchaseClassification
    WHERE user_type = 'return_user'
),

-- A user is active if they logged in or made a valid purchase on the date.
TargetActiveUserDays AS (
    SELECT
        l."#account_id",
        l.login_date AS activity_date
    FROM UserDailyLogin l
    CROSS JOIN ScanConfig sc
    WHERE l.login_date BETWEEN sc.target_start_date AND sc.target_end_date

    UNION

    SELECT
        p."#account_id",
        p.purchase_date AS activity_date
    FROM TargetPurchaseEvents p
),

-- All return users, used as the denominator for pay rate, ARPU, and LTV.
ReturnUserDays AS (
    SELECT
        a."#account_id",
        a.activity_date AS return_date
    FROM TargetActiveUserDays a
    LEFT JOIN UserProfile up
        ON a."#account_id" = up."#account_id"
    WHERE (up.reg_date IS NULL OR a.activity_date > up.reg_date)
      AND NOT EXISTS (
          SELECT 1
          FROM UserDailyLogin hist
          WHERE hist."#account_id" = a."#account_id"
            AND hist.login_date BETWEEN DATE_ADD('day', -90, a.activity_date)
                                    AND DATE_ADD('day', -1, a.activity_date)
      )
),

ReturnLtv AS (
    SELECT
        rc."#account_id",
        rc.return_date,

        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 1
                 THEN p.revenue_cny ELSE 0 END) AS revenue_1,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 2
                 THEN p.revenue_cny ELSE 0 END) AS revenue_2,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 3
                 THEN p.revenue_cny ELSE 0 END) AS revenue_3,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 4
                 THEN p.revenue_cny ELSE 0 END) AS revenue_4,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 5
                 THEN p.revenue_cny ELSE 0 END) AS revenue_5,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 6
                 THEN p.revenue_cny ELSE 0 END) AS revenue_6,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 7
                 THEN p.revenue_cny ELSE 0 END) AS revenue_7,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 14
                 THEN p.revenue_cny ELSE 0 END) AS revenue_14,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 21
                 THEN p.revenue_cny ELSE 0 END) AS revenue_21,
        SUM(CASE WHEN DATE_DIFF('day', rc.return_date, p.purchase_date) < 30
                 THEN p.revenue_cny ELSE 0 END) AS revenue_30
    FROM ReturnCohorts rc
    LEFT JOIN AllPurchaseEvents p
        ON rc."#account_id" = p."#account_id"
       AND p.purchase_date BETWEEN rc.return_date
                               AND DATE_ADD('day', 29, rc.return_date)
    GROUP BY 1, 2
)

SELECT
    CAST(ru.return_date AS VARCHAR) AS "回流日期",
    COUNT(DISTINCT ru."#account_id") AS "回流用户数",
    COUNT(DISTINCT rc."#account_id") AS "回流付费用户数",

    ROUND(
        CAST(COUNT(DISTINCT rc."#account_id") AS DOUBLE)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0),
        4
    ) AS "回流用户付费率",

    ROUND(COALESCE(SUM(ltv.revenue_1), 0), 2) AS "回流当天收入CNY",

    ROUND(
        COALESCE(SUM(ltv.revenue_1), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0),
        2
    ) AS "回流用户ARPU_CNY",

    ROUND(
        COALESCE(SUM(ltv.revenue_1), 0)
        / NULLIF(COUNT(DISTINCT rc."#account_id"), 0),
        2
    ) AS "回流用户ARPPU_CNY",

    ROUND(COALESCE(SUM(ltv.revenue_1), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV1_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_2), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV2_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_3), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV3_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_4), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV4_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_5), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV5_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_6), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV6_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_7), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV7_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_14), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV14_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_21), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV21_CNY",
    ROUND(COALESCE(SUM(ltv.revenue_30), 0)
        / NULLIF(COUNT(DISTINCT ru."#account_id"), 0), 2) AS "LTV30_CNY"

FROM ReturnUserDays ru
LEFT JOIN ReturnCohorts rc
    ON ru."#account_id" = rc."#account_id"
   AND ru.return_date = rc.return_date
LEFT JOIN ReturnLtv ltv
    ON rc."#account_id" = ltv."#account_id"
   AND rc.return_date = ltv.return_date
GROUP BY 1
ORDER BY 1 DESC;
