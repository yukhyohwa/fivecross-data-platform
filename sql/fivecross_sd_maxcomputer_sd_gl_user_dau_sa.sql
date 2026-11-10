-- 规范化的流失用户查询 SQL
-- 目标：筛选特定区域（zone开头为3）、无付费行为、且最后登录时间在20231229之前的用户

WITH SAUsers AS (
    SELECT 
        mbga_uid,user_id,
        MAX(last_login) AS last_login_ts
    FROM 
        g63002013.daily_user_snapshot
    WHERE 
        SUBSTR(zone, 1, 1) = '3' -- 依据提供的代码片段，取zone第一位为3
        AND day >= 20260201
    GROUP BY 
        mbga_uid,user_id
),
LoginUsers AS (
    SELECT DISTINCT day,
        lcm_id
    FROM 
        dm_platform.daily_lcx_user_info
    WHERE 
        day >= 20260101
        AND app_id = 63002013
       
)

SELECT AVG(dau)
FROM (
SELECT 
    t1.day,COUNT(DISTINCT t1.lcm_id) dau
FROM 
    LoginUsers t1
INNER JOIN 
    SAUsers t2 ON t1.lcm_id = t2.mbga_uid
GROUP BY t1.day
)