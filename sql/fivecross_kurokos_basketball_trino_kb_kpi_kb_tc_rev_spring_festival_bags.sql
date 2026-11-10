/*
================================================================================
Game: Kuroko's Basketball
Description: Spring Festival 2026 Lucky Bag Consumption Stats
Period: 2026-01-29 to 2026-02-22
Items: 
  - 1200674 (Big Lucky Bag)
  - 1200673 (Small Lucky Bag)
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: All Item Changes in the Spring Festival Period
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
    WHERE "$part_date" BETWEEN '2026-01-29' AND '2026-02-22'
),

--------------------------------------------------------------------------------
-- Section 2: Identify Purchase Events for Lucky Bags
--------------------------------------------------------------------------------
LuckyBagEvents AS (
    SELECT 
        "#user_id",
        "#event_time",
        CASE 
            WHEN item_id = 1200674 THEN '大福�?(1200674)'
            WHEN item_id = 1200673 THEN '小福�?(1200673)'
        END AS bag_type
    FROM AllItemChanges
    WHERE item_diff > 0 
      AND item_id IN (1200674, 1200673)
),

--------------------------------------------------------------------------------
-- Section 3: Aggregating Statistics
--------------------------------------------------------------------------------
GLStats AS (
    -- Total stamps consumed during the entire period
    SELECT 
        SUM(ABS(item_diff)) AS period_total_stamps
    FROM AllItemChanges
    WHERE item_id = 10000000 AND item_diff < 0
),

BagStats AS (
    -- Stats specifically for the Lucky Bag purchase events
    SELECT
        b.bag_type,
        COUNT(DISTINCT a."#user_id") AS user_count,
        SUM(ABS(a.item_diff)) AS bag_stamps_consumed
    FROM AllItemChanges a
    INNER JOIN LuckyBagEvents b 
        ON a."#user_id" = b."#user_id" 
        AND a."#event_time" = b."#event_time"
    WHERE a.item_id = 10000000 AND a.item_diff < 0
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- Section 4: Final Output
--------------------------------------------------------------------------------
SELECT
    b.bag_type AS "项目",
    b.user_count AS "购买人数",
    b.bag_stamps_consumed AS "消耗点券",
    g.period_total_stamps AS "期间总消耗点券",
    CAST(ROUND(b.bag_stamps_consumed * 100.0 / g.period_total_stamps, 2) AS VARCHAR) || '%' AS "消耗占总点券比"
FROM BagStats b
CROSS JOIN GLStats g

UNION ALL

-- Add a Total Row for both bags
SELECT
    '合计 (总计)' AS "项目",
    COUNT(DISTINCT a."#user_id") AS "购买人数",
    SUM(ABS(a.item_diff)) AS "消耗点券",
    MAX(g.period_total_stamps) AS "期间总消耗点券",
    CAST(ROUND(SUM(ABS(a.item_diff)) * 100.0 / MAX(g.period_total_stamps), 2) AS VARCHAR) || '%' AS "消耗占总点券比"
FROM AllItemChanges a
INNER JOIN LuckyBagEvents b 
    ON a."#user_id" = b."#user_id" 
    AND a."#event_time" = b."#event_time"
CROSS JOIN GLStats g
WHERE a.item_id = 10000000 AND a.item_diff < 0
GROUP BY 1;
