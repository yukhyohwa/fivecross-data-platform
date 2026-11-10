/*
================================================================================
Game    : Slam Dunk 灌篮高手
Region  : GL (全球 63002013) & KR (韩国 33002013)
Purpose : 查询 2020年至今 每日 DAU，用于判断两款游戏的上线时间
Metrics : 每日活跃用户数 (DAU)
Table   : dm_platform.daily_lcx_user_info
Engine  : Hologres
================================================================================
*/

SELECT
    CASE
        WHEN app_id = '63002013' THEN '灌篮全球(GL)'
        WHEN app_id = '33002013' THEN '灌篮韩国(KR)'
    END                          AS "游戏",
    app_id                       AS "App ID",
    day                          AS "日期",
    COUNT(DISTINCT lcm_id)       AS "DAU"
FROM
    dm_platform.daily_lcx_user_info
WHERE
    app_id IN ('63002013', '33002013')
    AND day >= 20200101
GROUP BY
    app_id,
    day
ORDER BY
    app_id ASC,
    day    ASC;
