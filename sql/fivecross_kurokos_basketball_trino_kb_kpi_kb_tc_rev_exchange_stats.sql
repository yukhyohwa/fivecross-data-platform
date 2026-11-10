/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Daily exchange consumption ratio for LG events.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - Proportion of Diamonds/Stamps consumed for Target Items (Tickets) vs Total Daily Consumption.

Notes:
  - Target items include Training and Awakening Tickets.
  - Event periods are hardcoded for LG Character events.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Explode all item changes
--------------------------------------------------------------------------------
AllItemChanges AS (
    SELECT 
        "$part_date",
        "#user_id",
        "#event_time",
        "#event_name",
        CAST(id AS BIGINT) AS item_id,
        CAST(diff AS BIGINT) AS item_diff
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE "$part_date" BETWEEN '2025-10-23' AND '2025-12-26'
),

--------------------------------------------------------------------------------
-- Section 2: Identify Exchange Events (Obtaining Target Items)
--------------------------------------------------------------------------------
TargetExchangeEvents AS (
    SELECT DISTINCT
        "#user_id",
        "#event_time"
    FROM AllItemChanges
    WHERE item_diff > 0
        AND item_id IN (
            3100316, 3100331, 3100349, -- Training Tickets
            3100317, 3100332, 3100350  -- Awakening Tickets
        )
),

--------------------------------------------------------------------------------
-- Section 3: Daily Consumption Calculation
--------------------------------------------------------------------------------
DailyStats AS (
    SELECT
        a."$part_date",
        
        -- Event Categorization
        CASE 
            WHEN a."$part_date" BETWEEN '2025-10-23' AND '2025-11-06' THEN 'LG黃瀨 (10/23-11/06)'
            WHEN a."$part_date" BETWEEN '2025-11-13' AND '2025-11-27' THEN 'LG赤司 (11/13-11/27)'
            WHEN a."$part_date" BETWEEN '2025-12-11' AND '2025-12-25' THEN 'LG日向 (12/11-12/25)'
            ELSE 'Other'
        END AS event_period,

        -- Total Consumption
        SUM(CASE WHEN item_id = 10000000 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS total_stamps_consumed,
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS total_diamonds_consumed,

        -- Target Consumption (Only events that gained Target Items)
        SUM(CASE 
            WHEN t."#event_time" IS NOT NULL AND item_id = 10000000 AND item_diff < 0 
            THEN ABS(item_diff) 
            ELSE 0 
        END) AS target_stamps_consumed,
        
        SUM(CASE 
            WHEN t."#event_time" IS NOT NULL AND item_id = 10000003 AND item_diff < 0 
            THEN ABS(item_diff) 
            ELSE 0 
        END) AS target_diamonds_consumed
    FROM AllItemChanges a
    LEFT JOIN TargetExchangeEvents t 
        ON a."#user_id" = t."#user_id" 
        AND a."#event_time" = t."#event_time"
    GROUP BY 
        1, 2
)

--------------------------------------------------------------------------------
-- Section 4: Final Ratio Calculation
--------------------------------------------------------------------------------
SELECT
    "$part_date" AS "日期",
    event_period AS "活动区间",
    
    -- Stamps (10000000)
    target_stamps_consumed AS "兑换消耗点券",
    total_stamps_consumed AS "当日总消耗点券",
    CASE 
        WHEN total_stamps_consumed > 0 THEN CAST(ROUND(target_stamps_consumed * 100.0 / total_stamps_consumed, 2) AS VARCHAR) || '%' 
        ELSE '0.00%' 
    END AS "点券消耗占比",

    -- Diamonds (10000003)
    target_diamonds_consumed AS "兑换消耗钻石",
    total_diamonds_consumed AS "当日总消耗钻石",
    CASE 
        WHEN total_diamonds_consumed > 0 THEN CAST(ROUND(target_diamonds_consumed * 100.0 / total_diamonds_consumed, 2) AS VARCHAR) || '%' 
        ELSE '0.00%' 
    END AS "钻石消耗占比"
FROM DailyStats
WHERE event_period <> 'Other'
ORDER BY 
    "$part_date";
