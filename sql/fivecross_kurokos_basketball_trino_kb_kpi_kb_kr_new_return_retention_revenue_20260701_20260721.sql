/*
================================================================================
Game: Kuroko's Basketball (黑子篮球)
Region: KR (v_event_12)
Description: 2026-07-01 ~ 2026-07-21 每日新增与回流用户在截至 2026-07-26 的剩余活跃数与累计付费数据统计
              - 使用 uuid 作为唯一用户标识
              - 回流定义：本次登录距离上一次登录 >= 90 天（且非首登）
              - 修正点：分别对活跃和充值在用户粒度预聚合，彻底消除 Join 膨胀 (Fan-out) 问题
              - 统计 7月1日~21日 分日的新增、回流及新增+回流合计
              - 包含截至 7月26日 当日剩余活跃人数、7月22~26日近5日活跃人数
              - 包含首日付费、截至 7月26日 累计付费人数、累计付费总额(USD)、累计LTV/ARPU
================================================================================
*/

WITH
-------------------------------------------------------
-- 1. 参数设置
-------------------------------------------------------
Params AS (
    SELECT
        DATE '2026-07-01' AS start_date,         -- 目标 Cohort 开始日期
        DATE '2026-07-21' AS end_date,           -- 目标 Cohort 结束日期
        DATE '2026-07-26' AS pay_active_end_date -- 付费与剩余活跃观察截止日期
),

-------------------------------------------------------
-- 2. 黑名单用户 (基于 #user_id 过滤)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 3. 用户全量活跃历史 (基于 uuid, 包含 login, charge, scroin_buy, srcoin_buy)
-------------------------------------------------------
DailyLogins AS (
    SELECT DISTINCT
        uuid AS user_id,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_12 v
    WHERE v."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
      AND v.uuid IS NOT NULL AND v.uuid <> ''
      AND v."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist WHERE "#user_id" IS NOT NULL)
),

-------------------------------------------------------
-- 4. 计算用户首次登录日期与上一次登录日期
-------------------------------------------------------
UserStatus AS (
    SELECT
        user_id,
        log_date,
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date ASC) AS prev_log_date,
        MIN(log_date) OVER (PARTITION BY user_id) AS first_log_date
    FROM DailyLogins
),

-------------------------------------------------------
-- 5. 划分 7月1日~21日 目标 Cohort (新增 / 90天回流)
-------------------------------------------------------
CohortUsers AS (
    SELECT
        s.user_id,
        s.log_date AS cohort_date,
        CASE
            WHEN s.log_date = s.first_log_date THEN 'new_user'
            WHEN s.prev_log_date IS NOT NULL AND DATE_DIFF('day', s.prev_log_date, s.log_date) >= 90 THEN 'return_user'
            ELSE 'other'
        END AS cohort_type
    FROM UserStatus s
    CROSS JOIN Params p
    WHERE s.log_date BETWEEN p.start_date AND p.end_date
),

-- 只保留 目标区间内的 新增 与 回流 用户
FilteredCohortUsers AS (
    SELECT *
    FROM CohortUsers
    WHERE cohort_type IN ('new_user', 'return_user')
),

-------------------------------------------------------
-- 6. 用户充值数据 (按用户及付费日期预聚合，避免膨胀)
-------------------------------------------------------
UserRevenue AS (
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
            (r."$part_event" = 'charge' AND r.pay_currency <> 'kuroko_pay' AND (r.sandbox = false OR r.sandbox IS NULL))
            OR r."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND r."$part_date" >= CAST(p.start_date AS VARCHAR)
      AND r."$part_date" <= CAST(p.pay_active_end_date AS VARCHAR)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r.uuid IS NOT NULL AND r.uuid <> ''
      AND r."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist WHERE "#user_id" IS NOT NULL)
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 7a. 预聚合 Cohort 用户的付费指标 (独立计算，无 Join 膨胀)
-------------------------------------------------------
UserCohortRevenue AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        SUM(CASE WHEN r.pay_date = c.cohort_date THEN r.rev_usd ELSE 0.0 END) AS rev_day0,
        MAX(CASE WHEN r.pay_date = c.cohort_date THEN 1 ELSE 0 END) AS is_pay_day0,
        SUM(COALESCE(r.rev_usd, 0.0)) AS cum_rev_to_26th,
        MAX(CASE WHEN r.pay_date IS NOT NULL THEN 1 ELSE 0 END) AS is_cum_pay_to_26th
    FROM FilteredCohortUsers c
    CROSS JOIN Params p
    LEFT JOIN UserRevenue r
        ON c.user_id = r.user_id
       AND r.pay_date >= c.cohort_date
       AND r.pay_date <= p.pay_active_end_date
    GROUP BY c.user_id, c.cohort_date, c.cohort_type
),

-------------------------------------------------------
-- 7b. 预聚合 Cohort 用户的剩余活跃指标 (独立计算，无 Join 膨胀)
-------------------------------------------------------
UserCohortActive AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        MAX(CASE WHEN l.log_date = p.pay_active_end_date THEN 1 ELSE 0 END) AS is_active_on_26th,
        MAX(CASE WHEN l.log_date BETWEEN DATE '2026-07-22' AND p.pay_active_end_date THEN 1 ELSE 0 END) AS is_active_recent_5d
    FROM FilteredCohortUsers c
    CROSS JOIN Params p
    LEFT JOIN DailyLogins l
        ON c.user_id = l.user_id
       AND l.log_date >= c.cohort_date
       AND l.log_date <= p.pay_active_end_date
    GROUP BY c.user_id, c.cohort_date, c.cohort_type
),

-------------------------------------------------------
-- 7c. 1:1 精确合并付费与活跃指标
-------------------------------------------------------
UserCohortStats AS (
    SELECT
        r.user_id,
        r.cohort_date,
        r.cohort_type,
        r.rev_day0,
        r.is_pay_day0,
        r.cum_rev_to_26th,
        r.is_cum_pay_to_26th,
        a.is_active_on_26th,
        a.is_active_recent_5d
    FROM UserCohortRevenue r
    INNER JOIN UserCohortActive a
        ON r.user_id = a.user_id
       AND r.cohort_date = a.cohort_date
       AND r.cohort_type = a.cohort_type
),

-------------------------------------------------------
-- 8. 扩展 Grouping Sets 聚合 (按日期、按用户类型及阶段汇总)
-------------------------------------------------------
CohortAgg AS (
    -- 分别统计 新用户 / 回流用户
    SELECT
        CAST(cohort_date AS VARCHAR) AS cohort_date_str,
        cohort_type,
        COUNT(DISTINCT user_id) AS cohort_users,
        
        -- 付费
        SUM(is_pay_day0) AS pay_users_day0,
        SUM(rev_day0) AS rev_day0,
        SUM(is_cum_pay_to_26th) AS cum_pay_users_to_26th,
        SUM(cum_rev_to_26th) AS cum_rev_to_26th,
        
        -- 剩余活跃
        SUM(is_active_on_26th) AS active_users_on_26th,
        SUM(is_active_recent_5d) AS active_users_recent_5d
    FROM UserCohortStats
    GROUP BY cohort_date, cohort_type
    
    UNION ALL
    
    -- 统计 新增 + 回流 合计 (按日)
    SELECT
        CAST(cohort_date AS VARCHAR) AS cohort_date_str,
        'new+return_total' AS cohort_type,
        COUNT(DISTINCT user_id) AS cohort_users,
        
        SUM(is_pay_day0) AS pay_users_day0,
        SUM(rev_day0) AS rev_day0,
        SUM(is_cum_pay_to_26th) AS cum_pay_users_to_26th,
        SUM(cum_rev_to_26th) AS cum_rev_to_26th,
        
        SUM(is_active_on_26th) AS active_users_on_26th,
        SUM(is_active_recent_5d) AS active_users_recent_5d
    FROM UserCohortStats
    GROUP BY cohort_date
    
    UNION ALL
    
    -- 统计 7月1日~21日 阶段全量汇总 (按用户类型)
    SELECT
        '【7月1日~21日 阶段汇总】' AS cohort_date_str,
        cohort_type,
        COUNT(DISTINCT user_id) AS cohort_users,
        
        SUM(is_pay_day0) AS pay_users_day0,
        SUM(rev_day0) AS rev_day0,
        SUM(is_cum_pay_to_26th) AS cum_pay_users_to_26th,
        SUM(cum_rev_to_26th) AS cum_rev_to_26th,
        
        SUM(is_active_on_26th) AS active_users_on_26th,
        SUM(is_active_recent_5d) AS active_users_recent_5d
    FROM UserCohortStats
    GROUP BY cohort_type
    
    UNION ALL
    
    -- 统计 7月1日~21日 阶段全量汇总 (新增+回流 总计)
    SELECT
        '【7月1日~21日 阶段汇总】' AS cohort_date_str,
        'new+return_total' AS cohort_type,
        COUNT(DISTINCT user_id) AS cohort_users,
        
        SUM(is_pay_day0) AS pay_users_day0,
        SUM(rev_day0) AS rev_day0,
        SUM(is_cum_pay_to_26th) AS cum_pay_users_to_26th,
        SUM(cum_rev_to_26th) AS cum_rev_to_26th,
        
        SUM(is_active_on_26th) AS active_users_on_26th,
        SUM(is_active_recent_5d) AS active_users_recent_5d
    FROM UserCohortStats
)

-------------------------------------------------------
-- 9. 格式化最终输出
-------------------------------------------------------
SELECT
    cohort_date_str AS "日期",
    CASE
        WHEN cohort_type = 'new_user' THEN '1. 新增用户'
        WHEN cohort_type = 'return_user' THEN '2. 回流用户(90天+)'
        WHEN cohort_type = 'new+return_total' THEN '3. 新增+回流合计'
    END AS "用户类型",
    
    cohort_users AS "获得用户数",
    
    -- 剩余活跃指标
    active_users_on_26th AS "7月26日当日剩余活跃人数",
    CAST(ROUND(TRY(CAST(active_users_on_26th AS DOUBLE) / NULLIF(cohort_users, 0) * 100), 2) AS VARCHAR) || '%' AS "7月26日剩余留存率",
    active_users_recent_5d AS "7月22~26日近5日活跃人数",
    CAST(ROUND(TRY(CAST(active_users_recent_5d AS DOUBLE) / NULLIF(cohort_users, 0) * 100), 2) AS VARCHAR) || '%' AS "7月22~26日近5日活跃率",
    
    -- 首日付费
    pay_users_day0 AS "首日付费人数",
    ROUND(rev_day0, 2) AS "首日充值金额(USD)",
    CAST(ROUND(TRY(CAST(pay_users_day0 AS DOUBLE) / NULLIF(cohort_users, 0) * 100), 2) AS VARCHAR) || '%' AS "首日付费率",
    
    -- 截至 7月26日 累计付费
    cum_pay_users_to_26th AS "截至26日累计付费人数",
    CAST(ROUND(TRY(CAST(cum_pay_users_to_26th AS DOUBLE) / NULLIF(cohort_users, 0) * 100), 2) AS VARCHAR) || '%' AS "截至26日累计付费率",
    ROUND(cum_rev_to_26th, 2) AS "截至26日总计付费金额(USD)",
    
    -- LTV / ARPU / ARPPU
    ROUND(TRY(cum_rev_to_26th / NULLIF(cohort_users, 0)), 2) AS "截至26日累计LTV(USD)",
    ROUND(TRY(cum_rev_to_26th / NULLIF(cum_pay_users_to_26th, 0)), 2) AS "截至26日累计ARPPU(USD)"

FROM CohortAgg
ORDER BY
    CASE WHEN cohort_date_str = '【7月1日~21日 阶段汇总】' THEN 1 ELSE 0 END,
    cohort_date_str ASC,
    CASE
        WHEN cohort_type = 'new_user' THEN 1
        WHEN cohort_type = 'return_user' THEN 2
        WHEN cohort_type = 'new+return_total' THEN 3
    END;
