/*
================================================================================
项目：蜡笔小新 - 首周注册用户分周SKU购买金额统计
描述：统计在查询周期首周（前7天）注册的用户，在各个商品 (SKU) 上：
     - 首周 (D0-D6)
     - 第二周 (D7-D13)
     - 第三周及以后 (D14+)
     购买的金额 (USD)。
================================================================================
*/

WITH ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_13
    WHERE ${PartDate:date1} AND "$part_event" IN ('new_role', 'login')
),

UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),

-- 1. 筛选在查询周期首周（前7天）注册的用户
FirstWeekCohort AS (
    SELECT
        v."#user_id",
        MIN(CAST(v."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_13 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" = 'new_role'
      AND ub."#user_id" IS NULL
    GROUP BY 1, sc.target_start_date
    HAVING MIN(CAST(v."$part_date" AS DATE)) BETWEEN sc.target_start_date AND DATE_ADD('day', 6, sc.target_start_date)
),

-- 2. 统计这些用户购买的所有充值流水
CohortPurchases AS (
    SELECT
        u."#user_id",
        u.reg_date,
        v.product_id,
        CAST(v."$part_date" AS DATE) AS charge_date,
        DATE_DIFF('day', u.reg_date, CAST(v."$part_date" AS DATE)) AS days_since_reg,
        v.pay_amount_usd
    FROM ta.v_event_13 v
    INNER JOIN FirstWeekCohort u ON v."#user_id" = u."#user_id"
    WHERE v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
)

-- 3. 按 SKU 维度和周区间进行金额汇总
SELECT 
    t.product_id AS "商品ID",
    dp."product_id@product_name_tc" AS "商品名称",
    dp."product_id@product_type" AS "商品类型",
    
    -- 首周 (D0 - D6)
    ROUND(SUM(CASE WHEN t.days_since_reg BETWEEN 0 AND 6 THEN t.pay_amount_usd ELSE 0.0 END), 2) AS "首周购买金额(USD)",
    COUNT(DISTINCT CASE WHEN t.days_since_reg BETWEEN 0 AND 6 THEN t."#user_id" END) AS "首周购买人数",
    
    -- 第二周 (D7 - D13)
    ROUND(SUM(CASE WHEN t.days_since_reg BETWEEN 7 AND 13 THEN t.pay_amount_usd ELSE 0.0 END), 2) AS "第二周购买金额(USD)",
    COUNT(DISTINCT CASE WHEN t.days_since_reg BETWEEN 7 AND 13 THEN t."#user_id" END) AS "第二周购买人数",
    
    -- 第三周及以后 (D14+)
    ROUND(SUM(CASE WHEN t.days_since_reg >= 14 THEN t.pay_amount_usd ELSE 0.0 END), 2) AS "第三周及以后购买金额(USD)",
    COUNT(DISTINCT CASE WHEN t.days_since_reg >= 14 THEN t."#user_id" END) AS "第三周及以后购买人数",
    
    -- 总计
    ROUND(SUM(t.pay_amount_usd), 2) AS "总购买金额(USD)",
    COUNT(DISTINCT t."#user_id") AS "付费人数"
FROM CohortPurchases t
LEFT JOIN ta_dim.dim_13_0_20639 dp 
    ON CAST(t.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER)
GROUP BY 1, 2, 3
ORDER BY "总购买金额(USD)" DESC;
