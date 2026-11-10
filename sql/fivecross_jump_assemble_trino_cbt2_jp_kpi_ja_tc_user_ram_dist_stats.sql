/*
================================================================================
Game: Jump Assemble (JA)
Region: TC (Traditional Chinese)
Description: Player Distribution by RAM Size (Memory) - Detailed for Low-end
Environment: Trino
Table: ta.v_event_16
================================================================================
*/

/*
================================================================================
Game: Jump Assemble (JA)
Region: TC (Traditional Chinese)
Description: Player Distribution by RAM Size (Memory) - Detailed for Low-end
Environment: Trino
Table: ta.v_event_16
================================================================================
*/

WITH ram_raw AS (
    -- 1. Extract numeric RAM value and map to standardized categories
  SELECT 
        COALESCE(lcx_id,lcxsdkcommon.lcx_id) lcx_id,
        CASE 
            WHEN v = 0 THEN '1GB'
            WHEN v = 1 THEN '2GB'
            WHEN v = 2 THEN '3GB'
            WHEN v = 3 THEN '4GB'
            WHEN v <= 5 THEN '6GB'     -- Covers 4, 5
            WHEN v <= 7 THEN '8GB'     -- Covers 6, 7
            WHEN v <= 11 THEN '12GB'   -- Covers 8, 9, 10, 11
            WHEN v <= 15 THEN '16GB'   -- Covers 12, 13, 14, 15
            WHEN v >= 16 THEN '16GB+'
            ELSE 'Unknown'
        END AS ram_category,
        -- Use the highest RAM value detected as the user's primary device category
        ROW_NUMBER() OVER(PARTITION BY COALESCE(lcx_id,lcxsdkcommon.lcx_id) ORDER BY v DESC) as device_rank
    FROM ta.v_event_16
    CROSS JOIN LATERAL (
        -- Extract the RAM integer value (usually stored as "Total/Free")
        SELECT TRY_CAST(SPLIT_PART(SPLIT_PART("#ram", '/', 2), '.', 1) AS INTEGER) AS v
    )
    WHERE "$part_date" BETWEEN '2025-11-24' AND '2025-12-02'
      AND "$part_event" = 'role_guide_before'
      AND v IS NOT NULL
)

-- 2. Aggregate counts per RAM category
SELECT 
    ram_category AS "RAM容量",
    COUNT(DISTINCT lcx_id) AS "用户数"
FROM 
    ram_raw
WHERE 
    device_rank = 1
GROUP BY 
    1
ORDER BY 
    -- Manual ordering to ensure logical capacity progression
    CASE 
        WHEN ram_category = '1GB'   THEN 1
        WHEN ram_category = '2GB'   THEN 2
        WHEN ram_category = '3GB'   THEN 3
        WHEN ram_category = '4GB'   THEN 4
        WHEN ram_category = '6GB'   THEN 5
        WHEN ram_category = '8GB'   THEN 6
        WHEN ram_category = '12GB'  THEN 7
        WHEN ram_category = '16GB'  THEN 8
        WHEN ram_category = '16GB+' THEN 9
        ELSE 10
    END ASC;