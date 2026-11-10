/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Track holders of specific Item IDs.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - List of players who obtained a specific item within a date range.
  - Metrics include Diff, Before, and After amounts.

Notes:
  - Default Item ID: 3100367.
  - Date Range: 2026-01-05 to 2026-01-12.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Parse Item Change Data
--------------------------------------------------------------------------------
ParsedData AS (
    SELECT 
        gid,
        role_name,
        t.item_id,
        t.item_before,
        t.item_diff,
        t.item_after,
        t.item_key
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE "$part_date" BETWEEN '2026-01-05' AND '2026-01-12'
)

--------------------------------------------------------------------------------
-- Section 2: Final Output and Filtering
--------------------------------------------------------------------------------
SELECT DISTINCT
    gid,
    role_name,
    item_id,
    item_diff AS diff_amount,
    item_before AS before_amount,
    item_after AS after_amount,
    item_key
FROM ParsedData
WHERE CAST(item_id AS INTEGER) = 3100367
    AND item_diff > 0
ORDER BY 
    gid;
