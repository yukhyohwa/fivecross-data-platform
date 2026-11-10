/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Analysis of LG Character Spring Gacha events.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  - Statistics split by Type (Training vs Awakening) and Total.
  - Metrics include People, Times, and Ticket Consumption.

Notes:
  - Date range: 2025-10-23 to 2025-12-26.
  - Character contexts: LG Kise, LG Akashi, LG Hyuga.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Event Level Stats (People & Times)
--------------------------------------------------------------------------------
EventStats AS (
    SELECT 
        CASE 
            WHEN spring_gacha_type IN (160, 159) THEN 'LG黃瀨 (10/23-11/06)'
            WHEN spring_gacha_type IN (168, 167) THEN 'LG赤司 (11/13-11/27)'
            WHEN spring_gacha_type IN (176, 175) THEN 'LG日向 (12/11-12/25)'
            ELSE 'Other'
        END AS event_name,
        
        -- Total
        COUNT(DISTINCT "#user_id") AS total_people,
        SUM(spring_gacha_times) AS total_times,
        
        -- Training (特训) - IDs: 160, 168, 176
        COUNT(DISTINCT CASE WHEN spring_gacha_type IN (160, 168, 176) THEN "#user_id" END) AS training_people,
        SUM(CASE WHEN spring_gacha_type IN (160, 168, 176) THEN spring_gacha_times ELSE 0 END) AS training_times,
        
        -- Awakening (觉醒) - IDs: 159, 167, 175
        COUNT(DISTINCT CASE WHEN spring_gacha_type IN (159, 167, 175) THEN "#user_id" END) AS awakening_people,
        SUM(CASE WHEN spring_gacha_type IN (159, 167, 175) THEN spring_gacha_times ELSE 0 END) AS awakening_times
    FROM ta.v_event_10
    WHERE "$part_date" BETWEEN '2025-10-23' AND '2025-12-26'
        AND "$part_event" = 'gacha_spring'
        AND spring_gacha_type IN (160, 159, 168, 167, 176, 175)
    GROUP BY 
        1
),

--------------------------------------------------------------------------------
-- Section 2: Ticket Consumption Stats
--------------------------------------------------------------------------------
ItemStats AS (
    SELECT 
        CASE 
            WHEN spring_gacha_type IN (160, 159) THEN 'LG黃瀨 (10/23-11/06)'
            WHEN spring_gacha_type IN (168, 167) THEN 'LG赤司 (11/13-11/27)'
            WHEN spring_gacha_type IN (176, 175) THEN 'LG日向 (12/11-12/25)'
        END AS event_name,
        -- Training Tickets
        SUM(CASE WHEN CAST(id AS BIGINT) IN (3100316, 3100331, 3100349) AND CAST(diff AS BIGINT) < 0 THEN ABS(CAST(diff AS BIGINT)) ELSE 0 END) AS training_ticket_consumed,
        -- Awakening Tickets
        SUM(CASE WHEN CAST(id AS BIGINT) IN (3100317, 3100332, 3100350) AND CAST(diff AS BIGINT) < 0 THEN ABS(CAST(diff AS BIGINT)) ELSE 0 END) AS awakening_ticket_consumed
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE "$part_date" BETWEEN '2025-10-23' AND '2025-12-26'
        AND "$part_event" = 'gacha_spring'
        AND spring_gacha_type IN (160, 159, 168, 167, 176, 175)
    GROUP BY 
        1
)

--------------------------------------------------------------------------------
-- Section 3: Final Combined Output
--------------------------------------------------------------------------------
SELECT 
    e.event_name AS "活动名称",
    
    -- Summary
    e.total_people AS "总人数 (去重)",
    e.total_times AS "总次数",
    
    -- Training
    e.training_people AS "特训人数",
    e.training_times AS "特训次数",
    i.training_ticket_consumed AS "特训扭蛋消耗",
    
    -- Awakening
    e.awakening_people AS "觉醒人数",
    e.awakening_times AS "觉醒次数",
    i.awakening_ticket_consumed AS "觉醒扭蛋消耗"
FROM EventStats e
LEFT JOIN ItemStats i ON e.event_name = i.event_name
ORDER BY 
    1;
