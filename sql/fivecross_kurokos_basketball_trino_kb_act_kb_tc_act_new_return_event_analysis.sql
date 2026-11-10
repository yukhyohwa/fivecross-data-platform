/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: 2026-07-01 ~ 2026-07-05 活動成效分析 (拉新/回歸/留存)
             Part 1: 3個指定活動的觸發人數
             Part 2: 活動期間的新增/回歸/持續活躍老用戶的登入與消費狀況
================================================================================
*/

WITH 
-------------------------------------------------------
-- 【黑名單】排除工作室/水軍
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 【Part 1】指定活動的觸發人數
-------------------------------------------------------
ActivityTriggers AS (
    SELECT 
        CAST(CAST("activity_id" AS BIGINT) AS VARCHAR) AS "類別_或_活動ID",
        '【2.活動觸發】' AS "指標分組",
        COUNT(DISTINCT "#user_id") AS "期間(7.1-7.5)活躍總人數",
        0 AS "至7月5日還活躍人數",
        0 AS "期間付費人數",
        0.0 AS "期間累計付費(USD)"
    FROM ta.v_event_10
    WHERE "$part_date" BETWEEN '2026-07-01' AND '2026-07-05'
      AND "activity_id" IN (70000023, 70000027, 70000028)
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
),

-------------------------------------------------------
-- 【Part 2】活動期間的新增/回歸/老用戶 登入與消費狀況
-------------------------------------------------------
-- 1. 獲取活動期間內所有有登入的活躍用戶，並標記他們在 7月5日 是否有登入
PeriodUsers AS (
    SELECT 
        "#user_id" AS user_id,
        MAX(CASE WHEN "$part_date" = '2026-07-05' THEN 1 ELSE 0 END) AS active_on_0705
    FROM ta.v_event_10
    WHERE "$part_event" = 'login'
      AND "$part_date" BETWEEN '2026-07-01' AND '2026-07-05'
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
),

-- 2. 追溯這些用戶在 2026-07-01 之前的歷史登入紀錄
UserHistory AS (
    SELECT 
        e."#user_id" AS user_id,
        MIN(e."$part_date") AS first_log_date,
        MAX(CASE WHEN e."$part_date" < '2026-07-01' THEN e."$part_date" END) AS max_log_before_0701
    FROM ta.v_event_10 e
    JOIN PeriodUsers p ON e."#user_id" = p.user_id
    WHERE e."$part_event" = 'login'
      AND e."$part_date" <= '2026-07-05'
    GROUP BY 1
),

-- 3. 用戶分類標籤
UserClassification AS (
    SELECT 
        p.user_id,
        p.active_on_0705,
        CASE 
            WHEN h.first_log_date >= '2026-07-01' THEN '1_新增用戶 (期間首次登入)'
            WHEN h.max_log_before_0701 <= '2026-06-15' THEN '2_回歸用戶 (07-01前≥15日未登入)'
            ELSE '3_持續活躍老用戶 (07-01前15日內有登入)'
        END AS user_type
    FROM PeriodUsers p
    JOIN UserHistory h ON p.user_id = h.user_id
),

-- 4. 計算活動期間的付費 (充值)
PeriodRevenue AS (
    SELECT 
        r."#user_id" AS user_id,
        SUM(r.pay_amount / COALESCE(ex.exchange, 1)) AS rev_usd
    FROM ta.v_event_10 r
    JOIN PeriodUsers p ON r."#user_id" = p.user_id
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
    WHERE r."$part_event" = 'charge'
      AND r."$part_date" BETWEEN '2026-07-01' AND '2026-07-05'
      AND (r.sandbox = false OR r.sandbox IS NULL)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
    GROUP BY 1
),

-- 5. 大盤數據聚合
UserGroupStats AS (
    SELECT 
        CAST(c.user_type AS VARCHAR) AS "類別_或_活動ID",
        '【1.大盤分析】' AS "指標分組",
        COUNT(DISTINCT c.user_id) AS "期間(7.1-7.5)活躍總人數",
        COUNT(DISTINCT CASE WHEN c.active_on_0705 = 1 THEN c.user_id END) AS "至7月5日還活躍人數",
        COUNT(DISTINCT CASE WHEN r.rev_usd > 0 THEN c.user_id END) AS "期間付費人數",
        COALESCE(SUM(r.rev_usd), 0.0) AS "期間累計付費(USD)"
    FROM UserClassification c
    LEFT JOIN PeriodRevenue r ON c.user_id = r.user_id
    GROUP BY 1
)

-------------------------------------------------------
-- 【Part 3】統一輸出 (避免多條 SQL 報錯)
-------------------------------------------------------
SELECT * FROM UserGroupStats
UNION ALL
SELECT * FROM ActivityTriggers
ORDER BY "指標分組", "類別_或_活動ID";
