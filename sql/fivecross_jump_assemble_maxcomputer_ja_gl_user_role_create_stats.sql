/*
================================================================================
Game: Kuroko's Basketball
Region: JP (GL)
Description: Device distribution statistics for users who created a role (obtained first character).
Author: Antigravity
Created: 2026-01-26

Current Queries:
  - User count distribution by device model for 'client_role_create' event.

Notes:
  - Filters for 'client_role_create' event and Apple store users.
  - Extracts device model from JSON-formatted sdk_info column.
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Role Creation Logs with Device Extraction
--------------------------------------------------------------------------------
RoleCreationLogs AS (
    SELECT 
        lcm_id,
        MAX(REGEXP_EXTRACT(sdk_info, '"device":"([^"]+)"', 1)) AS device_model
    FROM g65002007.daily_game_log
    WHERE day BETWEEN 20230125 AND 20250125
        AND event_name = 'client_role_create'
        AND LOWER(store) = 'apple'
    GROUP BY 
        lcm_id
)

--------------------------------------------------------------------------------
-- Section 2: Results Aggregation
--------------------------------------------------------------------------------
SELECT 
    t.device_model AS "设备型号",
    COUNT(DISTINCT t.lcm_id) AS "用户数量"
FROM RoleCreationLogs t
WHERE t.device_model IS NOT NULL 
    AND t.device_model <> ''
GROUP BY 
    1
ORDER BY 
    2 DESC;
