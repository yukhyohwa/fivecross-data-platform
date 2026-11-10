/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : OBT 首周新用户首日付费档位与 ARPU/ARPPU 异常分析 (6.24 - 6.30 每日批次)
Description: 
    针对 6/30 新用户出现“ARPU 偏高、付费率偏低”的现象进行细化拆解，
    统计 6.24 ~ 6.30 每日新用户在注册首日 (Day 0) 的：
    - 新增人数、付费人数、付费率、首日 ARPU、首日 ARPPU。
    - 首日充值金额在各个档位 ((0,10]、(10,50]、(50,100]、(100,300]、(300,∞] USD) 的人数占比。
    从而验证是否由于高档位付费用户的比例提高拉高了整体 ARPU。
Environment: Trino (TA)
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 0. 黑名单 / 内部测试与注水账号过滤
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS account_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 1. 提取首周每日注册的新玩家 (Cohort 批次，基于 fixed_regdate 标签)
--------------------------------------------------------------------------------
CohortUsers AS (
    SELECT 
        u."#varchar_id" AS account_id,
        CAST(u.tag_value AS DATE) AS cohort_date
    FROM user_result_cluster_23 u
    LEFT JOIN UserBlacklist b ON u."#varchar_id" = b.account_id
    WHERE u.cluster_name = 'fixed_regdate'
      AND b.account_id IS NULL
      AND CAST(u.tag_value AS DATE) BETWEEN DATE '2026-06-24' AND DATE '2026-06-30'
),

--------------------------------------------------------------------------------
-- 2. 计算每个新玩家在注册首日 (Day 0) 的真实充值总额 (排除沙盒充值，统一折算为 USD)
--------------------------------------------------------------------------------
UserDay0Recharge AS (
    SELECT 
        v."#account_id" AS account_id,
        SUM(CAST(v.payload.curamt AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS revenue_usd
    FROM ta.v_event_23 v
    INNER JOIN CohortUsers cu 
        ON v."#account_id" = cu.account_id 
        AND CAST(v."$part_date" AS DATE) = cu.cohort_date -- 严格限定在首日
    LEFT JOIN ta_dim.ta_exchange ex 
        ON v."$part_date" = ex.ex_date 
        AND v.payload.cur = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 3. 划分新玩家的首日充值档位 (按累计 Day 0 充值折算金额)
--------------------------------------------------------------------------------
UserMetrics AS (
    SELECT 
        cu.account_id,
        cu.cohort_date,
        COALESCE(r.revenue_usd, 0.0) AS day0_revenue,
        CASE 
            WHEN COALESCE(r.revenue_usd, 0.0) = 0.0 THEN '0.免费'
            WHEN r.revenue_usd <= 10.0 THEN 'a.(0,10]'
            WHEN r.revenue_usd <= 50.0 THEN 'b.(10,50]'
            WHEN r.revenue_usd <= 100.0 THEN 'c.(50,100]'
            WHEN r.revenue_usd <= 300.0 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS tier
    FROM CohortUsers cu
    LEFT JOIN UserDay0Recharge r ON cu.account_id = r.account_id
)

--------------------------------------------------------------------------------
-- 4. 汇总输出各批次的首日付费率、ARPU/ARPPU 以及各档位人数占付费人数的比例
--------------------------------------------------------------------------------
SELECT
    CAST(cohort_date AS VARCHAR) AS "注册日期",
    COUNT(DISTINCT account_id) AS "新增人数",
    COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END) AS "首日付费人数",
    
    -- 付费率与 ARPU 表现
    ROUND(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END) * 100.0 / NULLIF(COUNT(DISTINCT account_id), 0), 2) AS "首日付费率 (%)",
    ROUND(SUM(day0_revenue) / NULLIF(COUNT(DISTINCT account_id), 0), 4) AS "首日ARPU (USD)",
    ROUND(SUM(day0_revenue) / NULLIF(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END), 0), 2) AS "首日ARPPU (USD)",
    
    -- 充值区间占比统计 (分母为首日付费人数)
    ROUND(COUNT(DISTINCT CASE WHEN tier = 'a.(0,10]' THEN account_id END) * 100.0 / NULLIF(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END), 0), 2) AS "0至10美金占比 (%)",
    ROUND(COUNT(DISTINCT CASE WHEN tier = 'b.(10,50]' THEN account_id END) * 100.0 / NULLIF(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END), 0), 2) AS "10至50美金占比 (%)",
    ROUND(COUNT(DISTINCT CASE WHEN tier = 'c.(50,100]' THEN account_id END) * 100.0 / NULLIF(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END), 0), 2) AS "50至100美金占比 (%)",
    ROUND(COUNT(DISTINCT CASE WHEN tier = 'd.(100,300]' THEN account_id END) * 100.0 / NULLIF(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END), 0), 2) AS "100至300美金占比 (%)",
    ROUND(COUNT(DISTINCT CASE WHEN tier = 'e.(300,∞]' THEN account_id END) * 100.0 / NULLIF(COUNT(DISTINCT CASE WHEN day0_revenue > 0 THEN account_id END), 0), 2) AS "300美金以上占比 (%)"
FROM UserMetrics
GROUP BY 1, cohort_date
ORDER BY 1 ASC;
