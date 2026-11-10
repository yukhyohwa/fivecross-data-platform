/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Diamond consumption analysis (Item Exchange).
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - Analysis of items obtained by consuming Diamonds (ID: 10000003).
  - Results include Item Name, Total Amount Obtained, Diamonds Consumed, and Player Count.

Notes:
  - Date range: 2026-01-05 to 2026-01-07.
  - Joins with dim_10_0_12928 for item names.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Filter Diamond Consumption Events
--------------------------------------------------------------------------------
DiamondEvents AS (
    SELECT 
        "$part_date",
        "$part_event",
        gid,
        role_name,
        a_rst,
        ABS(
            REDUCE(
                FILTER(a_rst, x -> CAST(x.id AS INTEGER) = 10000003 AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS diamond_consumed
    FROM ta.v_event_10
    WHERE "$part_date" BETWEEN '2026-01-05' AND '2026-01-07'
        AND ANY_MATCH(a_rst, x -> CAST(x.id AS INTEGER) = 10000003 AND x.diff < 0)
),

--------------------------------------------------------------------------------
-- Section 2: Explode Obtained Items
--------------------------------------------------------------------------------
ItemsObtained AS (
    SELECT 
        "$part_date",
        "$part_event",
        gid,
        role_name,
        diamond_consumed,
        t.item_id AS obtained_item_id,
        t.item_diff AS obtained_amount
    FROM DiamondEvents
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE CAST(t.item_id AS INTEGER) != 10000003
        AND t.item_diff > 0
)

--------------------------------------------------------------------------------
-- Section 3: Final Output and Aggregation
--------------------------------------------------------------------------------
SELECT 
    "$part_date" AS part_date,
    obtained_item_id AS item_id,
    "shop_item.item_id@name" AS item_name,
    SUM(obtained_amount) AS total_obtained_amount,
    SUM(diamond_consumed) AS total_diamond_consumed,
    COUNT(DISTINCT gid) AS total_player_count
FROM ItemsObtained s1 
LEFT JOIN ta_dim.dim_10_0_12928 s2 
    ON s1.obtained_item_id = s2."shop_item.item_id@shop_item_id"
GROUP BY 
    1, 2, 3
ORDER BY 
    total_diamond_consumed DESC;
