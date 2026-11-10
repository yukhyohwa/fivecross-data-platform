/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: User list of Unpaid users with high Diamond inventory.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - List of Unpaid users with Diamonds > 100,000 based on Dec snapshot.
  - Metrics include Nov and Dec Diamond inventory.

Notes:
  - Cumulative revenue calculation starts from 2025-06-01.
  - Excludes blacklisted users (UserBlacklist).
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Blacklist Logic
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 2: User Revenue Calculation (USD)
--------------------------------------------------------------------------------
UserRevenue AS (
    SELECT 
        gid,
        SUM(CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('srcoin_buy'))
            )
            THEN s1.pay_amount / COALESCE(ex.exchange, 1)
            ELSE 0 
        END) AS revenue_usd
    FROM ta.v_event_10 s1
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    LEFT JOIN UserBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" >= '2025-06-01'
        AND b."#user_id" IS NULL
        AND (
            (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
            OR (s1."$part_event" IN ('srcoin_buy'))
        )
        AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
    GROUP BY 
        1
),

--------------------------------------------------------------------------------
-- Section 3: Monthly Snapshots (Nov & Dec)
--------------------------------------------------------------------------------
MonthlySnapshots AS (
    SELECT
        gid,
        MAX(CASE WHEN month_str = '2025-11' THEN diamond END) AS nov_diamond,
        MAX(CASE WHEN month_str = '2025-12' THEN diamond END) AS dec_diamond
    FROM (
        SELECT 
            gid,
            diamond,
            SUBSTR("$part_date", 1, 7) AS month_str,
            ROW_NUMBER() OVER (PARTITION BY gid, SUBSTR("$part_date", 1, 7) ORDER BY "#event_time" DESC) AS rn
        FROM ta.v_event_10
        WHERE "$part_date" BETWEEN '2025-11-01' AND '2025-12-31'
            AND "$part_event" IN ('login')
    )
    WHERE rn = 1
    GROUP BY 
        1
),

--------------------------------------------------------------------------------
-- Section 4: Segment Users and Filter Unpaid
--------------------------------------------------------------------------------
UserTiers AS (
    SELECT 
        s.gid,
        COALESCE(r.revenue_usd, 0) AS revenue_usd,
        CASE 
            WHEN (COALESCE(r.revenue_usd, 0) * 31.36) BETWEEN 1 AND 5000 THEN '1. 1~5,000 TWD'
            WHEN (COALESCE(r.revenue_usd, 0) * 31.36) BETWEEN 5001 AND 20000 THEN '2. 5,001~20,000 TWD'
            WHEN (COALESCE(r.revenue_usd, 0) * 31.36) > 20000 THEN '3. 20,000+ TWD'
            ELSE '0. Unpaid'
        END AS tier,
        s.nov_diamond,
        s.dec_diamond
    FROM MonthlySnapshots s
    LEFT JOIN UserRevenue r ON s.gid = r.gid
)

--------------------------------------------------------------------------------
-- Section 5: Final Output (High Diamond Unpaid Users)
--------------------------------------------------------------------------------
SELECT 
    gid,
    tier,
    nov_diamond AS "11月钻石",
    dec_diamond AS "12月钻石"
FROM UserTiers
WHERE tier = '0. Unpaid'
    AND dec_diamond > 100000
ORDER BY 
    dec_diamond DESC;
