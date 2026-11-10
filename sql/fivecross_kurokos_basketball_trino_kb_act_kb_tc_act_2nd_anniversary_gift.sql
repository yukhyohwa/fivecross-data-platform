/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: TC (Traditional Chinese)
Description: Track trigger counts for 2nd Anniversary Check-in Gift (1200658).
Period: 2026-01-22 ~ 2026-01-25
================================================================================
*/

-- 這段期間，每日觸發 2週年簽到禮包(1200658)獲取的次數。

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
    WHERE "$part_date" BETWEEN '2026-01-22' AND '2026-01-25'
),

--------------------------------------------------------------------------------
-- Section 2: Identify Exchange Events (Obtaining Target Items)
--------------------------------------------------------------------------------
TargetExchangeEvents AS (
    SELECT DISTINCT
        "#user_id",
        "#event_time",
        item_id,
        item_diff
    FROM AllItemChanges
    WHERE item_diff > 0
        AND item_id IN (
            1200658  -- 2週年簽到禮包
        )
)

SELECT 
    item_id,
    SUM(item_diff) as "item_count",
    COUNT(DISTINCT "#user_id") as "user_count",
    COUNT(1) as "event_count"
FROM TargetExchangeEvents
GROUP BY 1;
