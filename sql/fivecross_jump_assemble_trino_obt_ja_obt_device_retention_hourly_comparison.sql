/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 累计分时留存对比 (设备维度 - 不去水)
Description: 比较 CBT1, CBT2, OBT 在特定留存天数 (D_N) 内各小时的累计留存数据（不区分 OS）。
             以 fixed_deviceid 作为新增与留存的核心口径。
             黑名单规则：仅排除内部测试号(internal_users)，不排除水设备账号(is_water)。
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 时段边界
--    CBT1 固定为 2025-11-25
--    CBT2 固定为 2026-04-15
--    OBT  由参数 ${PartDate:date2} 动态控制 (从 2026-05-20 起的分区数据)
--------------------------------------------------------------------------------
Period1Range AS (
    SELECT 
        DATE '2025-11-25' AS p_start, 
        DATE '2025-11-25' AS p_end
),
Period2Range AS (
    SELECT
        DATE '2026-04-15' AS p_start,
        DATE '2026-04-15' AS p_end
),
PeriodOBTRange AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_23
    WHERE ${PartDate:date2}
),

--------------------------------------------------------------------------------
-- 2. 黑名单与设备映射 (CBT 对应 16，OBT 对应 23)
--    设备不去水判断：仅过滤测试号，不过滤 is_water 水设备
--------------------------------------------------------------------------------
DeviceBlacklist_16 AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name = 'internal_users'
),
DeviceBlacklist_23 AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_23
    WHERE cluster_name = 'internal_users'
),

UserProfileDetail_16 AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os'       THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid 
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate', 'fixed_deviceid')
    GROUP BY 1
),
UserProfileDetail_23 AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os'       THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid 
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate', 'fixed_deviceid')
    GROUP BY 1
),

-- 设备基本属性映射
DeviceProfile_16 AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), CONCAT('unknown_', "#account_id")) AS device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type
    FROM UserProfileDetail_16
    GROUP BY 1
),
DeviceProfile_23 AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), CONCAT('unknown_', "#account_id")) AS device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type
    FROM UserProfileDetail_23
    GROUP BY 1
),

-- 关联设备黑名单（只要设备下有任一账号在测试黑名单中，则排除该设备）
DeviceBlacklistFilter_16 AS (
    SELECT DISTINCT COALESCE(NULLIF(s.fixed_deviceid, ''), CONCAT('unknown_', s."#account_id")) AS device_id
    FROM DeviceBlacklist_16 b
    INNER JOIN UserProfileDetail_16 s ON b."#account_id" = s."#account_id"
),
DeviceBlacklistFilter_23 AS (
    SELECT DISTINCT COALESCE(NULLIF(s.fixed_deviceid, ''), CONCAT('unknown_', s."#account_id")) AS device_id
    FROM DeviceBlacklist_23 b
    INNER JOIN UserProfileDetail_23 s ON b."#account_id" = s."#account_id"
),

--------------------------------------------------------------------------------
-- 3. Cohort 设备集
--    符合注册日期要求的设备列表
--------------------------------------------------------------------------------
CohortDevices AS (
    -- Period1 (CBT1): 2025-11-25 注册的设备
    SELECT
        d.device_id,
        d.reg_date,
        d.os_type    AS ostype,
        'CBT1'       AS period
    FROM DeviceProfile_16 d
    LEFT JOIN DeviceBlacklistFilter_16 b ON d.device_id = b.device_id
    WHERE b.device_id IS NULL
      AND d.reg_date = '2025-11-25'

    UNION ALL

    -- Period2 (CBT2): 2026-04-15 注册的设备
    SELECT
        d.device_id,
        d.reg_date,
        d.os_type    AS ostype,
        'CBT2'       AS period
    FROM DeviceProfile_16 d
    LEFT JOIN DeviceBlacklistFilter_16 b ON d.device_id = b.device_id
    WHERE b.device_id IS NULL
      AND d.reg_date = '2026-04-15'

    UNION ALL

    -- Period3 (OBT): OBT 动态注册的设备
    SELECT
        d.device_id,
        d.reg_date,
        d.os_type    AS ostype,
        'OBT'        AS period
    FROM DeviceProfile_23 d
    LEFT JOIN DeviceBlacklistFilter_23 b ON d.device_id = b.device_id
    CROSS JOIN PeriodOBTRange p
    WHERE b.device_id IS NULL
      AND d.reg_date IS NOT NULL
      AND CAST(d.reg_date AS DATE) BETWEEN p.p_start AND p.p_end
),

--------------------------------------------------------------------------------
-- 4. 设备回访行为明细
--------------------------------------------------------------------------------
DeviceActivity AS (
    -- CBT1 窗口 (固定 2025-11-25)
    SELECT
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) AS device_id,
        s2.period,
        DATE '2025-11-25' AS p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_16 s1
    LEFT JOIN UserProfileDetail_16 s4 ON s1."#account_id" = s4."#account_id"
    INNER JOIN CohortDevices s2 ON COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) = s2.device_id AND s2.period = 'CBT1'
    WHERE s1."$part_date" BETWEEN '2025-11-25'
                               AND CAST(DATE_ADD('day', 7, DATE '2025-11-25') AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')

    UNION ALL

    -- CBT2 窗口 (固定 2026-04-15)
    SELECT
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) AS device_id,
        s2.period,
        DATE '2026-04-15' AS p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_16 s1
    LEFT JOIN UserProfileDetail_16 s4 ON s1."#account_id" = s4."#account_id"
    INNER JOIN CohortDevices s2 ON COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) = s2.device_id AND s2.period = 'CBT2'
    WHERE s1."$part_date" BETWEEN '2026-04-15'
                               AND CAST(DATE_ADD('day', 7, DATE '2026-04-15') AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')

    UNION ALL

    -- OBT 窗口 (动态时段)
    SELECT
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) AS device_id,
        s2.period,
        p.p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_23 s1
    LEFT JOIN UserProfileDetail_23 s4 ON s1."#account_id" = s4."#account_id"
    INNER JOIN CohortDevices s2 ON COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) = s2.device_id AND s2.period = 'OBT'
    CROSS JOIN PeriodOBTRange p
    WHERE s1."$part_date" BETWEEN CAST(p.p_start AS VARCHAR)
                               AND CAST(DATE_ADD('day', 7, p.p_end) AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')
),

--------------------------------------------------------------------------------
-- 5. 设备基准数
--------------------------------------------------------------------------------
BaseDevices AS (
    SELECT period, COUNT(DISTINCT device_id) AS new_device
    FROM CohortDevices
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 6. 分时累计留存统计
--------------------------------------------------------------------------------
HourlyStats AS (
    SELECT
        a.period,
        a.p_start,
        h.hr AS hour,
        COUNT(DISTINCT
            CASE
                WHEN a.diff_day = ${Selector:retention}
                 AND a.event_hour <= h.hr
                THEN a.device_id
            END
        ) AS retained_devices
    FROM DeviceActivity a
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1, 2, 3
)

--------------------------------------------------------------------------------
-- 7. 最终输出
--------------------------------------------------------------------------------
SELECT
    s.period,
    s.p_start,
    CAST(s.hour AS VARCHAR)                                      AS "hour",
    s.retained_devices                                           AS "累计分时留存设备数",
    b.new_device                                                 AS "新增基准设备",
    CAST(s.retained_devices AS DOUBLE) / NULLIF(b.new_device, 0) AS "留存率 (retention rate)"
FROM HourlyStats s
JOIN BaseDevices b ON s.period = b.period
ORDER BY s.period DESC, s.hour ASC;
