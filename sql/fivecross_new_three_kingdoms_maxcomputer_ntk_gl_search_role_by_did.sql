WITH user_info AS (
    -- 第一步：通过 did 获取 lid (lcm_id)
    SELECT lcm_id AS lid
    FROM dm_platform.lcx_user_info 
    WHERE app_id = '65002004' 
      AND day >= 20140101
      AND did = '226906992'
),
role_id_mapping AS (
    -- 第二步：通过 lid 在日志中解析出 role_id
    SELECT DISTINCT GET_JSON_OBJECT(t2.role_info, '$.role_id') AS role_id
    FROM g65002004.game_log_temp t2
    JOIN user_info t1 ON t2.lid = t1.lid
    WHERE t2.day = 20260209
)
-- 第三步：通过 role_id 获取每日角色详情
SELECT t3.*
FROM g65002004.dm_daily_role_info t3
JOIN role_id_mapping t2 ON t3.roleid = t2.role_id
WHERE t3.day = 20260201;