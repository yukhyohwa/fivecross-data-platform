/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 2026-07-01 ~ 2026-07-14 每日各群组用户（新用户、回流90天、老用户、新+回流）的 LTV 追踪
             - 使用 uuid 作为唯一标识
             - 包含 LTV1, LTV2, LTV3, LTV4, LTV5, LTV6, LTV7, LTV14, LTV30, LTV60
             - 当前日期未成熟的 LTV 数据会自动留空 (NULL)
================================================================================
*/

WITH Params AS (
    -- 适配 TA (数数) 自定义时间宏，在后台界面直接选择区间
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS start_date,
        MAX(CAST("$part_date" AS DATE)) AS end_date,
        -- 使用 CURRENT_DATE 动态获取当前系统日期，用来判定 LTV 未成熟的天数并留空
        CURRENT_DATE AS data_end_date
    FROM ta.v_event_12
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
),

-- 1. 获取所有用户活跃日志 (包含 login, charge, scroin_buy, srcoin_buy)
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

-- 2. 划分每日群组类型
CohortUsers AS (
    SELECT
        user_id,
        log_date AS cohort_date,
        CASE
            WHEN log_date = first_log_date THEN 'new'
            WHEN prev_log_date IS NOT NULL AND DATE_DIFF('day', prev_log_date, log_date) >= 90 THEN 'return'
            ELSE 'old'
        END AS cohort_type
    FROM UserStatus
    CROSS JOIN Params p
    WHERE log_date BETWEEN p.start_date AND p.end_date
),

-- 3. 获取相关流水 (取 start_date 到 data_end_date 内的所有流水)
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
            (r."$part_event" = 'charge' AND (r.sandbox = false OR r.sandbox IS NULL))
            OR r."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND r."$part_date" >= CAST(p.start_date AS VARCHAR)
      AND r."$part_date" <= CAST(p.data_end_date AS VARCHAR)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r.uuid IS NOT NULL
      AND r.uuid <> ''
    GROUP BY 1, 2
),

-- 4. 关联流水与群组天数
CohortRevenue AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        DATE_DIFF('day', c.cohort_date, p.data_end_date) AS mature_days,
        COALESCE(r.rev_usd, 0.0) AS rev_usd,
        DATE_DIFF('day', c.cohort_date, r.pay_date) AS ltv_day
    FROM CohortUsers c
    CROSS JOIN Params p
    LEFT JOIN UserRevenue r
        ON c.user_id = r.user_id
       AND r.pay_date >= c.cohort_date
       AND DATE_DIFF('day', c.cohort_date, r.pay_date) <= 59 -- LTV60 只需要 day 0 到 day 59 的充值
),

-- 5. 计算每个用户的各阶段 LTV 累计
UserLtvAgg AS (
    SELECT
        user_id,
        cohort_date,
        cohort_type,
        MAX(mature_days) AS mature_days,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 0 THEN rev_usd ELSE 0.0 END) AS rev_ltv1,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 1 THEN rev_usd ELSE 0.0 END) AS rev_ltv2,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 2 THEN rev_usd ELSE 0.0 END) AS rev_ltv3,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 3 THEN rev_usd ELSE 0.0 END) AS rev_ltv4,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 4 THEN rev_usd ELSE 0.0 END) AS rev_ltv5,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 5 THEN rev_usd ELSE 0.0 END) AS rev_ltv6,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 6 THEN rev_usd ELSE 0.0 END) AS rev_ltv7,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 13 THEN rev_usd ELSE 0.0 END) AS rev_ltv14,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 29 THEN rev_usd ELSE 0.0 END) AS rev_ltv30,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 59 THEN rev_usd ELSE 0.0 END) AS rev_ltv60
    FROM CohortRevenue
    GROUP BY 1, 2, 3
),

-- 6. 聚合为按群组计算的总量 (这里包含新用户、回流、老用户，以及特殊组合)
CohortAggregation AS (
    -- 分别聚合新用户、回流用户、老用户
    SELECT
        cohort_date,
        cohort_type,
        COUNT(DISTINCT user_id) AS users,
        MAX(mature_days) AS mature_days,
        SUM(rev_ltv1) AS total_rev_ltv1,
        SUM(rev_ltv2) AS total_rev_ltv2,
        SUM(rev_ltv3) AS total_rev_ltv3,
        SUM(rev_ltv4) AS total_rev_ltv4,
        SUM(rev_ltv5) AS total_rev_ltv5,
        SUM(rev_ltv6) AS total_rev_ltv6,
        SUM(rev_ltv7) AS total_rev_ltv7,
        SUM(rev_ltv14) AS total_rev_ltv14,
        SUM(rev_ltv30) AS total_rev_ltv30,
        SUM(rev_ltv60) AS total_rev_ltv60
    FROM UserLtvAgg
    GROUP BY 1, 2
    
    UNION ALL
    
    -- 聚合合并组：新用户 + 回流用户
    SELECT
        cohort_date,
        'new+return' AS cohort_type,
        COUNT(DISTINCT user_id) AS users,
        MAX(mature_days) AS mature_days,
        SUM(rev_ltv1) AS total_rev_ltv1,
        SUM(rev_ltv2) AS total_rev_ltv2,
        SUM(rev_ltv3) AS total_rev_ltv3,
        SUM(rev_ltv4) AS total_rev_ltv4,
        SUM(rev_ltv5) AS total_rev_ltv5,
        SUM(rev_ltv6) AS total_rev_ltv6,
        SUM(rev_ltv7) AS total_rev_ltv7,
        SUM(rev_ltv14) AS total_rev_ltv14,
        SUM(rev_ltv30) AS total_rev_ltv30,
        SUM(rev_ltv60) AS total_rev_ltv60
    FROM UserLtvAgg
    WHERE cohort_type IN ('new', 'return')
    GROUP BY 1
),

-- 7. 格式化最终输出
FinalOutput AS (
    SELECT
        CAST(cohort_date AS VARCHAR) AS "日期",
        CASE 
            WHEN cohort_type = 'new' THEN '1.新用户'
            WHEN cohort_type = 'return' THEN '2.回流用户(90天)'
            WHEN cohort_type = 'new+return' THEN '3.新用户+回流用户'
            WHEN cohort_type = 'old' THEN '4.老用户'
        END AS "用户类型",
        users AS "人数",
        
        -- LTV (人均累计营收)
        -- 使用 mature_days 判断是否成熟，不成熟的天数输出为 NULL
        CASE WHEN mature_days >= 0 THEN ROUND(TRY(total_rev_ltv1 / NULLIF(users, 0)), 2) END AS "LTV1",
        CASE WHEN mature_days >= 1 THEN ROUND(TRY(total_rev_ltv2 / NULLIF(users, 0)), 2) END AS "LTV2",
        CASE WHEN mature_days >= 2 THEN ROUND(TRY(total_rev_ltv3 / NULLIF(users, 0)), 2) END AS "LTV3",
        CASE WHEN mature_days >= 3 THEN ROUND(TRY(total_rev_ltv4 / NULLIF(users, 0)), 2) END AS "LTV4",
        CASE WHEN mature_days >= 4 THEN ROUND(TRY(total_rev_ltv5 / NULLIF(users, 0)), 2) END AS "LTV5",
        CASE WHEN mature_days >= 5 THEN ROUND(TRY(total_rev_ltv6 / NULLIF(users, 0)), 2) END AS "LTV6",
        CASE WHEN mature_days >= 6 THEN ROUND(TRY(total_rev_ltv7 / NULLIF(users, 0)), 2) END AS "LTV7",
        CASE WHEN mature_days >= 13 THEN ROUND(TRY(total_rev_ltv14 / NULLIF(users, 0)), 2) END AS "LTV14",
        CASE WHEN mature_days >= 29 THEN ROUND(TRY(total_rev_ltv30 / NULLIF(users, 0)), 2) END AS "LTV30",
        CASE WHEN mature_days >= 59 THEN ROUND(TRY(total_rev_ltv60 / NULLIF(users, 0)), 2) END AS "LTV60"
    FROM CohortAggregation
)

SELECT * FROM FinalOutput
ORDER BY "日期", "用户类型";
