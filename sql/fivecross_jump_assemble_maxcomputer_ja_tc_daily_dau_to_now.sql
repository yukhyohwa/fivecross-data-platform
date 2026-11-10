/*
================================================================================
Game    : Jump Assemble (众星之聚)
Region  : TC (Traditional Chinese - 台港澳)
Purpose : 查询 至今 每日 DAU
Metrics : 每日活跃用户数 (DAU)
Table   : dm_platform.daily_lcx_user_info
Engine  : MaxCompute (ODPS)
App ID  : 65002007
================================================================================
*/

SELECT
    'Jump Assemble (TC)'         AS game_name,
    app_id,
    day,
    COUNT(DISTINCT lcm_id)       AS dau
FROM
    dm_platform.daily_lcx_user_info
WHERE
    app_id = 65002007
    AND day >= 20240101
GROUP BY
    app_id,
    day
ORDER BY
    day ASC;
