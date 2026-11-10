/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 用户充值档位分布报表 (基于当日净充值总额 USD)
             1. 档位划分：(0,1], (1,10], (10,50], (50,100], (100,500], (500,∞)
             2. 统计每日各档位的付费人数 (PU) 与总流水 (USD)。
             3. 排除内部测试账号。
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. 内部用户名单 (黑名单)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users')
),

-- 2. 提取充值原始事件 (排除内部号)
PurchaseEvents AS (
    SELECT 
        v."$part_date" AS log_date,
        v."#account_id" AS lcx_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) AS amt,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') AS cur
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'PURCHASE'
      AND ub."#account_id" IS NULL
      AND v.payload.validationtype <>'SANDBOX_RECEIPT'
),

-- 3. 计算每位用户每日的充值总额 (折合 USD)
DailyUserRevenue AS (
    SELECT 
        s1.log_date,
        s1.lcx_id,
        SUM(s1.amt / COALESCE(s3.exchange, 1)) AS daily_revenue_usd
    FROM PurchaseEvents s1
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1.log_date = s3.ex_date 
        AND s1.cur = s3.currency
    GROUP BY 1, 2
),

-- 4. 根据“当日充值总额 (USD)”进行档位划分
TierAssignment AS (
    SELECT 
        log_date,
        lcx_id,
        daily_revenue_usd,
        CASE 
            WHEN daily_revenue_usd <= 1 THEN 'a.(0,1]'
            WHEN daily_revenue_usd <= 10 THEN 'b.(1,10]'
            WHEN daily_revenue_usd <= 50 THEN 'c.(10,50]'
            WHEN daily_revenue_usd <= 100 THEN 'd.(50,100]'
            WHEN daily_revenue_usd <= 500 THEN 'e.(100,500]'
            ELSE 'f.(500,∞]'
        END AS recharge_tier
    FROM DailyUserRevenue
)

-- 5. 按时间维度和档位进行汇总
SELECT 
    log_date AS "日期",
    recharge_tier AS "充值档位",
    COUNT(DISTINCT lcx_id) AS "付费人数(PU)",
    ROUND(SUM(daily_revenue_usd), 2) AS "总流水(USD)"
FROM TierAssignment
GROUP BY 1, 2
ORDER BY 1 DESC, 2 ASC;
