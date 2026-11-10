-- 规范化的流失用户查询 SQL
-- 目标：筛选特定区域（zone开头为3）、无付费行为、且最后登录时间在20231229之前的用户

WITH SAUsers AS (
    SELECT 
        DISTINCT mbga_uid,user_id
    FROM 
        g63002013.daily_user_snapshot
    WHERE 
        SUBSTR(zone, 1, 1) = '3' -- 依据提供的代码片段，取zone第一位为3
        AND day = 20260201
)

SELECT
    day,
    GET_JSON_OBJECT(a_tar, '$.type') AS type,
    AVG(GET_JSON_OBJECT(a_tar, '$.ping')) AS ping
FROM g63002013.daily_game_log s1
INNER JOIN SAUsers s2 ON s1.user_id = s2.user_id
WHERE day >= 20230101
AND a_typ = 'fight_data'
GROUP BY
    day,
    GET_JSON_OBJECT(a_tar, '$.type')