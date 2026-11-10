-- ODPS SQL: Jump Assemble GL RAM Distribution Stats
-- ********************************************************************
-- Description: 统计 Jump Assemble 全球区用户内�?RAM)分布情况
-- Table: g65002007.daily_game_log (Client Role Create Event)
-- ********************************************************************

SELECT 
    ram_category,
    COUNT(DISTINCT lcm_id) as user_count
FROM (
    SELECT 
        lcm_id,
        CASE 
            WHEN v = 0 THEN '1GB'
            WHEN v = 1 THEN '2GB'
            WHEN v = 2 THEN '3GB'
            WHEN v = 3 THEN '4GB'
            WHEN v <= 5 THEN '6GB'
            WHEN v <= 7 THEN '8GB'
            WHEN v <= 11 THEN '12GB'
            WHEN v <= 15 THEN '16GB'
            WHEN v >= 16 THEN '16GB+'
            ELSE 'Unknown'
        END AS ram_category
    FROM (
        SELECT 
            -- Extract essential fields
            lcm_id,
            --REGEXP_EXTRACT(sdk_info, '"deviceid":"([^"]+)"', 1) as deviceid,
            -- Calculate GB value (Bytes / 1024^3)
            FLOOR(CAST(REGEXP_EXTRACT(sdk_info, '"memorysize":"([^"]+)"', 1) AS DOUBLE) / 1073741824) as v
        FROM g65002007.daily_game_log
        WHERE day BETWEEN 20250125 AND 20260125
        AND event_name = 'client_role_create'  
        -- AND LOWER(store) = 'apple' -- 只有android有这个字�?
    ) t_inner
) t_outer
GROUP BY ram_category;
