/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 活动期间用户群组充值数据 (支持配置多个活动时间段)
             - 新用户：在活动期间首次活跃的用户，该用户在整个期间内的所有活跃和付费均记为“新用户”
             - 回流用户：在活动期间发生过 >= 90天回流的用户，该用户在整个期间内的活跃和付费均记为“回流用户”
             - 老用户：在此期间活跃的其他所有用户
             - 使用 uuid 作为用户唯一标识
================================================================================
*/

WITH Params AS (
    -- 适配 TA (数数) 自定义时间宏，在后台界面直接选择活动区间
    SELECT 
        '自定义活动期间' AS event_name, 
        MIN(CAST("$part_date" AS DATE)) AS event_start, 
        MAX(CAST("$part_date" AS DATE)) AS event_end
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

-- 2. 定义用户在活动期间的【固定身份】 (Cohort)
UserCohort AS (
    SELECT
        p.event_name,
        u.user_id,
        -- 是否为活动期新用户 (在活动期间首次登录)
        MAX(CASE WHEN u.log_date = u.first_log_date THEN 1 ELSE 0 END) AS is_event_new,
        -- 是否为活动期回流用户 (在活动期间发生过 >= 90天的回流)
        MAX(CASE WHEN u.log_date > u.first_log_date AND u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 90 THEN 1 ELSE 0 END) AS is_event_return
    FROM UserStatus u
    JOIN Params p ON u.log_date BETWEEN p.event_start AND p.event_end
    GROUP BY p.event_name, u.user_id
),

-- 确定用户的最终分类 (优先级: 活动新用户 > 活动回流用户 > 老用户)
UserTypeMapping AS (
    SELECT
        event_name,
        user_id,
        CASE 
            WHEN is_event_new = 1 THEN 'new'
            WHEN is_event_return = 1 THEN 'return'
            ELSE 'old'
        END AS user_type
    FROM UserCohort
),

-- 3. 获取目标时间段内的 DAU，并赋予他们固定的身份标签
TargetDAU AS (
    SELECT
        p.event_name,
        d.user_id,
        d.log_date,
        m.user_type
    FROM DailyLogins d
    JOIN Params p ON d.log_date BETWEEN p.event_start AND p.event_end
    JOIN UserTypeMapping m ON d.user_id = m.user_id AND p.event_name = m.event_name
),

-- 4. 获取目标时间段内的流水
TargetRevenue AS (
    SELECT
        p.event_name,
        r.uuid AS user_id,
        CAST(r."$part_date" AS DATE) AS pay_date,
        SUM(CAST(r.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS rev_usd
    FROM ta.v_event_12 r
    JOIN Params p ON CAST(r."$part_date" AS DATE) BETWEEN p.event_start AND p.event_end
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
    WHERE (
            (r."$part_event" = 'charge' AND (r.sandbox = false OR r.sandbox IS NULL))
            OR r."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r.uuid IS NOT NULL
      AND r.uuid <> ''
    GROUP BY 1, 2, 3
),

-- 5. 合并活跃和付费数据
UserDailyStats AS (
    SELECT
        d.event_name,
        d.log_date AS stat_date,
        d.user_id,
        d.user_type,
        COALESCE(r.rev_usd, 0.0) AS rev_usd,
        CASE WHEN r.rev_usd > 0 THEN 1 ELSE 0 END AS is_paying
    FROM TargetDAU d
    LEFT JOIN TargetRevenue r
        ON d.event_name = r.event_name
       AND d.user_id = r.user_id
       AND d.log_date = r.pay_date
),

-- 6. 按天聚合各项指标
DailyAgg AS (
    SELECT
        event_name,
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
    GROUP BY event_name, stat_date
),

-- 7. 计算最终衍生指标 (ARPU, ARPPU, 付费率)
DailyMetrics AS (
    SELECT
        event_name,
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

-- 8. 汇总计算 (Total)
TotalAgg AS (
    SELECT
        event_name,
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
    GROUP BY event_name
),

TotalMetrics AS (
    SELECT
        event_name,
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
)

-- 9. 格式化输出最终结果集
SELECT
    event_name AS "活动",
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
)
ORDER BY
    event_name,
    CASE WHEN stat_date = '汇总' THEN 1 ELSE 0 END,
    stat_date;
