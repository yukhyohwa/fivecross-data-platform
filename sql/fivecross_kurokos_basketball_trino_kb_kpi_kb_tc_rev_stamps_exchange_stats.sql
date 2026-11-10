/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Stamps consumption analysis (Item Exchange).
Author: Antigravity
Created: 2026-01-26

Current Queries:
  - Analysis of items obtained by consuming Stamps (ID: 19000000, 10000000).
  - Results include Item Name, Total Amount Obtained, Stamps Consumed, and Player Count.

Notes:
  - Date range: 2026-01-05 to 2026-01-07.
  - Joins with dim_10_0_12928 for item names.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Filter Stamps Consumption Events
--------------------------------------------------------------------------------
StampsEvents AS (
    SELECT 
        "$part_date",
        "$part_event",
        gid,
        role_name,
        a_rst,
        ABS(
            REDUCE(
                FILTER(a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS stamps_consumed
    FROM ta.v_event_10
    WHERE "$part_date" BETWEEN '2026-01-05' AND '2026-01-07'
--AND "#event_time" >= timestamp '2026-02-05 11:30:01'
        AND ANY_MATCH(a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0)
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
        stamps_consumed,
        t.item_id AS obtained_item_id,
        t.item_diff AS obtained_amount
    FROM StampsEvents
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE CAST(t.item_id AS INTEGER) NOT IN (10000000, 19000000)
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
    SUM(stamps_consumed) AS total_stamps_consumed,
    COUNT(DISTINCT gid) AS total_player_count
FROM ItemsObtained s1 
LEFT JOIN ta_dim.dim_10_0_12928 s2 
    ON s1.obtained_item_id = s2."shop_item.item_id@shop_item_id"
GROUP BY 
    1, 2, 3
ORDER BY 
    total_stamps_consumed DESC;
