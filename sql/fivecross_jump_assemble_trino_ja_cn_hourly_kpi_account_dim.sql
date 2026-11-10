/*
================================================================================
Game    : Jump Assemble- OBT Region
Report  : 单日分时累计 KPI (纯账号维度版 - 修复空设备坍塌与去水逻辑)
Description: 输入单日参数，输出 0-23 小时每个小时及之前的累计指标。
      包含指标：账号维度的 NUU (新增), DAU (活跃), Sales (收入), ARPU, PR (付费率), ARPPU。
================================================================================
*/

WITH UserBlacklist_WithWater AS (
    -- 用户去水黑名单：同时包含【内部测试号】与【水设备账号】
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_4
    WHERE cluster_name IN ('internal_users') 
),

-- 获取目标日期
TargetDate AS (
    SELECT MIN(CAST("$part_date" AS DATE)) AS target_date
    FROM ta.v_event_4
    WHERE ${PartDate:date1}
),

-- 获取目标日注册的新用户（从标签中获取）
NewUsers AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_4
    WHERE cluster_name = 'fixed_regdate'
      AND CAST(tag_value AS DATE) = (SELECT target_date FROM TargetDate)
),

-- 1. 获取活跃事件并打上对应的黑名单标记
ActiveEvents AS (
    SELECT 
        v."#account_id",
        v."$part_event",
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour,
        
        -- 用户去水判断：不在 UserBlacklist_WithWater 中即为 1
        CASE WHEN ub."#account_id" IS NULL THEN 1 ELSE 0 END AS is_valid_user
    FROM ta.v_event_4 v
    LEFT JOIN UserBlacklist_WithWater ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1}
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 梳理活跃用户的行为边界时点（排除测试号与水设备，即去水）
UserDailyStats AS (
    SELECT 
        ae."#account_id",
        MIN(ae.event_hour) AS min_active_hour,
        MAX(CASE WHEN nu."#account_id" IS NOT NULL THEN 1 ELSE 0 END) AS is_new_role,
        MIN(CASE WHEN nu."#account_id" IS NOT NULL THEN ae.event_hour END) AS min_nuu_hour
    FROM ActiveEvents ae
    LEFT JOIN NewUsers nu ON ae."#account_id" = nu."#account_id"
    WHERE ae.is_valid_user = 1
    GROUP BY 1
),

-- 3. 计算累计 NUU 和 DAU (账号维度)
HourlyPeopleAccount AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN s.min_active_hour <= h.hr THEN s."#account_id" END) AS dau,
        COUNT(DISTINCT CASE WHEN s.is_new_role = 1 AND s.min_nuu_hour <= h.hr THEN s."#account_id" END) AS nuu
    FROM UserDailyStats s
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

-- 4. 获取充值事件（所有正常充值记录）
RawPayEvents AS (
    SELECT 
        v."#account_id",
        CAST(v.payload.curamt AS DOUBLE) AS pay_amount_rmb,
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_4 v
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'PURCHASE'
      -- 过滤沙盒充值，只保留正常充值
      AND (v.payload.validationtype IS NULL OR v.payload.validationtype <> 'SANDBOX_RECEIPT')
),

-- 5. 计算累计收入和累计付费人数
UserFirstPay AS (
    SELECT 
        fp."#account_id",
        MIN(fp.event_hour) AS min_pay_hour
    FROM RawPayEvents fp
    LEFT JOIN UserBlacklist_WithWater ub ON fp."#account_id" = ub."#account_id"
    WHERE ub."#account_id" IS NULL
    GROUP BY 1
),

HourlyPay AS (
    SELECT 
        h.hr AS hour,
        SUM(CASE WHEN e.event_hour <= h.hr THEN e.pay_amount_rmb ELSE 0 END) AS sales
    FROM RawPayEvents e
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

HourlyPayUsers AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN fp.min_pay_hour <= h.hr THEN fp."#account_id" END) AS paying_users
    FROM UserFirstPay fp
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
)

-- 6. 整合输出
SELECT 
    LPAD(CAST(p.hour AS VARCHAR), 2, '0') || ':00' AS "時間",
    -- 账号维度
    p.nuu AS "nuu",
    p.dau AS "dau",
    ROUND(COALESCE(hp.sales, 0.0), 2) AS "sales",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(p.dau, 0), 2) AS "arpu",
    (CAST(COALESCE(hpu.paying_users, 0) AS DOUBLE) / NULLIF(p.dau, 0)) AS "pr",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(hpu.paying_users, 0), 2) AS "arppu"
FROM HourlyPeopleAccount p
LEFT JOIN HourlyPay hp ON p.hour = hp.hour
LEFT JOIN HourlyPayUsers hpu ON p.hour = hpu.hour
WHERE p.hour <= HOUR(CURRENT_TIME)
ORDER BY 
    p.hour DESC;
