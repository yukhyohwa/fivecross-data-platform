/*
================================================================================
Game    : Jump Assemble (众星之聚)
Region  : TC (Traditional Chinese - 台港澳)
Purpose : 查询 至今 每日 DAU
Metrics : 每日活跃用户数 (DAU)
Table   : dm_platform.daily_lcx_user_info
Engine  : Hologres / MaxCompute (ODPS)
App ID  : 65002007
================================================================================
*/

SELECT
    'Jump Assemble (TC)'         AS "游戏",
    app_id                       AS "App ID",
    day                          AS "日期",
    COUNT(DISTINCT lcm_id)       AS "DAU"
FROM
    dm_platform.daily_lcx_user_info
WHERE
    app_id = '65002007'
    AND day >= 20240101  -- 从 2024 年开始覆盖 CBT 及正式上线周期
GROUP BY
    app_id,
    day
ORDER BY
    day ASC;
