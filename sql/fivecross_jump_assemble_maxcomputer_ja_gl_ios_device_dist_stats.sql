-- ODPS SQL: Jump Assemble GL iOS Device Model Distribution
-- ********************************************************************
-- Description: 统计 Jump Assemble 全球�?iOS 设备型号分布情况
-- Table: g65002007.daily_game_log
-- ********************************************************************

SELECT 
    device_model,
    COUNT(DISTINCT lcm_id) as user_count
FROM (
    SELECT 
        lcm_id,
        MAX(REGEXP_EXTRACT(sdk_info, '"device":"([^"]+)"', 1)) as device_model
    FROM g65002007.daily_game_log
    WHERE day BETWEEN 20230125 AND 20250125
    AND event_name = 'client_role_create'
    AND LOWER(store) = 'apple'
    GROUP BY lcm_id
) t
WHERE device_model IS NOT NULL AND device_model <> ''
GROUP BY device_model
ORDER BY user_count DESC;
