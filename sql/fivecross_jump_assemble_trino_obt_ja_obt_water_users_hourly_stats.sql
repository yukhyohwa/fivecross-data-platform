/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 每日/每小时判定为水量 (is_water) 的账号与设备数量统计
Description: 
    统计 OBT 首周起，每日每个小时区间内被系统判定为水量 (is_water) 的：
    1. 新增水量：该小时注册 (NUU) 的水量账号与设备数。
    2. 活跃水量：该小时活跃 (LOGIN_SUCCESS 或 NUU) 的水量账号与设备数。
    设备定义口径：以 fixed_deviceid 为准，若为空则映射为 'unknown_' + account_id。
Environment: Trino (TA)
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 提取所有被判定为水量 (is_water) 的账号及其对应的设备 ID (fixed_deviceid)
--------------------------------------------------------------------------------
WaterUsers AS (
    SELECT 
        "#varchar_id" AS account_id,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid
    FROM user_result_cluster_23
    WHERE "#varchar_id" IN (
        SELECT DISTINCT "#varchar_id"
        FROM user_result_cluster_23
        WHERE cluster_name = 'is_water'
    )
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 2. 关联玩家在 v_event_23 中的活跃与注册事件
--------------------------------------------------------------------------------
WaterActivity AS (
    SELECT 
        v."$part_date" AS event_date,
        HOUR(v."#event_time") AS event_hour,
        v."$part_event" AS part_event,
        wu.account_id,
        COALESCE(NULLIF(wu.fixed_deviceid, ''), CONCAT('unknown_', wu.account_id)) AS device_id
    FROM ta.v_event_23 v
    INNER JOIN WaterUsers wu ON v."#account_id" = wu.account_id
    WHERE v."$part_date" >= '2026-06-24'
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
)

--------------------------------------------------------------------------------
-- 3. 按天、按小时进行新增和活跃水量去重统计
--------------------------------------------------------------------------------
SELECT 
    event_date AS "日期",
    event_hour AS "小时",
    
    -- 新增水量账号和设备 (注册事件)
    COUNT(DISTINCT CASE WHEN part_event = 'NUU' THEN account_id END) AS "新增水量账号数",
    COUNT(DISTINCT CASE WHEN part_event = 'NUU' THEN device_id END) AS "新增水量设备数",
    
    -- 活跃水量账号和设备 (登录或注册事件)
    COUNT(DISTINCT account_id) AS "活跃水量账号数",
    COUNT(DISTINCT device_id) AS "活跃水量设备数"
FROM WaterActivity
GROUP BY 1, event_hour
ORDER BY 1 DESC, event_hour DESC;
