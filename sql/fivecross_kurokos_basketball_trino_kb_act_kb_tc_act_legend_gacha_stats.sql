/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Usage analysis for LG Character Gacha items.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - Usage (People, Times, Amount) for LG Kise, LG Akashi, and LG Hyuga.
  - Covers specific date ranges associated with each character event.

Notes:
  - Considers item consumption (diff < 0) as usage.
  - Date range: 2025-10-23 to 2025-12-26.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Explode Gacha Items
--------------------------------------------------------------------------------
ExplodedItems AS (
    SELECT 
        "#user_id",
        "#event_time",
        CAST(id AS BIGINT) AS item_id,
        CAST(diff AS BIGINT) AS item_diff
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE "$part_date" BETWEEN '2025-10-23' AND '2025-12-26'
        AND a_rst IS NOT NULL 
        AND CAST(id AS BIGINT) IN (90000637, 90000636, 90000659, 90000658, 90000684, 90000683)
)

--------------------------------------------------------------------------------
-- Section 2: Character Usage Aggregation
--------------------------------------------------------------------------------
-- 1. LG Kise (LG黃瀨)
SELECT 
    'LG黃瀨' AS character_name,
    COUNT(DISTINCT "#user_id") AS people_count,
    COUNT(*) AS person_times,
    SUM(ABS(item_diff)) AS usage_amount
FROM ExplodedItems
WHERE "#event_time" BETWEEN TIMESTAMP '2025-10-23 00:00:00' AND TIMESTAMP '2025-11-06 09:00:00'
    AND item_id IN (90000637, 90000636)
    AND item_diff < 0

UNION ALL

-- 2. LG Akashi (LG赤司)
SELECT 
    'LG赤司' AS character_name,
    COUNT(DISTINCT "#user_id") AS people_count,
    COUNT(*) AS person_times,
    SUM(ABS(item_diff)) AS usage_amount
FROM ExplodedItems
WHERE "#event_time" BETWEEN TIMESTAMP '2025-11-13 00:00:00' AND TIMESTAMP '2025-11-27 00:00:00'
    AND item_id IN (90000659, 90000658)
    AND item_diff < 0

UNION ALL

-- 3. LG Hyuga (LG日向)
SELECT 
    'LG日向' AS character_name,
    COUNT(DISTINCT "#user_id") AS people_count,
    COUNT(*) AS person_times,
    SUM(ABS(item_diff)) AS usage_amount
FROM ExplodedItems
WHERE "#event_time" BETWEEN TIMESTAMP '2025-12-11 00:00:00' AND TIMESTAMP '2025-12-25 09:00:00'
    AND item_id IN (90000684, 90000683)
    AND item_diff < 0;
