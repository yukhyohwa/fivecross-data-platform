WITH 
-- 1. 黑名单用户
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 2. 4月15日开始测试的新用户底层名单 (排除黑名单)
NewUsers AS (
    SELECT 
        t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND t1.tag_value >= '2026-04-15'
      AND ub.lcx_id IS NULL
    GROUP BY 1
),

-- 3. 计算用户累计充值总额 (用于划分档位，统计至4月23日)
UserCumulativeRevenue AS (
    SELECT 
        nu.lcx_id,
        COALESCE(SUM(CAST(v.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1)), 0) AS total_revenue_usd
    FROM NewUsers nu
    LEFT JOIN ta.v_event_16 v ON nu.lcx_id = v."#account_id" 
        AND v."$part_event" = 'PURCHASE' 
        AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
        AND v."$part_date" <= '2026-04-23'
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date 
        AND v.payload.cur = s5.currency
    GROUP BY 1
),

-- 4. 根据累计充值金额划分档位
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

-- 5. 特供刊物抽取统计 (4/15 12:00 - 4/23)
SpecialGachaPulls AS (
    SELECT
       COALESCE(sdkcommon.lcx_id, lcxsdkcommon.lcx_id)  AS lcx_id,
        SUM(v.count)    AS pull_count
    FROM ta.v_event_16 v
    WHERE v."$part_event" = 'active_gacha'
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
      -- 15日从12点开始统计，其余日期全天
      AND (
          (v."$part_date" = '2026-04-15' AND CAST(SUBSTRING(CAST(v."#event_time" AS VARCHAR), 12, 2) AS INTEGER) >= 12)
          OR (v."$part_date" > '2026-04-15')
      )
      AND CAST(v.gacha_id AS INTEGER) IN (2, 3)   -- 特供刊物
    GROUP BY 1
),

-- 6. 五个指定礼包的购买金额统计
GiftPackPurchases AS (
    SELECT 
        v."#account_id" AS lcx_id,
        v.payload.productid AS productid,
        SUM((CAST(v.payload.curamt AS DOUBLE) - COALESCE(fa.freeamount, 0)) / COALESCE(s3.exchange, 1)) AS revenue_usd
    FROM ta.v_event_16 v
    LEFT JOIN (
        SELECT lcxtransactionid, ABS(freeamount) AS freeamount
        FROM ta.v_event_16
        WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
          AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
    ) fa ON v.payload.purchaseid = fa.lcxtransactionid
    LEFT JOIN ta_dim.ta_exchange s3 ON v."$part_date" = s3.ex_date AND v.payload.cur = s3.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
      AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
      AND v.payload.productid IN (
          'com.dgames.g65002007.apple.CBT.nt670.gift5',
          'com.dgames.g65002007.apple.CBT.nt330.gift4',
          'com.dgames.g65002007.apple.CBT.nt290.gift13',
          'com.dgames.g65002007.apple.CBT.nt370.gift12',
          'com.dgames.g65002007.apple.CBT.nt370.gift19'
      )
    GROUP BY 1, 2
)

-- 7. 最终汇总输出
SELECT 
    ut.recharge_tier AS "付费档位",
    COUNT(DISTINCT ut.lcx_id) AS "总用户数",
    -- 特供刊物指标
    SUM(COALESCE(sg.pull_count, 0)) AS "特供刊物总抽取次数",
    ROUND(CAST(SUM(COALESCE(sg.pull_count, 0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT ut.lcx_id), 0), 2) AS "人均抽取次数",
    -- 指定礼包指标 (展开显示)
    s4."payload.productid@product_name" AS "礼包名称",
    ROUND(SUM(COALESCE(gp.revenue_usd, 0)), 2) AS "付费金额(USD)"
FROM UserTierAssignment ut
LEFT JOIN SpecialGachaPulls sg ON ut.lcx_id = sg.lcx_id
LEFT JOIN GiftPackPurchases gp ON ut.lcx_id = gp.lcx_id
LEFT JOIN ta_dim.dim_16_0_23989 s4 ON gp.productid = s4."payload.productid@product_id"
GROUP BY 1, 5
ORDER BY 1 ASC, 6 DESC;
