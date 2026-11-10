/*
================================================================================
Game: Slam Dunk TC (灌篮TC)
Description: 2026年9月KPI完成情況查詢（每日收入 / 月度累積收入）
Environment: Trino
Table: ta.v_event_20
Url:https://ss-web.5xgames.com/#/tga/ide/20_4423?fromPanel=20_793
================================================================================
*/

WITH
-- 1. 9月KPI預估目標數據
KpiTarget AS (
    SELECT * FROM (
        VALUES
            (DATE '2026-09-01', 25229.0, 25229.0),
            (DATE '2026-09-02', 22714.0, 47942.0),
            (DATE '2026-09-03', 106150.0, 154092.0),
            (DATE '2026-09-04', 73794.0, 227886.0),
            (DATE '2026-09-05', 136448.0, 364334.0),
            (DATE '2026-09-06', 63270.0, 427604.0),
            (DATE '2026-09-07', 31935.0, 459539.0),
            (DATE '2026-09-08', 32859.0, 492398.0),
            (DATE '2026-09-09', 29136.0, 521534.0),
            (DATE '2026-09-10', 124392.0, 645926.0),
            (DATE '2026-09-11', 82224.0, 728150.0),
            (DATE '2026-09-12', 111727.0, 839877.0),
            (DATE '2026-09-13', 60446.0, 900323.0),
            (DATE '2026-09-14', 36516.0, 936838.0),
            (DATE '2026-09-15', 32766.0, 969604.0),
            (DATE '2026-09-16', 32223.0, 1001827.0),
            (DATE '2026-09-17', 91089.0, 1092916.0),
            (DATE '2026-09-18', 50145.0, 1143061.0),
            (DATE '2026-09-19', 30000.0, 1173061.0),
            (DATE '2026-09-20', 30000.0, 1203061.0),
            (DATE '2026-09-21', 30642.0, 1233703.0),
            (DATE '2026-09-22', 27248.0, 1260951.0),
            (DATE '2026-09-23', 26760.0, 1287711.0),
            (DATE '2026-09-24', 384000.0, 1671711.0),
            (DATE '2026-09-25', 121900.0, 1793611.0),
            (DATE '2026-09-26', 132000.0, 1925611.0),
            (DATE '2026-09-27', 66000.0, 1991611.0),
            (DATE '2026-09-28', 55000.0, 2046611.0),
            (DATE '2026-09-29', 43488.0, 2090099.0),
            (DATE '2026-09-30', 42644.0, 2132743.0)
    ) AS t(target_date, est_daily_sales, est_cum_sales)
),

-- 2. 黑名单/内部测试账号过滤
UserBlacklist AS (
    SELECT 
       DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_20
    WHERE cluster_name IN ('internal_users')
),

-- 3. 计算每日实际收入
ActualDailyMetrics AS (
    SELECT
        CAST(v."$part_date" AS DATE) AS "date",
        SUM(CASE 
            WHEN v."$part_event" = 'PURCHASE' 
             AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT' 
            THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange 
            ELSE 0.0 
        END) AS actual_daily_sales
    FROM ta.v_event_20 v
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    -- LEFT JOIN UserBlacklist s6 ON v."#account_id" = s6."#account_id"
    WHERE -- s6."#account_id" IS NULL AND 
          v."$part_date" >= '2026-09-01' AND v."$part_date" <= '2026-09-30'
      AND v."$part_event" IN ('PURCHASE')
    GROUP BY 1
)

-- 4. 最终汇总报表，包含每日和累计数据
SELECT 
    CAST(t.target_date AS VARCHAR) AS "日期",
    t.est_daily_sales AS "預估每日收入",
    t.est_cum_sales AS "預估月度累積Sales",
    COALESCE(a.actual_daily_sales, 0.0) AS "實際每日收入",
    SUM(COALESCE(a.actual_daily_sales, 0.0)) OVER (ORDER BY t.target_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "實際月度累積Sales"
FROM KpiTarget t
LEFT JOIN ActualDailyMetrics a ON t.target_date = a."date"
ORDER BY t.target_date;
