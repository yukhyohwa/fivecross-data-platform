/*
================================================================================
Game    : Crayon Shin-chan (蜡笔小新) - TC 繁体大区
Table   : ta.v_event_18, user_result_cluster_18
Report  : 台湾小新水设备关联水账号 ID 清单 (全时间段)
Rule    : 全时间段扫描。基于 user_result_cluster_18 的 fixed_deviceid 标签，
          统计单一设备 (fixed_deviceid) 下触发 new_role 事件去重账号数 > 50 的水设备，
          并直接列出所有关联水账号的 #user_id、#account_id 及关联水设备 ID。
================================================================================
*/

WITH
-- 1. 用户固化标签与固定设备映射
UserProfileDetail AS (
    SELECT 
        "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid,
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_18
    WHERE cluster_name IN ('fixed_deviceid', 'fixed_regdate')
    GROUP BY "#user_id"
),

-- 2. 识别水设备：全时间段内，单一 fixed_deviceid 下 new_role 创角账号数 > 50
WaterDeviceList AS (
    SELECT 
        u.fixed_deviceid,
        COUNT(DISTINCT COALESCE(NULLIF(CAST(v."#account_id" AS VARCHAR), ''), CAST(v."#user_id" AS VARCHAR))) AS new_role_count
    FROM ta.v_event_18 v
    INNER JOIN UserProfileDetail u 
        ON v."#user_id" = u."#user_id"
    WHERE v."$part_event" = 'new_role'
      AND u.fixed_deviceid IS NOT NULL 
      AND u.fixed_deviceid <> ''
    GROUP BY u.fixed_deviceid
    HAVING COUNT(DISTINCT COALESCE(NULLIF(CAST(v."#account_id" AS VARCHAR), ''), CAST(v."#user_id" AS VARCHAR))) > 50
)

-- 3. 直接列出所有水账号 ID 与关联水设备 ID (无复杂统计值)
SELECT DISTINCT
    v."#user_id"                                                                          AS "user_id",
    COALESCE(NULLIF(CAST(v."#account_id" AS VARCHAR), ''), CAST(v."#user_id" AS VARCHAR)) AS "account_id",
    u.fixed_deviceid                                                                      AS "fixed_deviceid",
    u.fixed_regdate                                                                       AS "fixed_regdate",
    wd.new_role_count                                                                     AS "device_new_role_count"
FROM ta.v_event_18 v
INNER JOIN UserProfileDetail u 
    ON v."#user_id" = u."#user_id"
INNER JOIN WaterDeviceList wd 
    ON u.fixed_deviceid = wd.fixed_deviceid
ORDER BY wd.new_role_count DESC, u.fixed_deviceid, "user_id";
