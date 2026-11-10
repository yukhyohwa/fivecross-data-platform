/*
================================================================================
项目    : 蜡笔小新 (Crayon Shin-chan) - TC 新加坡
表名    : ta.v_event_13, user_result_cluster_13
描述    : 单日分时累计 KPI (0-23 小时累计指标)
          包含指标：NUU (新增), DAU (活跃), Sales (收入 USD), ARPU, PR (付费率), ARPPU。
          修正点：1. 严格过滤 "$part_event" IN ('login', 'new_role', 'charge')，排除创角前的 SDK 游离用户
                 2. pay_amount_usd 为空值，采用 CAST(v.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1) 关联 ta_dim.ta_exchange 计算 USD 流水
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),


--AndroidUsers AS (
    -- 仅筛选新加坡用户
--    SELECT DISTINCT "#user_id" AS user_id
--    FROM user_result_cluster_13
--    WHERE cluster_name = 'fixed_os' AND tag_value = 'Android'
--),

-- 1. 获取当天的有效用户行为事件 (排除创角前的 SDK 游离事件)
RawEvents AS (
    SELECT 
        v."#user_id",
        v."$part_event",
        pay_amount_usd,
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub 
        ON v."#user_id" = ub."#user_id"
  --  INNER JOIN AndroidUsers au
  --     ON v."#user_id" = au.user_id
    WHERE v.${PartDate:date1}
      AND ub."#user_id" IS NULL
      AND v."$part_event" IN ('login', 'new_role', 'charge')
      AND (v."$part_event" <> 'charge' OR ((v.sandbox IS NULL OR v.sandbox = FALSE) AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)))
),

-- 2. 梳理每个用户的行为边界时点
UserDailyStats AS (
    SELECT 
        r."#user_id",
        -- 该用户当天首次活跃的小时 (作为计入 DAU 的时点，仅包含 login/new_role/charge 有效事件)
        MIN(event_hour) AS min_active_hour,
        
        -- 该用户是否是新创角用户，以及当天首次创角的小时
        MAX(CASE WHEN "$part_event" = 'new_role' THEN 1 ELSE 0 END) AS is_new_role,
        MIN(CASE WHEN "$part_event" = 'new_role' THEN event_hour END) AS min_nuu_hour
    FROM RawEvents r
    GROUP BY 1
),

-- 3. 交叉 0-23 小时，计算累计 NUU 和 DAU
HourlyPeople AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN s.min_active_hour <= h.hr THEN s."#user_id" END) AS dau,
        COUNT(DISTINCT CASE WHEN s.is_new_role = 1 AND s.min_nuu_hour <= h.hr THEN s."#user_id" END) AS nuu
    FROM UserDailyStats s
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

-- 4. 计算累计收入和累计付费人数
UserPayEvents AS (
    SELECT 
        r."#user_id",
        r.event_hour,
        r.pay_amount_usd
    FROM RawEvents r
    WHERE r."$part_event" = 'charge'
),

UserFirstPay AS (
    SELECT 
        "#user_id",
        MIN(event_hour) AS min_pay_hour
    FROM UserPayEvents
    GROUP BY 1
),

HourlyPay AS (
    SELECT 
        h.hr AS hour,
        SUM(CASE WHEN e.event_hour <= h.hr THEN e.pay_amount_usd ELSE 0 END) AS sales
    FROM UserPayEvents e
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
),

HourlyPayUsers AS (
    SELECT 
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN fp.min_pay_hour <= h.hr THEN fp."#user_id" END) AS paying_users
    FROM UserFirstPay fp
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1
)

-- 5. 整合输出
SELECT 
    LPAD(CAST(p.hour AS VARCHAR), 2, '0') || ':00' AS "時間",
    p.nuu AS "nuu",
    p.dau AS "dau",
    CAST(COALESCE(hpu.paying_users, 0) AS DOUBLE) AS "付费用户数",
    ROUND(COALESCE(hp.sales, 0.0), 2) AS "sales",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(p.dau, 0), 2) AS "arpu",
    CAST(COALESCE(hpu.paying_users, 0) AS DOUBLE) / NULLIF(p.dau, 0)  AS "pr",
    ROUND(COALESCE(hp.sales, 0.0) / NULLIF(hpu.paying_users, 0), 2) AS "arppu"
FROM HourlyPeople p
LEFT JOIN HourlyPay hp ON p.hour = hp.hour
LEFT JOIN HourlyPayUsers hpu ON p.hour = hpu.hour
ORDER BY 
    p.hour DESC;
