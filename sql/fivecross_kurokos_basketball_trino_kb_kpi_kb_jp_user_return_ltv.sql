/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 每日14日与30日回流用户及氪金LTV看板
             1. 14日回流：距离上次登录超过 14 天
             2. 30日回流：距离上次登录超过 30 天 (包含在14日回流中)
             3. LTV 维度: 1,2,3,4,5,6,7,14,30,60,90,120,150,180,270,360
================================================================================
*/

WITH 
-------------------------------------------------------
-- 1. 黑名单逻辑
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 每日登录记录与上一天登录 (回溯定义回流)
-------------------------------------------------------
DailyLogins AS (
    SELECT DISTINCT 
        "#user_id" AS user_id, 
        "$part_date" AS log_date
    FROM ta.v_event_9
    WHERE "$part_event" = 'login'
      AND "$part_date" >= '2023-11-15' 
      AND "#user_id" IS NOT NULL
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

UserStatus AS (
    SELECT 
        user_id,
        log_date AS "$part_date",
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date ASC) AS prev_log_date
    FROM DailyLogins
),

-------------------------------------------------------
-- 3. 筛选回流 Cohort (至少 >= 14天的才进入计算)
-------------------------------------------------------
ReturnCohorts AS (
    SELECT 
        user_id,
        "$part_date",
        date_diff('day', CAST(prev_log_date AS DATE), CAST("$part_date" AS DATE)) AS diff_days
    FROM UserStatus
    WHERE prev_log_date IS NOT NULL
      AND date_diff('day', CAST(prev_log_date AS DATE), CAST("$part_date" AS DATE)) >= 14
),

-------------------------------------------------------
-- 4. 计算这些回流用户的 LTV (关联充值表)
-------------------------------------------------------
UserLtvRaw AS (
    SELECT
        c.user_id,
        c."$part_date",
        c.diff_days,
        r.pay_amount / COALESCE(ex.exchange, 1) AS rev_usd,
        date_diff('day', CAST(c."$part_date" AS DATE), CAST(r."$part_date" AS DATE)) AS ltv_day
    FROM ReturnCohorts c
    LEFT JOIN ta.v_event_9 r 
        ON c.user_id = r."#user_id" 
        AND r."$part_event" = 'charge'
        AND r."$part_date" >= c."$part_date"
        AND (r.sandbox = false OR r.sandbox IS NULL)
        AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
),

UserLtvAgg AS (
    SELECT
        user_id,
        "$part_date",
        diff_days,
        SUM(CASE WHEN ltv_day < 1 THEN rev_usd ELSE 0 END) AS rev_1,
        SUM(CASE WHEN ltv_day < 2 THEN rev_usd ELSE 0 END) AS rev_2,
        SUM(CASE WHEN ltv_day < 3 THEN rev_usd ELSE 0 END) AS rev_3,
        SUM(CASE WHEN ltv_day < 4 THEN rev_usd ELSE 0 END) AS rev_4,
        SUM(CASE WHEN ltv_day < 5 THEN rev_usd ELSE 0 END) AS rev_5,
        SUM(CASE WHEN ltv_day < 6 THEN rev_usd ELSE 0 END) AS rev_6,
        SUM(CASE WHEN ltv_day < 7 THEN rev_usd ELSE 0 END) AS rev_7,
        SUM(CASE WHEN ltv_day < 14 THEN rev_usd ELSE 0 END) AS rev_14,
        SUM(CASE WHEN ltv_day < 30 THEN rev_usd ELSE 0 END) AS rev_30,
        SUM(CASE WHEN ltv_day < 60 THEN rev_usd ELSE 0 END) AS rev_60,
        SUM(CASE WHEN ltv_day < 90 THEN rev_usd ELSE 0 END) AS rev_90,
        SUM(CASE WHEN ltv_day < 120 THEN rev_usd ELSE 0 END) AS rev_120,
        SUM(CASE WHEN ltv_day < 150 THEN rev_usd ELSE 0 END) AS rev_150,
        SUM(CASE WHEN ltv_day < 180 THEN rev_usd ELSE 0 END) AS rev_180,
        SUM(CASE WHEN ltv_day < 270 THEN rev_usd ELSE 0 END) AS rev_270,
        SUM(CASE WHEN ltv_day < 360 THEN rev_usd ELSE 0 END) AS rev_360
    FROM UserLtvRaw
    GROUP BY 1, 2, 3
),

-------------------------------------------------------
-- 5. 按天汇总 14日/30日 维度
-------------------------------------------------------
DailyStats AS (
    SELECT 
        "$part_date",
        
        -- 14天回流
        COUNT(DISTINCT CASE WHEN diff_days >= 14 THEN user_id END) AS uu_14d,
        SUM(CASE WHEN diff_days >= 14 THEN rev_1 ELSE 0 END) AS r14_rev_1,
        SUM(CASE WHEN diff_days >= 14 THEN rev_2 ELSE 0 END) AS r14_rev_2,
        SUM(CASE WHEN diff_days >= 14 THEN rev_3 ELSE 0 END) AS r14_rev_3,
        SUM(CASE WHEN diff_days >= 14 THEN rev_4 ELSE 0 END) AS r14_rev_4,
        SUM(CASE WHEN diff_days >= 14 THEN rev_5 ELSE 0 END) AS r14_rev_5,
        SUM(CASE WHEN diff_days >= 14 THEN rev_6 ELSE 0 END) AS r14_rev_6,
        SUM(CASE WHEN diff_days >= 14 THEN rev_7 ELSE 0 END) AS r14_rev_7,
        SUM(CASE WHEN diff_days >= 14 THEN rev_14 ELSE 0 END) AS r14_rev_14,
        SUM(CASE WHEN diff_days >= 14 THEN rev_30 ELSE 0 END) AS r14_rev_30,
        SUM(CASE WHEN diff_days >= 14 THEN rev_60 ELSE 0 END) AS r14_rev_60,
        SUM(CASE WHEN diff_days >= 14 THEN rev_90 ELSE 0 END) AS r14_rev_90,
        SUM(CASE WHEN diff_days >= 14 THEN rev_120 ELSE 0 END) AS r14_rev_120,
        SUM(CASE WHEN diff_days >= 14 THEN rev_150 ELSE 0 END) AS r14_rev_150,
        SUM(CASE WHEN diff_days >= 14 THEN rev_180 ELSE 0 END) AS r14_rev_180,
        SUM(CASE WHEN diff_days >= 14 THEN rev_270 ELSE 0 END) AS r14_rev_270,
        SUM(CASE WHEN diff_days >= 14 THEN rev_360 ELSE 0 END) AS r14_rev_360,

        -- 30天回流
        COUNT(DISTINCT CASE WHEN diff_days >= 30 THEN user_id END) AS uu_30d,
        SUM(CASE WHEN diff_days >= 30 THEN rev_1 ELSE 0 END) AS r30_rev_1,
        SUM(CASE WHEN diff_days >= 30 THEN rev_2 ELSE 0 END) AS r30_rev_2,
        SUM(CASE WHEN diff_days >= 30 THEN rev_3 ELSE 0 END) AS r30_rev_3,
        SUM(CASE WHEN diff_days >= 30 THEN rev_4 ELSE 0 END) AS r30_rev_4,
        SUM(CASE WHEN diff_days >= 30 THEN rev_5 ELSE 0 END) AS r30_rev_5,
        SUM(CASE WHEN diff_days >= 30 THEN rev_6 ELSE 0 END) AS r30_rev_6,
        SUM(CASE WHEN diff_days >= 30 THEN rev_7 ELSE 0 END) AS r30_rev_7,
        SUM(CASE WHEN diff_days >= 30 THEN rev_14 ELSE 0 END) AS r30_rev_14,
        SUM(CASE WHEN diff_days >= 30 THEN rev_30 ELSE 0 END) AS r30_rev_30,
        SUM(CASE WHEN diff_days >= 30 THEN rev_60 ELSE 0 END) AS r30_rev_60,
        SUM(CASE WHEN diff_days >= 30 THEN rev_90 ELSE 0 END) AS r30_rev_90,
        SUM(CASE WHEN diff_days >= 30 THEN rev_120 ELSE 0 END) AS r30_rev_120,
        SUM(CASE WHEN diff_days >= 30 THEN rev_150 ELSE 0 END) AS r30_rev_150,
        SUM(CASE WHEN diff_days >= 30 THEN rev_180 ELSE 0 END) AS r30_rev_180,
        SUM(CASE WHEN diff_days >= 30 THEN rev_270 ELSE 0 END) AS r30_rev_270,
        SUM(CASE WHEN diff_days >= 30 THEN rev_360 ELSE 0 END) AS r30_rev_360
    FROM UserLtvAgg
    WHERE ${PartDate:date1}
    GROUP BY 1
)

-------------------------------------------------------
-- 6. 最终输出计算结果
-------------------------------------------------------
SELECT 
    "$part_date" AS "日期",
    
    -- 14日回流
    uu_14d AS "流失14天回流的用户",
    TRY(CAST(r14_rev_1 AS DOUBLE) / uu_14d) AS "14d回流_LTV1",
    TRY(CAST(r14_rev_2 AS DOUBLE) / uu_14d) AS "14d回流_LTV2",
    TRY(CAST(r14_rev_3 AS DOUBLE) / uu_14d) AS "14d回流_LTV3",
    TRY(CAST(r14_rev_4 AS DOUBLE) / uu_14d) AS "14d回流_LTV4",
    TRY(CAST(r14_rev_5 AS DOUBLE) / uu_14d) AS "14d回流_LTV5",
    TRY(CAST(r14_rev_6 AS DOUBLE) / uu_14d) AS "14d回流_LTV6",
    TRY(CAST(r14_rev_7 AS DOUBLE) / uu_14d) AS "14d回流_LTV7",
    TRY(CAST(r14_rev_14 AS DOUBLE) / uu_14d) AS "14d回流_LTV14",
    TRY(CAST(r14_rev_30 AS DOUBLE) / uu_14d) AS "14d回流_LTV30",
    TRY(CAST(r14_rev_60 AS DOUBLE) / uu_14d) AS "14d回流_LTV60",
    TRY(CAST(r14_rev_90 AS DOUBLE) / uu_14d) AS "14d回流_LTV90",
    TRY(CAST(r14_rev_120 AS DOUBLE) / uu_14d) AS "14d回流_LTV120",
    TRY(CAST(r14_rev_150 AS DOUBLE) / uu_14d) AS "14d回流_LTV150",
    TRY(CAST(r14_rev_180 AS DOUBLE) / uu_14d) AS "14d回流_LTV180",
    TRY(CAST(r14_rev_270 AS DOUBLE) / uu_14d) AS "14d回流_LTV270",
    TRY(CAST(r14_rev_360 AS DOUBLE) / uu_14d) AS "14d回流_LTV360",

    -- 30日回流
    uu_30d AS "流失30天回流的用户",
    TRY(CAST(r30_rev_1 AS DOUBLE) / uu_30d) AS "30d回流_LTV1",
    TRY(CAST(r30_rev_2 AS DOUBLE) / uu_30d) AS "30d回流_LTV2",
    TRY(CAST(r30_rev_3 AS DOUBLE) / uu_30d) AS "30d回流_LTV3",
    TRY(CAST(r30_rev_4 AS DOUBLE) / uu_30d) AS "30d回流_LTV4",
    TRY(CAST(r30_rev_5 AS DOUBLE) / uu_30d) AS "30d回流_LTV5",
    TRY(CAST(r30_rev_6 AS DOUBLE) / uu_30d) AS "30d回流_LTV6",
    TRY(CAST(r30_rev_7 AS DOUBLE) / uu_30d) AS "30d回流_LTV7",
    TRY(CAST(r30_rev_14 AS DOUBLE) / uu_30d) AS "30d回流_LTV14",
    TRY(CAST(r30_rev_30 AS DOUBLE) / uu_30d) AS "30d回流_LTV30",
    TRY(CAST(r30_rev_60 AS DOUBLE) / uu_30d) AS "30d回流_LTV60",
    TRY(CAST(r30_rev_90 AS DOUBLE) / uu_30d) AS "30d回流_LTV90",
    TRY(CAST(r30_rev_120 AS DOUBLE) / uu_30d) AS "30d回流_LTV120",
    TRY(CAST(r30_rev_150 AS DOUBLE) / uu_30d) AS "30d回流_LTV150",
    TRY(CAST(r30_rev_180 AS DOUBLE) / uu_30d) AS "30d回流_LTV180",
    TRY(CAST(r30_rev_270 AS DOUBLE) / uu_30d) AS "30d回流_LTV270",
    TRY(CAST(r30_rev_360 AS DOUBLE) / uu_30d) AS "30d回流_LTV360"

FROM DailyStats
ORDER BY 1 DESC;
