/*
================================================================================
Game: Kuroko's Basketball
Description: Spring Festival Fortune Gacha (春节运势扭蛋) Stats
Period: 2026-02-09 to 2026-02-22
Gacha ID: 186
Item Obtained: Submarine Ball (海底�?- 50201036)
Currency: Stamps (点券 - 10000000)
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Raw Item Changes in the period
--------------------------------------------------------------------------------
AllItemChanges AS (
    SELECT 
        "$part_date",
        "#user_id",
        "#event_time",
        "#event_name",
        spring_gacha_type,
        CAST(id AS BIGINT) AS item_id,
        CAST(diff AS BIGINT) AS item_diff
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE "$part_date" BETWEEN '2026-02-09' AND '2026-02-22'
),

--------------------------------------------------------------------------------
-- Section 2: Identify Stamp Cost for the Gacha Coin (3100398)
-- We find events where users GAINED the gacha coin and check STAMPS lost in those events.
--------------------------------------------------------------------------------
CoinPurchaseStamps AS (
    SELECT
        SUM(ABS(i.item_diff)) AS total_stamps_spent_on_coins
    FROM AllItemChanges i
    INNER JOIN (
        SELECT DISTINCT "#user_id", "#event_time"
        FROM AllItemChanges
        WHERE item_id = 3100398 AND item_diff > 0 -- Gained the Lottery Coin
    ) p ON i."#user_id" = p."#user_id" AND i."#event_time" = p."#event_time"
    WHERE i.item_id = 10000000 AND i.item_diff < 0 -- Stamps lost in the same purchase pulse
),

--------------------------------------------------------------------------------
-- Section 3: Gacha Action Stats (ID 186)
--------------------------------------------------------------------------------
GachaStats AS (
    SELECT
        COUNT(DISTINCT "#user_id") AS user_count,
        SUM(CASE WHEN item_id = 50201036 AND item_diff > 0 THEN item_diff ELSE 0 END) AS ball_obtained_count,
        SUM(CASE WHEN item_id = 3100398 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS coins_consumed
    FROM AllItemChanges
    WHERE spring_gacha_type = 186
),

--------------------------------------------------------------------------------
-- Section 4: Periodic Totals for Ratio calculation
--------------------------------------------------------------------------------
GLStats AS (
    SELECT 
        SUM(ABS(item_diff)) AS total_period_stamps
    FROM AllItemChanges
    WHERE item_id = 10000000 AND item_diff < 0
)

--------------------------------------------------------------------------------
-- Section 5: Final Output
--------------------------------------------------------------------------------
SELECT
    '春节运势扭蛋 (ID 186)' AS "项目",
    s.user_count AS "参与人数",
    s.coins_consumed AS "消耗抽奖币(3100398)",
    s.ball_obtained_count AS "产出海底(50201036)",
    cp.total_stamps_spent_on_coins AS "对应的点券消耗",
    g.total_period_stamps AS "期间全服总点券消耗",
    CASE 
        WHEN g.total_period_stamps > 0 
        THEN CAST(ROUND(cp.total_stamps_spent_on_coins * 100.0 / g.total_period_stamps, 2) AS VARCHAR) || '%' 
        ELSE '0.00%' 
    END AS "点券消耗占比"
FROM GachaStats s
CROSS JOIN CoinPurchaseStamps cp
CROSS JOIN GLStats g;
