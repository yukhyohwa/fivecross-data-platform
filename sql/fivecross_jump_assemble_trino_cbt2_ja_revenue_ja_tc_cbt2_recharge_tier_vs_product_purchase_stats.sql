WITH 
-- 1. 黑名单用户 (排除内部号与灌水号)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 2. 4月15日开始测试的新用户名单
NewUsers AS (
    SELECT 
        t1."#varchar_id" AS lcx_id,
        MAX(CASE WHEN t1.cluster_name = 'fixed_regdate' THEN t1.tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND ub.lcx_id IS NULL  -- 排除黑名单
    GROUP BY 1
    HAVING MAX(CASE WHEN t1.cluster_name = 'fixed_regdate' THEN t1.tag_value END) >= '2026-04-15'
),

-- 3. 计算用户累计充值总额 (用于划分档位)
UserCumulativeRevenue AS (
    SELECT 
        nu.lcx_id,
        COALESCE(SUM(CAST(v.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1)), 0) AS total_revenue_usd
    FROM NewUsers nu
    LEFT JOIN ta.v_event_16 v ON nu.lcx_id = v."#account_id" 
        AND v."$part_event" = 'PURCHASE' 
        AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date 
        AND v.payload.cur = s5.currency
    GROUP BY 1
),

-- 4. 划分充值档位
UserTierAssignment AS (
    SELECT 
        lcx_id,
        CASE 
            WHEN total_revenue_usd = 0 THEN '0.免费用户'
            WHEN total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM UserCumulativeRevenue
),

-- 5. 提取指定时间段 (4/15-4/22) 的购买明细
TargetPurchaseDetails AS (
    SELECT 
        s1."#account_id" AS lcx_id,
        s1.payload.productid AS productid,
        s1.payload.curamt AS amt,
        s1.payload.cur AS cur,
        s1.payload.purchaseid AS purchaseid,
        s1."$part_date" AS part_date
    FROM ta.v_event_16 s1
    WHERE s1."$part_date" BETWEEN '2026-04-15' AND '2026-04-22'
      AND s1."$part_event" = 'PURCHASE'
      AND s1.payload.validationtype <> 'SANDBOX_RECEIPT'
),

-- 6. 关联抵扣券/赠送金额
FreeAmountDetails AS (
    SELECT 
        lcxtransactionid, 
        ABS(freeamount) AS freeamount
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-22'
      AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
)

-- 7. 最终聚合统计
SELECT 
    ut.recharge_tier,
    tp.productid,
    s4."payload.productid@product_name" AS product_name,
    COUNT(DISTINCT tp.lcx_id) AS pu,
    COUNT(tp.purchaseid) AS purchase_count,
    SUM((CAST(tp.amt AS DOUBLE) - COALESCE(fa.freeamount, 0)) / COALESCE(s3.exchange, 1)) AS revenue_usd,
    '2026-04-15 - 2026-04-22' AS date_range
FROM TargetPurchaseDetails tp
JOIN UserTierAssignment ut ON tp.lcx_id = ut.lcx_id
LEFT JOIN FreeAmountDetails fa ON tp.purchaseid = fa.lcxtransactionid
LEFT JOIN ta_dim.ta_exchange s3 ON tp.part_date = s3.ex_date AND tp.cur = s3.currency
LEFT JOIN ta_dim.dim_16_0_23989 s4 ON tp.productid = s4."payload.productid@product_id"
GROUP BY 1, 2, 3
ORDER BY 1, 6 DESC;
