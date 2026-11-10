/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 单日分时累计 KPI (设备维度 - 不去水)
Description: 输入单日参数，输出 0-23 小时每个小时及之前的累计指标（不区分 OS）。
      包含指标：device_nuu (新增设备), device_dau (活跃设备), Sales (设备维度收入), device_arpu, device_pr (设备付费率), device_arppu。
      例如 10:00 的数据代表当天 00:00 到 10:59:59 期间所有去重设备的累计数据。
      黑名单规则：仅排除内部测试账号(internal_users)，不排除水设备账号(is_water)。
================================================================================
*/

WITH DeviceBlacklist_NoWater AS (
    -- 设备不去水黑名单：仅包含【内部测试号】，保留【水设备账号】
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_23
    WHERE cluster_name = 'internal_users'
),

-- 获取目标日期
TargetDate AS (
    SELECT MIN(CAST("$part_date" AS DATE)) AS target_date
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
),

-- 获取账号和设备绑定关系表
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid 
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_regdate', 'fixed_deviceid')
    GROUP BY "#varchar_id"
),

-- 映射设备最早注册时间
DeviceProfile AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), 'unknown') AS device_id,
        MIN(fixed_regdate) AS reg_date
    FROM UserProfileDetail
    GROUP BY 1
),

-- 获取目标日注册的新设备
NewDevices AS (
    SELECT DISTINCT device_id
    FROM DeviceProfile
    WHERE CAST(reg_date AS DATE) = (SELECT target_date FROM TargetDate)
),

-- 1. 获取活跃事件（仅 NUU 和 LOGIN_SUCCESS，过滤测试账号）
ActiveEvents AS (
    SELECT 
        v."#account_id",
        COALESCE(NULLIF(s4.fixed_deviceid, ''), 'unknown') AS device_id,
        v."$part_event",
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_23 v
    LEFT JOIN DeviceBlacklist_NoWater db ON v."#account_id" = db."#account_id"
    LEFT JOIN UserProfileDetail s4 ON v."#account_id" = s4."#account_id"
    WHERE v.${PartDate:date1}
      AND db."#account_id" IS NULL
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 梳理活跃设备的行为边界时点
DeviceDailyStats AS (
    SELECT 
        ae.device_id,
        MIN(ae.event_hour) AS min_active_hour,
        MAX(CASE WHEN nd.device_id IS NOT NULL THEN 1 ELSE 0 END) AS is_new_device,
        MIN(CASE WHEN nd.device_id IS NOT NULL THEN ae.event_hour END) AS min_nuu_hour
    FROM ActiveEvents ae
    LEFT JOIN NewDevices nd ON ae.device_id = nd.device_id
    GROUP BY 1
),

-- 3. 计算累计 NUU 和 DAU
HourlyPeopleDevice AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN d.min_active_hour <= h.hr THEN d.device_id END) AS device_dau,
        COUNT(DISTINCT CASE WHEN d.is_new_device = 1 AND d.min_nuu_hour <= h.hr THEN d.device_id END) AS device_nuu
    FROM DeviceDailyStats d
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

-- 4. 获取充值事件（所有正常充值记录，过滤测试账号）
RawPayEvents AS (
    SELECT 
        v."#account_id",
        COALESCE(NULLIF(s4.fixed_deviceid, ''), 'unknown') AS device_id,
        CAST(v.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0) AS pay_amount_usd,
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_23 v
    LEFT JOIN DeviceBlacklist_NoWater db ON v."#account_id" = db."#account_id"
    LEFT JOIN UserProfileDetail s4 ON v."#account_id" = s4."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
        AND v.payload.cur = s5.currency
    WHERE v.${PartDate:date1}
      AND db."#account_id" IS NULL
      AND v."$part_event" = 'PURCHASE'
      -- 过滤沙盒充值，只保留正常充值
      AND (v.payload.validationtype IS NULL OR v.payload.validationtype <> 'SANDBOX_RECEIPT')
),

-- 5. 计算累计收入和累计付费设备数
DeviceFirstPay AS (
    SELECT 
        device_id,
        MIN(event_hour) AS min_pay_hour
    FROM RawPayEvents
    GROUP BY 1
),

HourlyPay AS (
    SELECT 
        h.hr AS hour,
        SUM(CASE WHEN e.event_hour <= h.hr THEN e.pay_amount_usd ELSE 0 END) AS sales
    FROM RawPayEvents e
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

HourlyPayDevices AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN fd.min_pay_hour <= h.hr THEN fd.device_id END) AS paying_devices
    FROM DeviceFirstPay fd
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
)

-- 6. 整合输出
SELECT 
    LPAD(CAST(p.hour AS VARCHAR), 2, '0') || ':00' AS "時間",
    p.device_nuu AS "device_nuu",
    p.device_dau AS "device_dau",
    ROUND(COALESCE(hp.sales, 0.0), 2) AS "sales",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(p.device_dau, 0), 2) AS "device_arpu",
    (CAST(COALESCE(hpd.paying_devices, 0) AS DOUBLE) / NULLIF(p.device_dau, 0)) AS "device_pr",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(hpd.paying_devices, 0), 2) AS "device_arppu"
FROM HourlyPeopleDevice p
LEFT JOIN HourlyPay hp ON p.hour = hp.hour
LEFT JOIN HourlyPayDevices hpd ON p.hour = hpd.hour
ORDER BY 
    p.hour ASC;
