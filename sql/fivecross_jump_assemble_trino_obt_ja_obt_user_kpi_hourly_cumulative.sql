/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 单日分时累计 KPI (用户维度 - 去水)
Description: 输入单日参数，输出 0-23 小时每个小时及之前的累计指标（不区分 OS）。
      包含指标：NUU (新增), DAU (活跃), Sales (收入), ARPU, PR (付费率), ARPPU。
      例如 10:00 的数据代表当天 00:00 到 10:59:59 期间所有去重账号的累计数据。
      黑名单规则：同时排除内部测试号(internal_users)和水设备账号(is_water)。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- 获取目标日期
TargetDate AS (
    SELECT MIN(CAST("$part_date" AS DATE)) AS target_date
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
),

-- 获取目标日注册的新用户（从标签中获取）
NewUsers AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_23
    WHERE cluster_name = 'fixed_regdate'
      AND CAST(tag_value AS DATE) = (SELECT target_date FROM TargetDate)
),

-- 1. 获取活跃事件（仅 NUU 和 LOGIN_SUCCESS，过滤黑名单用户）
ActiveEvents AS (
    SELECT 
        v."#account_id",
        v."$part_event",
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1}
      AND ub."#account_id" IS NULL
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 梳理活跃用户的行为边界时点
UserDailyStats AS (
    SELECT 
        ae."#account_id",
        -- 该用户当天首次活跃的小时 (作为他计入 DAU 的时点)
        MIN(ae.event_hour) AS min_active_hour,
        
        -- 该用户是否是新用户，以及当天首次出现 NUU 的小时
        MAX(CASE WHEN nu."#account_id" IS NOT NULL THEN 1 ELSE 0 END) AS is_new_role,
        MIN(CASE WHEN nu."#account_id" IS NOT NULL THEN ae.event_hour END) AS min_nuu_hour
    FROM ActiveEvents ae
    LEFT JOIN NewUsers nu ON ae."#account_id" = nu."#account_id"
    GROUP BY 1
),

-- 3. 交叉 0-23 小时，计算累计 NUU 和 DAU
HourlyPeople AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN s.min_active_hour <= h.hr THEN s."#account_id" END) AS dau,
        COUNT(DISTINCT CASE WHEN s.is_new_role = 1 AND s.min_nuu_hour <= h.hr THEN s."#account_id" END) AS nuu
    FROM UserDailyStats s
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

-- 4. 获取充值事件（所有正常充值记录，过滤黑名单账号以保持PR等指标口径一致）
RawPayEvents AS (
    SELECT 
        v."#account_id",
        CAST(v.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0) AS pay_amount_usd,
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
        AND v.payload.cur = s5.currency
    WHERE v.${PartDate:date1}
      AND ub."#account_id" IS NULL
      AND v."$part_event" = 'PURCHASE'
      -- 过滤沙盒充值，只保留正常充值
      AND (v.payload.validationtype IS NULL OR v.payload.validationtype <> 'SANDBOX_RECEIPT')
),

-- 5. 计算累计收入和累计付费人数
UserFirstPay AS (
    SELECT 
        "#account_id",
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
    p.nuu AS "nuu",
    p.dau AS "dau",
    ROUND(COALESCE(hp.sales, 0.0), 2) AS "sales",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(p.dau, 0), 2) AS "arpu",
    (CAST(COALESCE(hpu.paying_users, 0) AS DOUBLE) / NULLIF(p.dau, 0)) AS "pr",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(hpu.paying_users, 0), 2) AS "arppu"
FROM HourlyPeople p
LEFT JOIN HourlyPay hp ON p.hour = hp.hour
LEFT JOIN HourlyPayUsers hpu ON p.hour = hpu.hour
ORDER BY 
    p.hour ASC;
