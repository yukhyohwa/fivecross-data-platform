/*
================================================================================
Game: Slam Dunk GL (灌篮全球)
Description: 2026年9月KPI完成情况查询（每日收入 / 月度累计收入）
Environment: Trino
Table: ta.v_event_21
URL:https://ss-web.5xgames.com/#/tga/ide/21_4424?fromPanel=21_826
================================================================================
*/

WITH
-- 1. 9月KPI预估目标数据（灌篮GL / WW）
KpiTarget AS (
    SELECT * FROM (
        VALUES
            (DATE '2026-09-01', 3604.0, 3604.0),
            (DATE '2026-09-02', 3129.0, 6733.0),
            (DATE '2026-09-03', 15201.0, 21934.0),
            (DATE '2026-09-04', 10888.0, 32822.0),
            (DATE '2026-09-05', 19801.0, 52623.0),
            (DATE '2026-09-06', 9023.0, 61646.0),
            (DATE '2026-09-07', 4593.0, 66239.0),
            (DATE '2026-09-08', 4517.0, 70756.0),
            (DATE '2026-09-09', 4068.0, 74825.0),
            (DATE '2026-09-10', 17294.0, 92119.0),
            (DATE '2026-09-11', 11707.0, 103825.0),
            (DATE '2026-09-12', 15785.0, 119611.0),
            (DATE '2026-09-13', 8139.0, 127750.0),
            (DATE '2026-09-14', 4834.0, 132584.0),
            (DATE '2026-09-15', 4045.0, 136628.0),
            (DATE '2026-09-16', 3989.0, 140617.0),
            (DATE '2026-09-17', 11682.0, 152299.0),
            (DATE '2026-09-18', 6505.0, 158804.0),
            (DATE '2026-09-19', 3810.0, 162614.0),
            (DATE '2026-09-20', 3776.0, 166390.0),
            (DATE '2026-09-21', 3905.0, 170295.0),
            (DATE '2026-09-22', 3171.0, 173466.0),
            (DATE '2026-09-23', 3319.0, 176785.0),
            (DATE '2026-09-24', 42694.0, 219479.0),
            (DATE '2026-09-25', 14261.0, 233740.0),
            (DATE '2026-09-26', 16089.0, 249829.0),
            (DATE '2026-09-27', 8057.0, 257886.0),
            (DATE '2026-09-28', 6623.0, 264509.0),
            (DATE '2026-09-29', 5329.0, 269837.0),
            (DATE '2026-09-30', 5357.0, 275194.0)
    ) AS t(target_date, est_daily_sales, est_cum_sales)
),

-- 2. 黑名单/内部测试账号过滤 (使用 GL 对应的分群表)
UserBlacklist AS (
    SELECT 
       DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_21
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
    FROM ta.v_event_21 v
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
    t.est_daily_sales AS "预估每日收入",
    t.est_cum_sales AS "预估月度累计Sales",
    COALESCE(a.actual_daily_sales, 0.0) AS "实际每日收入",
    SUM(COALESCE(a.actual_daily_sales, 0.0)) OVER (ORDER BY t.target_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "实际月度累计Sales"
FROM KpiTarget t
LEFT JOIN ActualDailyMetrics a ON t.target_date = a."date"
ORDER BY t.target_date;
