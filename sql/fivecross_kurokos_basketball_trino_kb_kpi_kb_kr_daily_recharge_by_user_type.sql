/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 每日充值数据按用户类型拆分 (新用户, 回流用户, 老用户)
             - 使用 uuid 作为用户唯一标识
             - 回流定义：本次活跃距离上一次活跃 >= 90天
================================================================================
*/

WITH Params AS (
    -- 适配 TA (数数) 自定义时间宏，在后台界面直接选择区间
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS start_date,
        MAX(CAST("$part_date" AS DATE)) AS end_date
    FROM ta.v_event_12
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
),

-- 1. 获取用户所有的活跃日期 (包含 login, charge, srcoin_buy, scroin_buy)
DailyLogins AS (
    SELECT DISTINCT
        uuid AS user_id,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_12
    WHERE "$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
      AND uuid IS NOT NULL
      AND uuid <> ''
),

UserStatus AS (
    SELECT
        user_id,
        log_date,
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date) AS prev_log_date,
        MIN(log_date) OVER (PARTITION BY user_id) AS first_log_date
    FROM DailyLogins
),

-- 2. 划分目标时间段内的 DAU 类型
TargetDAU AS (
    SELECT
        user_id,
        log_date,
        CASE
            WHEN log_date = first_log_date THEN 'new'
            WHEN prev_log_date IS NOT NULL AND DATE_DIFF('day', prev_log_date, log_date) >= 90 THEN 'return'
            ELSE 'old'
        END AS user_type
    FROM UserStatus
    CROSS JOIN Params p
    WHERE log_date BETWEEN p.start_date AND p.end_date
),

-- 3. 获取目标时间段内的流水
TargetRevenue AS (
    SELECT
        r.uuid AS user_id,
        CAST(r."$part_date" AS DATE) AS pay_date,
        SUM(CAST(r.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS rev_usd
    FROM ta.v_event_12 r
    CROSS JOIN Params p
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
    WHERE (
            (r."$part_event" = 'charge' AND (r.sandbox = false OR r.sandbox IS NULL))
            OR r."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND r."$part_date" >= CAST(p.start_date AS VARCHAR)
      AND r."$part_date" <= CAST(p.end_date AS VARCHAR)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r.uuid IS NOT NULL
      AND r.uuid <> ''
    GROUP BY 1, 2
),

-- 4. 合并活跃和付费数据
UserDailyStats AS (
    SELECT
        d.log_date AS stat_date,
        d.user_id,
        d.user_type,
        COALESCE(r.rev_usd, 0.0) AS rev_usd,
        CASE WHEN r.rev_usd > 0 THEN 1 ELSE 0 END AS is_paying
    FROM TargetDAU d
    LEFT JOIN TargetRevenue r
        ON d.user_id = r.user_id
       AND d.log_date = r.pay_date
),

-- 5. 按天聚合各项指标
DailyAgg AS (
    SELECT
        stat_date,
        COUNT(DISTINCT CASE WHEN user_type = 'new' THEN user_id END) AS new_dau,
        COUNT(DISTINCT CASE WHEN user_type = 'return' THEN user_id END) AS return_dau,
        COUNT(DISTINCT CASE WHEN user_type = 'old' THEN user_id END) AS old_dau,
        
        SUM(CASE WHEN user_type = 'new' THEN rev_usd ELSE 0.0 END) AS new_rev,
        SUM(CASE WHEN user_type = 'return' THEN rev_usd ELSE 0.0 END) AS return_rev,
        SUM(CASE WHEN user_type = 'old' THEN rev_usd ELSE 0.0 END) AS old_rev,
        
        COUNT(DISTINCT CASE WHEN user_type = 'new' AND is_paying = 1 THEN user_id END) AS new_pu,
        COUNT(DISTINCT CASE WHEN user_type = 'return' AND is_paying = 1 THEN user_id END) AS return_pu,
        COUNT(DISTINCT CASE WHEN user_type = 'old' AND is_paying = 1 THEN user_id END) AS old_pu
    FROM UserDailyStats
    GROUP BY stat_date
),

-- 6. 计算最终衍生指标 (ARPU, ARPPU, 付费率)
DailyMetrics AS (
    SELECT
        CAST(stat_date AS VARCHAR) AS stat_date,
        new_dau,
        return_dau,
        old_dau,
        new_rev,
        return_rev,
        old_rev,
        
        TRY(new_rev / NULLIF(new_dau, 0)) AS new_arpu,
        TRY(return_rev / NULLIF(return_dau, 0)) AS return_arpu,
        TRY(old_rev / NULLIF(old_dau, 0)) AS old_arpu,
        
        TRY(new_rev / NULLIF(new_pu, 0)) AS new_arppu,
        TRY(return_rev / NULLIF(return_pu, 0)) AS return_arppu,
        TRY(old_rev / NULLIF(old_pu, 0)) AS old_arppu,
        
        TRY(CAST(new_pu AS DOUBLE) / NULLIF(new_dau, 0)) AS new_pay_rate,
        TRY(CAST(return_pu AS DOUBLE) / NULLIF(return_dau, 0)) AS return_pay_rate,
        TRY(CAST(old_pu AS DOUBLE) / NULLIF(old_dau, 0)) AS old_pay_rate
    FROM DailyAgg
),

-- 7. 汇总计算 (Total)
TotalAgg AS (
    SELECT
        '汇总' AS stat_date,
        SUM(new_dau) AS new_dau,
        SUM(return_dau) AS return_dau,
        SUM(old_dau) AS old_dau,
        SUM(new_rev) AS new_rev,
        SUM(return_rev) AS return_rev,
        SUM(old_rev) AS old_rev,
        SUM(new_pu) AS new_pu,
        SUM(return_pu) AS return_pu,
        SUM(old_pu) AS old_pu
    FROM DailyAgg
),

TotalMetrics AS (
    SELECT
        stat_date,
        new_dau,
        return_dau,
        old_dau,
        new_rev,
        return_rev,
        old_rev,
        
        TRY(new_rev / NULLIF(new_dau, 0)) AS new_arpu,
        TRY(return_rev / NULLIF(return_dau, 0)) AS return_arpu,
        TRY(old_rev / NULLIF(old_dau, 0)) AS old_arpu,
        
        TRY(new_rev / NULLIF(new_pu, 0)) AS new_arppu,
        TRY(return_rev / NULLIF(return_pu, 0)) AS return_arppu,
        TRY(old_rev / NULLIF(old_pu, 0)) AS old_arppu,
        
        TRY(CAST(new_pu AS DOUBLE) / NULLIF(new_dau, 0)) AS new_pay_rate,
        TRY(CAST(return_pu AS DOUBLE) / NULLIF(return_dau, 0)) AS return_pay_rate,
        TRY(CAST(old_pu AS DOUBLE) / NULLIF(old_dau, 0)) AS old_pay_rate
    FROM TotalAgg
),

-- 7.5. 汇总2计算 (期间累计，按期间内最高身份划分)
PeriodUserType AS (
    SELECT
        user_id,
        CASE
            WHEN COUNT_IF(user_type = 'new') > 0 THEN 'new'
            WHEN COUNT_IF(user_type = 'return') > 0 THEN 'return'
            ELSE 'old'
        END AS period_user_type
    FROM TargetDAU
    GROUP BY user_id
),

PeriodUserRevenue AS (
    SELECT
        p.period_user_type,
        p.user_id,
        SUM(COALESCE(r.rev_usd, 0.0)) AS period_rev_usd,
        CASE WHEN SUM(COALESCE(r.rev_usd, 0.0)) > 0 THEN 1 ELSE 0 END AS is_paying
    FROM PeriodUserType p
    LEFT JOIN TargetRevenue r ON p.user_id = r.user_id
    GROUP BY p.period_user_type, p.user_id
),

Total2Agg AS (
    SELECT
        '汇总2(期间累计)' AS stat_date,
        COUNT(DISTINCT CASE WHEN period_user_type = 'new' THEN user_id END) AS new_dau,
        COUNT(DISTINCT CASE WHEN period_user_type = 'return' THEN user_id END) AS return_dau,
        COUNT(DISTINCT CASE WHEN period_user_type = 'old' THEN user_id END) AS old_dau,
        
        SUM(CASE WHEN period_user_type = 'new' THEN period_rev_usd ELSE 0.0 END) AS new_rev,
        SUM(CASE WHEN period_user_type = 'return' THEN period_rev_usd ELSE 0.0 END) AS return_rev,
        SUM(CASE WHEN period_user_type = 'old' THEN period_rev_usd ELSE 0.0 END) AS old_rev,
        
        COUNT(DISTINCT CASE WHEN period_user_type = 'new' AND is_paying = 1 THEN user_id END) AS new_pu,
        COUNT(DISTINCT CASE WHEN period_user_type = 'return' AND is_paying = 1 THEN user_id END) AS return_pu,
        COUNT(DISTINCT CASE WHEN period_user_type = 'old' AND is_paying = 1 THEN user_id END) AS old_pu
    FROM PeriodUserRevenue
),

Total2Metrics AS (
    SELECT
        stat_date,
        new_dau,
        return_dau,
        old_dau,
        new_rev,
        return_rev,
        old_rev,
        
        TRY(new_rev / NULLIF(new_dau, 0)) AS new_arpu,
        TRY(return_rev / NULLIF(return_dau, 0)) AS return_arpu,
        TRY(old_rev / NULLIF(old_dau, 0)) AS old_arpu,
        
        TRY(new_rev / NULLIF(new_pu, 0)) AS new_arppu,
        TRY(return_rev / NULLIF(return_pu, 0)) AS return_arppu,
        TRY(old_rev / NULLIF(old_pu, 0)) AS old_arppu,
        
        TRY(CAST(new_pu AS DOUBLE) / NULLIF(new_dau, 0)) AS new_pay_rate,
        TRY(CAST(return_pu AS DOUBLE) / NULLIF(return_dau, 0)) AS return_pay_rate,
        TRY(CAST(old_pu AS DOUBLE) / NULLIF(old_dau, 0)) AS old_pay_rate
    FROM Total2Agg
)

-- 8. 格式化输出最终结果集
SELECT
    stat_date AS "日期",
    new_dau AS "新用户数量",
    return_dau AS "回流用户数量",
    old_dau AS "老用户数量",
    
    ROUND(new_rev, 2) AS "新用户流水",
    ROUND(return_rev, 2) AS "回流用户流水",
    ROUND(old_rev, 2) AS "老用户流水",
    
    ROUND(new_arpu, 2) AS "新用户ARPU",
    ROUND(return_arpu, 2) AS "回流用户ARPU",
    ROUND(old_arpu, 2) AS "老用户ARPU",
    
    ROUND(new_arppu, 2) AS "新用户ARPPU",
    ROUND(return_arppu, 2) AS "回流用户ARPPU",
    ROUND(old_arppu, 2) AS "老用户ARPPU",
    
    CAST(ROUND(new_pay_rate * 100, 2) AS VARCHAR) || '%' AS "新用户付费率",
    CAST(ROUND(return_pay_rate * 100, 2) AS VARCHAR) || '%' AS "回流用户付费率",
    CAST(ROUND(old_pay_rate * 100, 2) AS VARCHAR) || '%' AS "老用户付费率"
FROM (
    SELECT * FROM DailyMetrics
    UNION ALL
    SELECT * FROM TotalMetrics
    UNION ALL
    SELECT * FROM Total2Metrics
)
ORDER BY
    CASE 
        WHEN stat_date = '汇总' THEN 1 
        WHEN stat_date = '汇总2(期间累计)' THEN 2 
        ELSE 0 
    END,
    stat_date;
