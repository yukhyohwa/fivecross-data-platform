-- Query to find dena_id (did) by matching Game User ID -> Order IDs -> Platform LCM_ID
-- Useful when User ID in game logs is encrypted/obfuscated.
-- Game: Saint Seiya 2 (g23000113)

WITH 
-- 1. Get all Order IDs for the specific game user from BI logs
GameOrders AS (
    SELECT DISTINCT order_id
    FROM g23000113.bi_order_logs
    WHERE day >= 20140101 
      AND user_id = '285787123888037'
),

-- 2. Match these Order IDs in the platform purchase table to find the standard lcm_id
FoundLcm AS (
    SELECT DISTINCT lcm_id, order_id
    FROM dm_platform.daily_lcx_user_purchase
    WHERE app_id = '23000113'
      AND day >= 20140101
      AND order_id IN (SELECT order_id FROM GameOrders)
)

-- 3. Join with user_info to get the final dena_id (did)
SELECT 
    u.did,
    u.dena_id,
    f.lcm_id,
    f.order_id,
    u.reg_day
FROM FoundLcm f
JOIN (
    SELECT did,dena_id, lcm_id, reg_day
    FROM dm_platform.lcx_user_info 
    WHERE app_id = '23000113' 
      AND day >= 20140101 -- Specified partition to avoid full table scan error
) u ON f.lcm_id = u.lcm_id;
