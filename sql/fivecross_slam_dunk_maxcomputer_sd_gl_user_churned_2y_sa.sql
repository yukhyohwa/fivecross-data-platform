-- 规范化的流失用户查询 SQL
-- 目标：筛选特定区域（zone开头为3）、无付费行为、且最后登录时间在20231229之前的用户

WITH LastLogin AS (
    SELECT 
        mbga_uid,user_id,
        MAX(last_login) AS last_login_ts
    FROM 
        g63002013.daily_user_snapshot
    WHERE 
        SUBSTR(zone, 1, 1) = '3' -- 依据提供的代码片段，取zone第一位为3
        AND day >= 0
    GROUP BY 
        mbga_uid,user_id
),
PaidUsers AS (
    SELECT DISTINCT 
        lcm_id
    FROM 
        dm_platform.daily_lcx_user_info
    WHERE 
        day >= 0
        AND app_id = 63002013
        AND purchase > 0
)

SELECT 
    t1.user_id
FROM 
    LastLogin t1
LEFT JOIN 
    PaidUsers t2 ON t1.mbga_uid = t2.lcm_id
WHERE 
    -- 将时间戳转换为yyyyMMdd格式进行比较
    TO_CHAR(FROM_UNIXTIME(CAST(t1.last_login_ts AS BIGINT)), 'yyyyMMdd') <= '20231229'
    AND t2.lcm_id IS NULL; -- 仅筛选未在 PaidUsers 表中出现的用户（非付费用户）
