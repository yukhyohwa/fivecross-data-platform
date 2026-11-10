-- =================================================================================================================
-- Game: Kuroko's Basketball (黑子的篮球)
-- Region: TC / TW (繁体中文/台湾 10)
-- Description: 2025年7月1日~2026年4月30日 新注册用户 LTV (1, 3, 7, 14, 30, 60, 90, 180日) 看板
--              包含整体、Android、iOS，支持每日明细与阶段汇总，已对未成熟队列进行分母剔除
-- Engine: Trino
-- =================================================================================================================

WITH 
-------------------------------------------------------
-- 1. 黑名单过滤 (Blacklist)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 新注册用户确定 (首次登录时间作为注册日)
-------------------------------------------------------
UserRegister AS (
    SELECT 
        "#user_id" AS user_id,
        MIN("$part_date") AS reg_date,
        MIN(CASE 
            WHEN LOWER("#os") LIKE '%android%' THEN 'Android'
            WHEN LOWER("#os") LIKE '%ios%' THEN 'iOS'
            ELSE 'Other' 
        END) AS os_group
    FROM ta.v_event_10
    WHERE "$part_event" = 'login'
      AND "#user_id" IS NOT NULL
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
),

-------------------------------------------------------
-- 3. 充值与付费流水 (Revenue)
-------------------------------------------------------
UserRevenue AS (
    SELECT 
        r."#user_id" AS user_id,
        r."$part_date" AS pay_date,
        r.pay_amount / COALESCE(ex.exchange, 1) AS rev_usd
    FROM ta.v_event_10 r
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
    WHERE (
        (r."$part_event" = 'charge' AND r.pay_currency <> 'kuroko_pay' AND (r.sandbox = false OR r.sandbox IS NULL))
        OR (r."$part_event" IN ('scroin_buy', 'srcoin_buy'))
    )
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

-------------------------------------------------------
-- 4. 关联 Cohort 与付费，计算距注册日的天数
-------------------------------------------------------
CohortRevenue AS (
    SELECT
        c.user_id,
        c.reg_date,
        c.os_group,
        -- 计算距当前日期的成熟天数
        DATE_DIFF('day', CAST(c.reg_date AS DATE), CURRENT_DATE) AS mature_days,
        COALESCE(r.rev_usd, 0) AS rev_usd,
        DATE_DIFF('day', CAST(c.reg_date AS DATE), CAST(r.pay_date AS DATE)) AS ltv_day
    FROM UserRegister c
    LEFT JOIN UserRevenue r 
        ON c.user_id = r.user_id 
        AND r.pay_date >= c.reg_date
    WHERE c.reg_date BETWEEN '2025-07-01' AND '2026-04-30'
),

-------------------------------------------------------
-- 5. 汇总每个用户各 LTV 阶段的累计付费
-------------------------------------------------------
UserLtvAgg AS (
    SELECT
        user_id,
        reg_date,
        os_group,
        MAX(mature_days) AS mature_days,
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
-- 6. 每日及汇总的多维聚合 (GROUPING SETS)
-------------------------------------------------------
DailySummary AS (
    SELECT 
        reg_date,
        os_group,
        COUNT(DISTINCT user_id) AS new_users,
        
        -- 分母判断： mature_days >= X 的用户才计入分母以做无偏差统计
        SUM(CASE WHEN mature_days >= 0 THEN 1 ELSE 0 END) AS d1_den,
        SUM(CASE WHEN mature_days >= 0 THEN rev_1 ELSE 0 END) AS rev_1,
        
        SUM(CASE WHEN mature_days >= 2 THEN 1 ELSE 0 END) AS d3_den,
        SUM(CASE WHEN mature_days >= 2 THEN rev_3 ELSE 0 END) AS rev_3,
        
        SUM(CASE WHEN mature_days >= 6 THEN 1 ELSE 0 END) AS d7_den,
        SUM(CASE WHEN mature_days >= 6 THEN rev_7 ELSE 0 END) AS rev_7,
        
        SUM(CASE WHEN mature_days >= 13 THEN 1 ELSE 0 END) AS d14_den,
        SUM(CASE WHEN mature_days >= 13 THEN rev_14 ELSE 0 END) AS rev_14,
        
        SUM(CASE WHEN mature_days >= 29 THEN 1 ELSE 0 END) AS d30_den,
        SUM(CASE WHEN mature_days >= 29 THEN rev_30 ELSE 0 END) AS rev_30,
        
        SUM(CASE WHEN mature_days >= 59 THEN 1 ELSE 0 END) AS d60_den,
        SUM(CASE WHEN mature_days >= 59 THEN rev_60 ELSE 0 END) AS rev_60,
        
        SUM(CASE WHEN mature_days >= 89 THEN 1 ELSE 0 END) AS d90_den,
        SUM(CASE WHEN mature_days >= 89 THEN rev_90 ELSE 0 END) AS rev_90,
        
        SUM(CASE WHEN mature_days >= 179 THEN 1 ELSE 0 END) AS d180_den,
        SUM(CASE WHEN mature_days >= 179 THEN rev_180 ELSE 0 END) AS rev_180
    FROM UserLtvAgg
    GROUP BY 
        GROUPING SETS (
            (reg_date, os_group),
            (reg_date),
            (os_group),
            ()
        )
)

-------------------------------------------------------
-- 7. 格式化输出
-------------------------------------------------------
SELECT 
    COALESCE(reg_date, '【阶段汇总】') AS "日期",
    COALESCE(os_group, '整体') AS "OS",
    new_users AS "新增用户",
    ROUND(TRY(rev_1 / NULLIF(d1_den, 0)), 4) AS "LTV_1",
    ROUND(TRY(rev_3 / NULLIF(d3_den, 0)), 4) AS "LTV_3",
    ROUND(TRY(rev_7 / NULLIF(d7_den, 0)), 4) AS "LTV_7",
    ROUND(TRY(rev_14 / NULLIF(d14_den, 0)), 4) AS "LTV_14",
    ROUND(TRY(rev_30 / NULLIF(d30_den, 0)), 4) AS "LTV_30",
    ROUND(TRY(rev_60 / NULLIF(d60_den, 0)), 4) AS "LTV_60",
    ROUND(TRY(rev_90 / NULLIF(d90_den, 0)), 4) AS "LTV_90",
    ROUND(TRY(rev_180 / NULLIF(d180_den, 0)), 4) AS "LTV_180"
FROM DailySummary
ORDER BY 
    CASE WHEN reg_date IS NULL THEN 0 ELSE 1 END, 
    reg_date DESC,
    CASE WHEN os_group = '整体' THEN 0 
         WHEN os_group = 'Android' THEN 1 
         WHEN os_group = 'iOS' THEN 2 
         ELSE 3 END;
