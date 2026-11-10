/*
================================================================================
Game: Crayon Shin-chan (蜡笔小新) - SG/Global (Event 13)
Description: Return User (RUU) KPI & LTV analysis script.
             Detects users returning after 30+ days of inactivity.
             Calculates RUU Retention and LTV (1-30 days).
             Uses custom attribution logic and excludes Windows users.
Environment: Trino
Table: ta.v_event_13
================================================================================
*/

WITH
-- 1. [性能优化] 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date,
        -- 往前追溯 60 天作为扫描起点，以判定 30 天不活跃
        DATE_ADD('day', -60, MIN(CAST("$part_date" AS DATE))) AS scan_start_date,
        MAX(CAST("$part_date" AS DATE)) AS scan_end_date
    FROM ta.v_event_13
    WHERE ${PartDate:date1} AND "$part_event" IN ('new_role', 'login')
),

-- 2. 黑名单用户
UserBlacklist AS (
    SELECT DISTINCT CAST("#varchar_id" AS DOUBLE) AS "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

-- 3. 用户归属信息 (整合 ta_app_start 逻辑)
UserAttribution AS (
    SELECT 
        "#user_id",
        "#os" AS os_type,
        country_name,
        ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time" DESC) as rank
    FROM (
        SELECT 
            "#user_id", 
            "#os",
            "#event_time",
            CASE 
                WHEN "#country_code" IN ('HK', 'MO', 'TW') THEN "#province"
                WHEN "#country_code" = 'CN' THEN '中国大陆'
                ELSE "#country" 
            END AS country_name
        FROM ta.v_event_13
        WHERE "$part_date" >= '2025-11-24'
          AND "$part_event" = 'ta_app_start'
    )
),

UserAttributionFinal AS (
    SELECT "#user_id", os_type, country_name
    FROM UserAttribution
    WHERE rank = 1
),

-- 4. 基础登录去重
UserDailyLogin AS (
    SELECT 
        v."#user_id", 
        v."$part_date"
    FROM ta.v_event_13 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" IN ('new_role', 'login')
      AND CAST(v."$part_date" AS DATE) BETWEEN sc.scan_start_date AND sc.scan_end_date
    GROUP BY 1, 2
),

UserLoginSequence AS (
    SELECT 
        "#user_id",
        "$part_date", 
        CAST("$part_date" AS DATE) AS login_date,
        LAG(CAST("$part_date" AS DATE)) OVER (PARTITION BY "#user_id" ORDER BY "$part_date" ASC) AS prev_login_date
    FROM UserDailyLogin
),

-- 5. 判定回流行为 (RUU)
ReturnEvents AS (
    SELECT 
        s."#user_id",
        s."$part_date", 
        s.login_date AS return_date,
        s.prev_login_date
    FROM UserLoginSequence s
    WHERE 
        s.prev_login_date IS NOT NULL 
        AND DATE_DIFF('day', s.prev_login_date, s.login_date) >= 30
),

-- 6. 锁定目标日期窗口内的回流动作
TargetReturnUsers AS (
    SELECT 
        re."#user_id",
        re.return_date,
        COALESCE(ua.os_type, '未知') AS os_type,
        COALESCE(ua.country_name, '未知') AS country
    FROM ReturnEvents re
    LEFT JOIN UserAttributionFinal ua ON re."#user_id" = ua."#user_id"
    LEFT JOIN UserBlacklist ub ON re."#user_id" = ub."#user_id"
    WHERE ${PartDate:date1} 
      AND ub."#user_id" IS NULL
),

-- 7. 回流后留存
ReturneeRetention AS (
    SELECT 
        tru."#user_id",
        tru.return_date,
        ARRAY_AGG(DISTINCT DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE))) AS retention_days_array
    FROM TargetReturnUsers tru
    JOIN ta.v_event_13 v ON tru."#user_id" = v."#user_id"
    WHERE v."$part_date" >= CAST(tru.return_date AS VARCHAR)
      AND v."$part_event" = 'login'
    GROUP BY 1, 2
),

-- 8. 回流用户 LTV 及 周期转化计算
ReturneeLtvStats AS (
    SELECT 
        tru."#user_id",
        tru.return_date,
        
        -- [周期自适应] 回流首期付费金额
        SUM(CASE 
            WHEN (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', tru.return_date) = DATE_TRUNC('day', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', tru.return_date) = DATE_TRUNC('week', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', tru.return_date) = DATE_TRUNC('month', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'A') 
            ) THEN pay_amount_usd ELSE 0 END) AS rev_period,

        -- [固定天数] LTV 序列
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 1 THEN pay_amount_usd ELSE 0 END) AS rev_1,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 7 THEN pay_amount_usd ELSE 0 END) AS rev_7,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 14 THEN pay_amount_usd ELSE 0 END) AS rev_14,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 30 THEN pay_amount_usd ELSE 0 END) AS rev_30
    FROM TargetReturnUsers tru
    JOIN ta.v_event_13 v ON tru."#user_id" = v."#user_id"
    WHERE v."$part_date" >= CAST(tru.return_date AS VARCHAR)
      AND v."$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    GROUP BY 1, 2
)

-- 9. 最终汇总报表
SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '已合并'
    END AS "时间维度",
    CASE WHEN ${Selector:ostype} THEN p1.os_type ELSE '已合并' END AS os_type,
    CASE WHEN ${Selector:country} THEN p1.country ELSE '已合并' END AS country, 
    MAX(CONCAT(
        CAST(GREATEST(
            CASE 
                WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', p1.return_date)
                WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', p1.return_date)
                WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', p1.return_date)
                WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                ELSE p1.return_date
            END, 
            sc.target_start_date
        ) AS VARCHAR),
        ' ~ ',
        CAST(LEAST(
            CASE 
                WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', p1.return_date)
                WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', p1.return_date))
                WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', p1.return_date)))
                WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                ELSE p1.return_date
            END,
            sc.target_end_date
        ) AS VARCHAR)
    )) AS "日期范围",

    COUNT(DISTINCT p1."#user_id") AS "回流人数(RUU)",
    
    -- 回流用户核心转化指标 (自适应统计周期)
    COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#user_id" END) AS "付费回流人数",
    CAST(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#user_id" END) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "付费回流率",
    SUM(r_ltv.rev_period) AS "回流首期收入(USD)",
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "RUU_ARPU",
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#user_id" END), 0) AS "RUU_ARPPU",

    -- 留存指标
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "回流次留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "回流3留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "回流7留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "回流14留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0) AS "回流30留",

    -- LTV 指标 (USD)
    COALESCE(SUM(r_ltv.rev_1) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0), 0) AS ltv_1,
    COALESCE(SUM(r_ltv.rev_7) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0), 0) AS ltv_7,
    COALESCE(SUM(r_ltv.rev_14) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0), 0) AS ltv_14,
    COALESCE(SUM(r_ltv.rev_30) / NULLIF(COUNT(DISTINCT p1."#user_id"), 0), 0) AS ltv_30

FROM TargetReturnUsers p1
CROSS JOIN ScanConfig sc
LEFT JOIN ReturneeRetention r_ret ON p1."#user_id" = r_ret."#user_id" AND p1.return_date = r_ret.return_date
LEFT JOIN ReturneeLtvStats r_ltv ON p1."#user_id" = r_ltv."#user_id" AND p1.return_date = r_ltv.return_date
GROUP BY 1, 2, 3
ORDER BY 1 DESC;
