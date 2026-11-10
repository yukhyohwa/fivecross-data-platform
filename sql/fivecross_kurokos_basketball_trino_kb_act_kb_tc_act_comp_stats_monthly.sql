/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Monthly KPI report including MAU, Retention, and Revenue.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - MAU and New User Count.
  - Old User Count and Monthly Retention Proportion.
  - Total Revenue (USD) and New User Revenue (USD).

Notes:
  - Uses Device-based registration month for New User identification.
  - Excludes blacklisted users (UserBlacklist).
  - Date Range: 2025-01 to 2025-11.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Blacklist Logic
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 2: User Registration Month Mapping (Device-based)
--------------------------------------------------------------------------------
-- 2.1 Find first appearance month for each device
DeviceFirstSeen AS (
    SELECT 
        "#device_id",
        SUBSTR(MIN("$part_date"), 1, 7) AS dev_reg_month
    FROM ta.v_event_10
    WHERE "$part_date" >= '2020-01-01'
        AND "#event_name" = 'login'
        AND "#device_id" IS NOT NULL
    GROUP BY 
        1
),

-- 2.2 Find first device used by each user
UserFirstDevice AS (
    SELECT 
        "#user_id",
        (ARRAY_AGG("#device_id" ORDER BY "#event_time" ASC))[1] AS first_device_id
    FROM ta.v_event_10
    WHERE "$part_date" >= '2020-01-01'
        AND "#event_name" = 'login'
        AND "#device_id" IS NOT NULL
    GROUP BY 
        1
),

-- 2.3 Final Mapping: UserID -> Registration Month
UserRefMonth AS (
    SELECT 
        u."#user_id",
        d.dev_reg_month
    FROM UserFirstDevice u
    INNER JOIN DeviceFirstSeen d ON u.first_device_id = d."#device_id"
),

--------------------------------------------------------------------------------
-- Section 3: Monthly Statistics Aggregation
--------------------------------------------------------------------------------
MonthlyStats AS (
    SELECT 
        SUBSTR(s1."$part_date", 1, 7) AS data_month,
        
        -- MAU
        COUNT(DISTINCT CASE WHEN s1."$part_event" = 'login' THEN s1."#device_id" END) AS mau,
        
        -- New User Count
        COUNT(DISTINCT CASE 
            WHEN s1."$part_event" = 'login' AND u.dev_reg_month = SUBSTR(s1."$part_date", 1, 7)
            THEN s1."#device_id"
        END) AS new_users_count,
        
        -- Total Revenue (USD)
        SUM(CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            )
            THEN s1.pay_amount / COALESCE(ex.exchange, 1)
            ELSE 0 
        END) AS total_revenue_usd,

        -- New User Revenue (USD)
        SUM(CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('scroin_buy', 'srcoin_buy'))
            ) 
            AND u.dev_reg_month = SUBSTR(s1."$part_date", 1, 7)
            THEN s1.pay_amount / COALESCE(ex.exchange, 1)
            ELSE 0 
        END) AS new_user_revenue_usd
    FROM ta.v_event_10 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    LEFT JOIN UserRefMonth u ON s1."#user_id" = u."#user_id"
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_date" BETWEEN '2024-12-01' AND '2025-11-30'
        AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
        AND b."#user_id" IS NULL 
        AND s1."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy') 
    GROUP BY 
        1
),

--------------------------------------------------------------------------------
-- Section 4: Metrics Calculation
--------------------------------------------------------------------------------
CalculatedMetrics AS (
    SELECT 
        data_month,
        mau,
        new_users_count,
        mau - new_users_count AS old_users_count,
        LAG(mau, 1) OVER (ORDER BY data_month) AS prev_month_mau,
        total_revenue_usd,
        new_user_revenue_usd
    FROM MonthlyStats
)

--------------------------------------------------------------------------------
-- Section 5: Final Output
--------------------------------------------------------------------------------
SELECT 
    data_month AS "月份",
    mau AS "当月MAU",
    prev_month_mau AS "上月MAU",
    old_users_count AS "当月老设备数",
    CASE 
        WHEN prev_month_mau > 0 THEN CAST(ROUND(old_users_count * 100.0 / prev_month_mau, 2) AS VARCHAR) || '%'
        ELSE '0%' 
    END AS "月留存比例(老设备/上月MAU)",
    ROUND(total_revenue_usd, 2) AS "当月总流水(USD)",
    ROUND(new_user_revenue_usd, 2) AS "新增设备流水(USD)"
FROM CalculatedMetrics
WHERE data_month BETWEEN '2025-01' AND '2025-11'
ORDER BY 
    data_month;
