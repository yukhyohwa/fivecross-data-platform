/*
================================================================================
Game: Slam Dunk - GL
Description: Return-user KPI by selected day / week / month / all-period grain.
             Revenue is the valid purchase revenue within the selected reporting
             period, not revenue only on the user's return date.
Environment: Trino
Table: ta.v_event_21
================================================================================
*/

WITH
ScanConfig AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_21
    WHERE ${PartDate:date1}
),

UserProfile AS (
    SELECT
        "#varchar_id" AS "#account_id",
        CAST(MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS DATE) AS reg_date
    FROM user_result_cluster_21
    WHERE cluster_name = 'fixed_regdate'
    GROUP BY 1
),

UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_21
    WHERE cluster_name IN (
        'cohort_20231116_224917', 'cohort_waternew', 'is_water', 'internal_users'
    )
),

-- Login history starts 90 days before the reporting range so return status can
-- be determined for every day in the selected range.
UserDailyLogin AS (
    SELECT
        v."#account_id",
        CAST(v."$part_date" AS DATE) AS login_date
    FROM ta.v_event_21 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist b ON v."#account_id" = b."#account_id"
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(v."$part_date" AS DATE)
          BETWEEN DATE_ADD('day', -90, sc.target_start_date) AND sc.target_end_date
      AND b."#account_id" IS NULL
    GROUP BY 1, 2
),

ExchangeRates AS (
    SELECT ex_date, currency, MAX(exchange) AS exchange
    FROM ta_dim.ta_exchange
    GROUP BY 1, 2
),

-- This CTE is intentionally limited to the selected reporting range.
TargetPurchaseEvents AS (
    SELECT
        v."#account_id",
        CAST(v."$part_date" AS DATE) AS purchase_date,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)
            / NULLIF(fx.exchange, 0) * cny.exchange AS revenue_cny
    FROM ta.v_event_21 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist b ON v."#account_id" = b."#account_id"
    LEFT JOIN ExchangeRates fx
        ON v."$part_date" = fx.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = fx.currency
    LEFT JOIN ExchangeRates cny
        ON v."$part_date" = cny.ex_date AND cny.currency = 'CNY'
    WHERE v."$part_event" = 'PURCHASE'
      AND CAST(v."$part_date" AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND b."#account_id" IS NULL
),

TargetActiveUserDays AS (
    SELECT l."#account_id", l.login_date AS activity_date
    FROM UserDailyLogin l
    CROSS JOIN ScanConfig sc
    WHERE l.login_date BETWEEN sc.target_start_date AND sc.target_end_date

    UNION

    SELECT "#account_id", purchase_date
    FROM TargetPurchaseEvents
),

-- A return user is active today, was not registered today, and did not log in
-- during the preceding 90 days.
ReturnUserDays AS (
    SELECT a."#account_id", a.activity_date AS return_date
    FROM TargetActiveUserDays a
    LEFT JOIN UserProfile p ON a."#account_id" = p."#account_id"
    WHERE (p.reg_date IS NULL OR a.activity_date > p.reg_date)
      AND NOT EXISTS (
          SELECT 1
          FROM UserDailyLogin h
          WHERE h."#account_id" = a."#account_id"
            AND h.login_date BETWEEN DATE_ADD('day', -90, a.activity_date)
                                 AND DATE_ADD('day', -1, a.activity_date)
      )
),

-- Deduplicate to one account per selected reporting period.
ReturnUsersByPeriod AS (
    SELECT
        "#account_id",
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(return_date AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', return_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', return_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension
    FROM ReturnUserDays
    GROUP BY 1, 2
),

-- Revenue is independently periodized by purchase date, then joined to the
-- return-user population in the same period.
PurchaseRevenueByPeriod AS (
    SELECT
        "#account_id",
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(purchase_date AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', purchase_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', purchase_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        SUM(revenue_cny) AS revenue_cny
    FROM TargetPurchaseEvents
    GROUP BY 1, 2
)

SELECT
    r.time_dimension AS "时间维度",
    COUNT(DISTINCT r."#account_id") AS "回流用户数",
    COUNT(DISTINCT p."#account_id") AS "回流付费用户数",
    ROUND(
        CAST(COUNT(DISTINCT p."#account_id") AS DOUBLE)
        / NULLIF(COUNT(DISTINCT r."#account_id"), 0),
        4
    ) AS "回流用户付费率",
    ROUND(COALESCE(SUM(p.revenue_cny), 0), 2) AS "所选周期回流用户收入_CNY",
    ROUND(
        COALESCE(SUM(p.revenue_cny), 0)
        / NULLIF(COUNT(DISTINCT r."#account_id"), 0),
        2
    ) AS "回流用户ARPU_CNY",
    ROUND(
        COALESCE(SUM(p.revenue_cny), 0)
        / NULLIF(COUNT(DISTINCT p."#account_id"), 0),
        2
    ) AS "回流用户ARPPU_CNY"
FROM ReturnUsersByPeriod r
LEFT JOIN PurchaseRevenueByPeriod p
    ON r."#account_id" = p."#account_id"
   AND r.time_dimension = p.time_dimension
GROUP BY 1
ORDER BY 1 DESC;
