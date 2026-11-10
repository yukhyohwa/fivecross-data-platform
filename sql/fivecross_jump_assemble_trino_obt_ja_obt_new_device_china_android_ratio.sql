/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 每日新设备中中国安卓用户占比统计
Description : 统计每日新增设备总数、其中属于中国且为 Android 系统的设备数，并计算其占比。
              1. 使用 UserProfileDetail (来自 user_result_cluster_23) 确定注册日期、设备ID、系统(fixed_os)和国家(fixed_country)。
              2. 以 fixed_deviceid 作为唯一设备标识。
              3. 排除 internal_users 黑名单对应的设备。
Environment : Trino (TA)
================================================================================
*/

WITH
-- 1. [性能优化] 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_23
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 黑名单用户
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users')
),

-- 3. 用户标签数据表 (抓取所需字段)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os'       THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid,
        MAX(CASE WHEN cluster_name = 'fixed_country'  THEN tag_value END) AS fixed_country
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate', 'fixed_deviceid', 'fixed_country')
    GROUP BY "#varchar_id"
),

-- 4. 映射设备基本属性 (最早注册时间、系统以及国家)
DeviceProfile AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), 'unknown') AS device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type,
        MAX(fixed_country) AS country
    FROM UserProfileDetail
    GROUP BY 1
),

-- 5. 黑名单设备 (如果设备下有账号是黑名单，则剔除该设备，排除空与 unknown 异常设备)
DeviceBlacklist AS (
    SELECT DISTINCT s4.fixed_deviceid AS device_id
    FROM UserBlacklist ub
    INNER JOIN UserProfileDetail s4 ON ub."#account_id" = s4."#account_id"
    WHERE s4.fixed_deviceid IS NOT NULL 
      AND s4.fixed_deviceid <> '' 
      AND s4.fixed_deviceid <> 'unknown'
)

-- 6. 聚合统计
SELECT
    dp.reg_date AS "日期",
    COUNT(DISTINCT dp.device_id) AS "新设备",
    COUNT(DISTINCT CASE WHEN dp.os_type = 'Android' AND dp.country = '中国' THEN dp.device_id END) AS "中国安卓设备",
    CAST(COUNT(DISTINCT CASE WHEN dp.os_type = 'Android' AND dp.country = '中国' THEN dp.device_id END) AS DOUBLE) 
        / NULLIF(COUNT(DISTINCT dp.device_id), 0) AS "占比"
FROM DeviceProfile dp
LEFT JOIN DeviceBlacklist db ON dp.device_id = db.device_id
CROSS JOIN ScanConfig sc
WHERE dp.device_id <> 'unknown'
  AND db.device_id IS NULL
  AND CAST(dp.reg_date AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
GROUP BY 1
ORDER BY 1 DESC;
