-- =================================================================================================================
-- Game: Kuroko's Basketball
-- Region: KR (韩国)
-- Description: 2025年7月1日~2026年4月24日 新增与回流(90天/180天) LTV (1,3,7,14,30,60,90,180日) 看板
--              包含每日明细与阶段汇总，对于时间未达标的队列进行分母剔除
-- =================================================================================================================

WITH 
-------------------------------------------------------
-- 1. 黑名单逻辑 (Blacklist)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 每日登录记录与上一天登录 (回溯定义回流和新增)
-------------------------------------------------------
DailyLogins AS (
    SELECT DISTINCT 
        uuid AS user_id, 
        "$part_date" AS log_date
    FROM ta.v_event_12
    WHERE "$part_event" = 'login'
      AND "$part_date" >= '2023-01-01'
      AND uuid IS NOT NULL AND uuid <> ''
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

UserStatus AS (
    SELECT 
        user_id,
        log_date AS "$part_date",
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date ASC) AS prev_log_date,
        FIRST_VALUE(log_date) OVER (PARTITION BY user_id ORDER BY log_date ASC) AS first_log_date
    FROM DailyLogins
),

-------------------------------------------------------
-- 3. 定义 Cohort (新增 / 90天回流 / 180天回流)
-------------------------------------------------------
Cohorts AS (
    SELECT 
        user_id,
        "$part_date" AS cohort_date,
        CASE 
            WHEN "$part_date" = first_log_date THEN 'new_user'
            WHEN date_diff('day', CAST(prev_log_date AS DATE), CAST("$part_date" AS DATE)) >= 180 THEN 'return_180d'
            WHEN date_diff('day', CAST(prev_log_date AS DATE), CAST("$part_date" AS DATE)) >= 90 THEN 'return_90d'
            ELSE 'other'
        END AS cohort_type
    FROM UserStatus
    WHERE "$part_date" BETWEEN '2025-07-01' AND '2026-04-24'
),

FilteredCohorts AS (
    SELECT * 
    FROM Cohorts
    WHERE cohort_type IN ('new_user', 'return_90d', 'return_180d')
),

-------------------------------------------------------
-- 4. 充值数据 (Revenue)
-------------------------------------------------------
UserRevenue AS (
    SELECT 
        r.uuid AS user_id,
        r."$part_date" AS pay_date,
        r.pay_amount / COALESCE(ex.exchange, 1) AS rev_usd
    FROM ta.v_event_12 r
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
    WHERE r."$part_event" = 'charge'
      AND r."$part_date" >= '2025-07-01'
      AND (r.sandbox = false OR r.sandbox IS NULL)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r.uuid IS NOT NULL AND r.uuid <> ''
      AND r."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

-------------------------------------------------------
-- 5. 关联 Cohort 与充值，并计算距 Cohort Date 的天数
-------------------------------------------------------
CohortRevenue AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        -- 使用 current_date 判断当前的成熟天数
        date_diff('day', CAST(c.cohort_date AS DATE), current_date) AS mature_days,
        COALESCE(r.rev_usd, 0) AS rev_usd,
        date_diff('day', CAST(c.cohort_date AS DATE), CAST(r.pay_date AS DATE)) AS ltv_day
    FROM FilteredCohorts c
    LEFT JOIN UserRevenue r 
        ON c.user_id = r.user_id 
        AND r.pay_date >= c.cohort_date
),

-------------------------------------------------------
-- 6. 摊平每个用户在其 Cohort 下的 LTV
-------------------------------------------------------
UserLtvAgg AS (
    SELECT
        user_id,
        cohort_date,
        cohort_type,
        MAX(mature_days) AS mature_days,
        SUM(CASE WHEN ltv_day = 0 THEN rev_usd ELSE 0 END) AS rev_0,
        SUM(CASE WHEN ltv_day < 1 THEN rev_usd ELSE 0 END) AS rev_1,
        SUM(CASE WHEN ltv_day < 3 THEN rev_usd ELSE 0 END) AS rev_3,
        SUM(CASE WHEN ltv_day < 7 THEN rev_usd ELSE 0 END) AS rev_7,
        SUM(CASE WHEN ltv_day < 14 THEN rev_usd ELSE 0 END) AS rev_14,
        SUM(CASE WHEN ltv_day < 30 THEN rev_usd ELSE 0 END) AS rev_30,
        SUM(CASE WHEN ltv_day < 60 THEN rev_usd ELSE 0 END) AS rev_60,
        SUM(CASE WHEN ltv_day < 90 THEN rev_usd ELSE 0 END) AS rev_90,
        SUM(CASE WHEN ltv_day < 180 THEN rev_usd ELSE 0 END) AS rev_180
    FROM CohortRevenue
    GROUP BY 1, 2, 3
),

-------------------------------------------------------
-- 7. 按天/汇总聚合计算 (GROUPING SETS 阶段汇总)
-------------------------------------------------------
DailySummary AS (
    SELECT 
        cohort_date,
        
        -- ================== 新增用户 ==================
        COUNT(CASE WHEN cohort_type = 'new_user' THEN user_id END) AS new_users,
        SUM(CASE WHEN cohort_type = 'new_user' THEN rev_0 ELSE 0 END) AS new_rev_0,
        
        -- 分母判断：成熟天数 >= X 才能计入分母
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 0 THEN 1 ELSE 0 END) AS new_d1_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 0 THEN rev_1 ELSE 0 END) AS new_rev_1,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 2 THEN 1 ELSE 0 END) AS new_d3_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 2 THEN rev_3 ELSE 0 END) AS new_rev_3,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 6 THEN 1 ELSE 0 END) AS new_d7_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 6 THEN rev_7 ELSE 0 END) AS new_rev_7,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 13 THEN 1 ELSE 0 END) AS new_d14_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 13 THEN rev_14 ELSE 0 END) AS new_rev_14,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 29 THEN 1 ELSE 0 END) AS new_d30_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 29 THEN rev_30 ELSE 0 END) AS new_rev_30,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 59 THEN 1 ELSE 0 END) AS new_d60_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 59 THEN rev_60 ELSE 0 END) AS new_rev_60,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 89 THEN 1 ELSE 0 END) AS new_d90_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 89 THEN rev_90 ELSE 0 END) AS new_rev_90,
        
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 179 THEN 1 ELSE 0 END) AS new_d180_den,
        SUM(CASE WHEN cohort_type = 'new_user' AND mature_days >= 179 THEN rev_180 ELSE 0 END) AS new_rev_180,

        -- ================== 90天回流 ==================
        COUNT(CASE WHEN cohort_type = 'return_90d' THEN user_id END) AS ret90_users,
        SUM(CASE WHEN cohort_type = 'return_90d' THEN rev_0 ELSE 0 END) AS ret90_rev_0,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 0 THEN 1 ELSE 0 END) AS ret90_d1_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 0 THEN rev_1 ELSE 0 END) AS ret90_rev_1,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 2 THEN 1 ELSE 0 END) AS ret90_d3_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 2 THEN rev_3 ELSE 0 END) AS ret90_rev_3,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 6 THEN 1 ELSE 0 END) AS ret90_d7_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 6 THEN rev_7 ELSE 0 END) AS ret90_rev_7,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 13 THEN 1 ELSE 0 END) AS ret90_d14_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 13 THEN rev_14 ELSE 0 END) AS ret90_rev_14,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 29 THEN 1 ELSE 0 END) AS ret90_d30_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 29 THEN rev_30 ELSE 0 END) AS ret90_rev_30,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 59 THEN 1 ELSE 0 END) AS ret90_d60_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 59 THEN rev_60 ELSE 0 END) AS ret90_rev_60,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 89 THEN 1 ELSE 0 END) AS ret90_d90_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 89 THEN rev_90 ELSE 0 END) AS ret90_rev_90,
        
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 179 THEN 1 ELSE 0 END) AS ret90_d180_den,
        SUM(CASE WHEN cohort_type = 'return_90d' AND mature_days >= 179 THEN rev_180 ELSE 0 END) AS ret90_rev_180,

        -- ================== 180天回流 ==================
        COUNT(CASE WHEN cohort_type = 'return_180d' THEN user_id END) AS ret180_users,
        SUM(CASE WHEN cohort_type = 'return_180d' THEN rev_0 ELSE 0 END) AS ret180_rev_0,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 0 THEN 1 ELSE 0 END) AS ret180_d1_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 0 THEN rev_1 ELSE 0 END) AS ret180_rev_1,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 2 THEN 1 ELSE 0 END) AS ret180_d3_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 2 THEN rev_3 ELSE 0 END) AS ret180_rev_3,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 6 THEN 1 ELSE 0 END) AS ret180_d7_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 6 THEN rev_7 ELSE 0 END) AS ret180_rev_7,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 13 THEN 1 ELSE 0 END) AS ret180_d14_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 13 THEN rev_14 ELSE 0 END) AS ret180_rev_14,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 29 THEN 1 ELSE 0 END) AS ret180_d30_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 29 THEN rev_30 ELSE 0 END) AS ret180_rev_30,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 59 THEN 1 ELSE 0 END) AS ret180_d60_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 59 THEN rev_60 ELSE 0 END) AS ret180_rev_60,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 89 THEN 1 ELSE 0 END) AS ret180_d90_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 89 THEN rev_90 ELSE 0 END) AS ret180_rev_90,
        
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 179 THEN 1 ELSE 0 END) AS ret180_d180_den,
        SUM(CASE WHEN cohort_type = 'return_180d' AND mature_days >= 179 THEN rev_180 ELSE 0 END) AS ret180_rev_180
    FROM UserLtvAgg
    GROUP BY 
        GROUPING SETS (
            (cohort_date),
            ()
        )
)

SELECT 
    COALESCE(cohort_date, '【阶段汇总】') AS "日期",
    
    -- ================== 新增 ==================
    new_users AS "新增用户",
    new_rev_0 AS "新增用户流水",
    TRY(new_rev_1 / NULLIF(new_d1_den, 0)) AS "新增用户LTV1",
    TRY(new_rev_3 / NULLIF(new_d3_den, 0)) AS "新增用户LTV3",
    TRY(new_rev_7 / NULLIF(new_d7_den, 0)) AS "新增用户LTV7",
    TRY(new_rev_14 / NULLIF(new_d14_den, 0)) AS "新增用户LTV14",
    TRY(new_rev_30 / NULLIF(new_d30_den, 0)) AS "新增用户LTV30",
    TRY(new_rev_60 / NULLIF(new_d60_den, 0)) AS "新增用户LTV60",
    TRY(new_rev_90 / NULLIF(new_d90_den, 0)) AS "新增用户LTV90",
    TRY(new_rev_180 / NULLIF(new_d180_den, 0)) AS "新增用户LTV180",
    
    -- ================== 90天回流 ==================
    ret90_users AS "回流用户（90天未登陆）",
    ret90_rev_0 AS "回流用户（90天未登录的流水）",
    TRY(ret90_rev_1 / NULLIF(ret90_d1_den, 0)) AS "回流用户（90天未登陆）LTV1",
    TRY(ret90_rev_3 / NULLIF(ret90_d3_den, 0)) AS "回流用户（90天未登陆）LTV3",
    TRY(ret90_rev_7 / NULLIF(ret90_d7_den, 0)) AS "回流用户（90天未登陆）LTV7",
    TRY(ret90_rev_14 / NULLIF(ret90_d14_den, 0)) AS "回流用户（90天未登陆）LTV14",
    TRY(ret90_rev_30 / NULLIF(ret90_d30_den, 0)) AS "回流用户（90天未登陆）LTV30",
    TRY(ret90_rev_60 / NULLIF(ret90_d60_den, 0)) AS "回流用户（90天未登陆）LTV60",
    TRY(ret90_rev_90 / NULLIF(ret90_d90_den, 0)) AS "回流用户（90天未登陆）LTV90",
    TRY(ret90_rev_180 / NULLIF(ret90_d180_den, 0)) AS "回流用户（90天未登陆）LTV180",
    
    -- ================== 180天回流 ==================
    ret180_users AS "回流用户（180天未登陆）",
    ret180_rev_0 AS "回流用户（180天未登录的流水）",
    TRY(ret180_rev_1 / NULLIF(ret180_d1_den, 0)) AS "回流用户（180天未登陆）LTV1",
    TRY(ret180_rev_3 / NULLIF(ret180_d3_den, 0)) AS "回流用户（180天未登陆）LTV3",
    TRY(ret180_rev_7 / NULLIF(ret180_d7_den, 0)) AS "回流用户（180天未登陆）LTV7",
    TRY(ret180_rev_14 / NULLIF(ret180_d14_den, 0)) AS "回流用户（180天未登陆）LTV14",
    TRY(ret180_rev_30 / NULLIF(ret180_d30_den, 0)) AS "回流用户（180天未登陆）LTV30",
    TRY(ret180_rev_60 / NULLIF(ret180_d60_den, 0)) AS "回流用户（180天未登陆）LTV60",
    TRY(ret180_rev_90 / NULLIF(ret180_d90_den, 0)) AS "回流用户（180天未登陆）LTV90",
    TRY(ret180_rev_180 / NULLIF(ret180_d180_den, 0)) AS "回流用户（180天未登陆）LTV180"

FROM DailySummary
ORDER BY 
    CASE WHEN cohort_date IS NULL THEN 0 ELSE 1 END, 
    cohort_date DESC;
