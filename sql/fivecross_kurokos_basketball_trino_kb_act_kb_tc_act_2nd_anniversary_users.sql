/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Track users who gained 2nd Anniversary Coins.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - Count of players who gained 4 or more 2nd Anniversary Coins (ID: 3100381).

Notes:
  - Date range: 2026-01-15 to 2026-01-18 (Start time 10:00:00).
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Aggregate Item Gains
--------------------------------------------------------------------------------
ItemGains AS (
    SELECT
        gid,
        SUM(t.item_diff) AS total_gain
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE "$part_date" BETWEEN '2026-01-15' AND '2026-01-18'
        AND "#event_time" >= TIMESTAMP '2026-01-15 10:00:00'
        AND CAST(t.item_id AS INTEGER) = 3100381
        AND t.item_diff > 0
    GROUP BY
        gid
)

--------------------------------------------------------------------------------
-- Section 2: Final Count Filter
--------------------------------------------------------------------------------
SELECT
    COUNT(DISTINCT gid) AS player_count
FROM ItemGains
WHERE total_gain >= 4;