/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 回流用户 LTV (动态选择 14日/30日)
             可选项: 14d回流还是30d回流, 参数为 ${Selector:selector2}
             LTV 维度: 1, 2, 3, 4, 5, 6, 7, 14, 30, 60, 90, 180, 360
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
-- 3. 筛选回流 Cohort (根据选择的参数: 14 或 30)
-------------------------------------------------------
ReturnCohorts AS (
    SELECT 
        user_id,
        "$part_date",
        date_diff('day', CAST(prev_log_date AS DATE), CAST("$part_date" AS DATE)) AS diff_days
    FROM UserStatus
    WHERE prev_log_date IS NOT NULL
      AND date_diff('day', CAST(prev_log_date AS DATE), CAST("$part_date" AS DATE)) >= ${Selector:selector2}
),

-------------------------------------------------------
-- 4. 计算这些回流用户的 LTV (关联充值表)
-------------------------------------------------------
UserLtvRaw AS (
    SELECT
        c.user_id,
        c."$part_date",
        (r.pay_amount / COALESCE(ex.exchange, 1)) * COALESCE(ex_jpy.exchange, 150) AS rev_jpy,
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
    LEFT JOIN (
        SELECT ex_date, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        WHERE currency = 'JPY'
        GROUP BY 1
    ) ex_jpy ON r."$part_date" = ex_jpy.ex_date
),

UserLtvAgg AS (
    SELECT
        user_id,
        "$part_date",
        SUM(CASE WHEN ltv_day < 1 THEN rev_jpy ELSE 0 END) AS rev_1,
        SUM(CASE WHEN ltv_day < 2 THEN rev_jpy ELSE 0 END) AS rev_2,
        SUM(CASE WHEN ltv_day < 3 THEN rev_jpy ELSE 0 END) AS rev_3,
        SUM(CASE WHEN ltv_day < 4 THEN rev_jpy ELSE 0 END) AS rev_4,
        SUM(CASE WHEN ltv_day < 5 THEN rev_jpy ELSE 0 END) AS rev_5,
        SUM(CASE WHEN ltv_day < 6 THEN rev_jpy ELSE 0 END) AS rev_6,
        SUM(CASE WHEN ltv_day < 7 THEN rev_jpy ELSE 0 END) AS rev_7,
        SUM(CASE WHEN ltv_day < 14 THEN rev_jpy ELSE 0 END) AS rev_14,
        SUM(CASE WHEN ltv_day < 30 THEN rev_jpy ELSE 0 END) AS rev_30,
        SUM(CASE WHEN ltv_day < 60 THEN rev_jpy ELSE 0 END) AS rev_60,
        SUM(CASE WHEN ltv_day < 90 THEN rev_jpy ELSE 0 END) AS rev_90,
        SUM(CASE WHEN ltv_day < 180 THEN rev_jpy ELSE 0 END) AS rev_180,
        SUM(CASE WHEN ltv_day < 360 THEN rev_jpy ELSE 0 END) AS rev_360
    FROM UserLtvRaw
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 5. 按天汇总
-------------------------------------------------------
DailyStats AS (
    SELECT 
        "$part_date",
        COUNT(DISTINCT user_id) AS uu_return,
        SUM(rev_1) AS total_rev_1,
        SUM(rev_2) AS total_rev_2,
        SUM(rev_3) AS total_rev_3,
        SUM(rev_4) AS total_rev_4,
        SUM(rev_5) AS total_rev_5,
        SUM(rev_6) AS total_rev_6,
        SUM(rev_7) AS total_rev_7,
        SUM(rev_14) AS total_rev_14,
        SUM(rev_30) AS total_rev_30,
        SUM(rev_60) AS total_rev_60,
        SUM(rev_90) AS total_rev_90,
        SUM(rev_180) AS total_rev_180,
        SUM(rev_360) AS total_rev_360
    FROM UserLtvAgg
    WHERE ${PartDate:date1}
    GROUP BY 1
)

-------------------------------------------------------
-- 6. 最终输出计算结果
-------------------------------------------------------
SELECT 
    "$part_date" AS "日期",
    uu_return AS "回流用户数",
    TRY(CAST(total_rev_1 AS DOUBLE) / uu_return) AS "回流_LTV1",
    TRY(CAST(total_rev_2 AS DOUBLE) / uu_return) AS "回流_LTV2",
    TRY(CAST(total_rev_3 AS DOUBLE) / uu_return) AS "回流_LTV3",
    TRY(CAST(total_rev_4 AS DOUBLE) / uu_return) AS "回流_LTV4",
    TRY(CAST(total_rev_5 AS DOUBLE) / uu_return) AS "回流_LTV5",
    TRY(CAST(total_rev_6 AS DOUBLE) / uu_return) AS "回流_LTV6",
    TRY(CAST(total_rev_7 AS DOUBLE) / uu_return) AS "回流_LTV7",
    TRY(CAST(total_rev_14 AS DOUBLE) / uu_return) AS "回流_LTV14",
    TRY(CAST(total_rev_30 AS DOUBLE) / uu_return) AS "回流_LTV30",
    TRY(CAST(total_rev_60 AS DOUBLE) / uu_return) AS "回流_LTV60",
    TRY(CAST(total_rev_90 AS DOUBLE) / uu_return) AS "回流_LTV90",
    TRY(CAST(total_rev_180 AS DOUBLE) / uu_return) AS "回流_LTV180",
    TRY(CAST(total_rev_360 AS DOUBLE) / uu_return) AS "回流_LTV360"
FROM DailyStats
ORDER BY 1 DESC;
