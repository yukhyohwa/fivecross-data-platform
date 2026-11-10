/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 黑子JP 每日分R登录人数
             自定义时间范围内的活跃用户按历史累计充值分段（日元）进行分类统计。
             R分段：
             300万以上
             200万~300万
             100万~200万
             500000~999999
             200000~499999
             50000~199999
             20000~49999
             5000~19999
             2000~4999
             1~1999
             0
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
-- 2. 每日登录用户 (自定义时间范围)
-------------------------------------------------------
DailyLogins AS (
    SELECT 
        s1."$part_date" AS log_date,
        s1.uuid
    FROM ta.v_event_9 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND ${PartDate:date1}
      AND b."#user_id" IS NULL
      AND s1.uuid IS NOT NULL AND s1.uuid <> ''
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 3. 登录用户的历史充值记录 (包含登录当日及以前的所有充值，转化为JPY)
-------------------------------------------------------
UserRecharge AS (
    SELECT 
        c.uuid,
        c."$part_date" AS charge_date,
        SUM( (c.pay_amount / COALESCE(ex.exchange, 1)) * COALESCE(ex_jpy.exchange, 150) ) AS daily_charge_jpy
    FROM ta.v_event_9 c
    -- 仅关联所选时间范围内登录过的用户，减小数据量
    INNER JOIN (SELECT DISTINCT uuid FROM DailyLogins) u 
        ON c.uuid = u.uuid
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON c."$part_date" = ex.ex_date AND c.pay_currency = ex.currency
    LEFT JOIN (
        SELECT ex_date, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        WHERE currency = 'JPY'
        GROUP BY 1
    ) ex_jpy ON c."$part_date" = ex_jpy.ex_date
    WHERE c."$part_event" = 'charge'
      AND (c.sandbox = false OR c.sandbox IS NULL)
      AND (c.order_id NOT IN ('11') OR c.order_id IS NULL)
      AND c.pay_currency <> 'kuroko_pay'
      AND c.uuid IS NOT NULL AND c.uuid <> ''
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 4. 计算每日登录用户在当天的历史累计充值 (JPY)
-------------------------------------------------------
DailyUserHistoricalCharge AS (
    SELECT 
        l.log_date,
        l.uuid,
        COALESCE(SUM(r.daily_charge_jpy), 0) AS historical_charge_jpy
    FROM DailyLogins l
    LEFT JOIN UserRecharge r 
        ON l.uuid = r.uuid 
        AND r.charge_date <= l.log_date
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 5. 按分段统计
-------------------------------------------------------
DailyR_Tier AS (
    SELECT 
        log_date,
        uuid,
        CASE 
            WHEN historical_charge_jpy >= 3000000 THEN '300万以上'
            WHEN historical_charge_jpy >= 2000000 AND historical_charge_jpy < 3000000 THEN '200万~300万'
            WHEN historical_charge_jpy >= 1000000 AND historical_charge_jpy < 2000000 THEN '100万~200万'
            WHEN historical_charge_jpy >= 500000 AND historical_charge_jpy < 1000000 THEN '500000~999999'
            WHEN historical_charge_jpy >= 200000 AND historical_charge_jpy < 500000 THEN '200000~499999'
            WHEN historical_charge_jpy >= 50000 AND historical_charge_jpy < 200000 THEN '50000~199999'
            WHEN historical_charge_jpy >= 20000 AND historical_charge_jpy < 50000 THEN '20000~49999'
            WHEN historical_charge_jpy >= 5000 AND historical_charge_jpy < 20000 THEN '5000~19999'
            WHEN historical_charge_jpy >= 2000 AND historical_charge_jpy < 5000 THEN '2000~4999'
            WHEN historical_charge_jpy >= 1 AND historical_charge_jpy < 2000 THEN '1~1999'
            ELSE '0'
        END AS r_tier
    FROM DailyUserHistoricalCharge
)

-------------------------------------------------------
-- 6. 输出结果，按日期和分段汇聚
-------------------------------------------------------
SELECT 
    log_date AS "日期",
    COUNT(DISTINCT CASE WHEN r_tier = '300万以上' THEN uuid END) AS "300万以上",
    COUNT(DISTINCT CASE WHEN r_tier = '200万~300万' THEN uuid END) AS "200万~300万",
    COUNT(DISTINCT CASE WHEN r_tier = '100万~200万' THEN uuid END) AS "100万~200万",
    COUNT(DISTINCT CASE WHEN r_tier = '500000~999999' THEN uuid END) AS "500000~999999",
    COUNT(DISTINCT CASE WHEN r_tier = '200000~499999' THEN uuid END) AS "200000~499999",
    COUNT(DISTINCT CASE WHEN r_tier = '50000~199999' THEN uuid END) AS "50000~199999",
    COUNT(DISTINCT CASE WHEN r_tier = '20000~49999' THEN uuid END) AS "20000~49999",
    COUNT(DISTINCT CASE WHEN r_tier = '5000~19999' THEN uuid END) AS "5000~19999",
    COUNT(DISTINCT CASE WHEN r_tier = '2000~4999' THEN uuid END) AS "2000~4999",
    COUNT(DISTINCT CASE WHEN r_tier = '1~1999' THEN uuid END) AS "1~1999",
    COUNT(DISTINCT CASE WHEN r_tier = '0' THEN uuid END) AS "0",
    COUNT(DISTINCT uuid) AS "总登录人数"
FROM DailyR_Tier
GROUP BY 1
ORDER BY 1 DESC;
