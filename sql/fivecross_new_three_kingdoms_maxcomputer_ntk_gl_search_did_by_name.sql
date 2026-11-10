
WITH role_info AS (
    -- 第一步：通过昵称获取 role_id
    SELECT DISTINCT roleid, role_name, lid, zone
    FROM g65002004.dm_daily_role_info
    WHERE role_name LIKE "%關羽你的歌%"
      AND day >= 20200201
)


SELECT 
    DISTINCT
    t3.dena_id,
    t3.did, 
    t3.lcm_id, 
    t1.zone,
    t1.roleid,
    t1.role_name
FROM dm_platform.lcx_user_info t3
JOIN role_info t1 ON TRIM(t3.lcm_id) = TRIM(t1.lid)
WHERE t3.app_id = '65002004'
  AND t3.day >= 20140101;