/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 每日充值分类汇总统计 (包含主播收入、积分商城收入、游戏内充值及总收入)
Description : 按天汇总总充值金额 (USD)，并细分为以下几类：
              1. 主播收入 (Streamer Revenue)
              2. 积分商城收入 (Points Mall Revenue)
              3. 游戏内充值 (In-Game Top-up, 排除前两者后的剩余部分)
Environment : Trino (TA)
================================================================================
*/

-- ================================================================================
-- 【V2 版本】(推荐)：精确全链路关联 (基于 chargeReservationId 与 order_id 进行三方关联验证)
-- 关联链路：
-- 1. 主播购买: streamer_purchase(order_id) -> WALLET_DIRECT_CHARGE(chargeReservationId -> order_id) -> PURCHASE(purchaseid)
-- 2. 积分商城: WALLET_DIRECT_CHARGE(channeltype='Points Mall' -> order_id) -> PURCHASE(purchaseid)
-- ================================================================================

WITH PurchaseAll AS (
    -- 1. 基础数据：获取所有非沙盒的 PURCHASE 订单，并扣除免费额度后换算为 USD
    SELECT 
        p."$part_date" AS part_date,
        p.payload.purchaseid AS purchaseid,
        (CAST(p.payload.curamt AS DOUBLE) - COALESCE(free.freeamount, 0.0)) / COALESCE(exch.exchange, 1.0) AS usd_amt
    FROM ta.v_event_23 p
    LEFT JOIN (
        SELECT 
            lcxtransactionid, 
            ABS(freeamount) AS freeamount
        FROM ta.v_event_16
        WHERE ${PartDate:date1} 
          AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
    ) free ON p.payload.purchaseid = free.lcxtransactionid
    LEFT JOIN ta_dim.ta_exchange exch 
        ON p."$part_date" = exch.ex_date 
        AND p.payload.cur = exch.currency
    WHERE p.${PartDate:date1} 
      AND p."$part_event" = 'PURCHASE'
      AND COALESCE(p.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
),

StreamerPurchaseIds AS (
    -- 2. 提取出所有属于主播充值的 purchaseid
    SELECT DISTINCT
        p.payload.purchaseid AS purchaseid
    FROM ta.v_event_23 s
    INNER JOIN (
        SELECT 
            chargeReservationId,
            CASE 
                WHEN "$part_event" = 'WALLET_DIRECT_CHARGE_SPEND_TRANSACTION' THEN lcxtransactionid
                WHEN "$part_event" = 'WALLET_DIRECT_CHARGE_PURCHASE' THEN transactionid 
            END AS order_id
        FROM ta.v_event_23
        WHERE ${PartDate:date1} 
          AND "$part_event" IN ('WALLET_DIRECT_CHARGE_SPEND_TRANSACTION', 'WALLET_DIRECT_CHARGE_PURCHASE')
          AND CAST(paidamount AS DOUBLE) > 0
    ) w ON CAST(s.order_id AS VARCHAR) = CAST(w.chargeReservationId AS VARCHAR) -- streamer_purchase 的 order_id 关联到直充表的 chargeReservationId
    INNER JOIN ta.v_event_23 p
        ON CAST(w.order_id AS VARCHAR) = CAST(p.payload.purchaseid AS VARCHAR)
    WHERE s.${PartDate:date1} 
      AND s."$part_event" = 'streamer_purchase'
      AND p.${PartDate:date1} 
      AND p."$part_event" = 'PURCHASE'
      AND COALESCE(p.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
),

PointsMallPurchaseIds AS (
    -- 3. 提取出所有属于积分商城渠道的 purchaseid
    SELECT DISTINCT
        p.payload.purchaseid AS purchaseid
    FROM ta.v_event_23 w
    INNER JOIN ta.v_event_23 p
        ON CAST(CASE 
            WHEN w."$part_event" = 'WALLET_DIRECT_CHARGE_SPEND_TRANSACTION' THEN w.lcxtransactionid
            WHEN w."$part_event" = 'WALLET_DIRECT_CHARGE_PURCHASE' THEN w.transactionid 
        END AS VARCHAR) = CAST(p.payload.purchaseid AS VARCHAR)
    WHERE w.${PartDate:date1} 
      AND w."$part_event" IN ('WALLET_DIRECT_CHARGE_SPEND_TRANSACTION', 'WALLET_DIRECT_CHARGE_PURCHASE')
      AND w.channeltype = 'Points Mall'
      AND CAST(w.paidamount AS DOUBLE) > 0
      AND p.${PartDate:date1}
      AND p."$part_event" = 'PURCHASE'
      AND COALESCE(p.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
)

-- 4. 每日分类汇总收入 (USD)
SELECT 
    pa.part_date AS "日期",
    -- 1) 总计收入 (来自 PURCHASE)
    ROUND(SUM(pa.usd_amt), 2) AS "总收入 (USD)",
    
    -- 2) 主播分成通道的收入
    ROUND(SUM(CASE 
        WHEN sp.purchaseid IS NOT NULL THEN pa.usd_amt 
        ELSE 0.0 
    END), 2) AS "主播收入 (USD)",
    
    -- 3) 积分商城通道的收入 (加入 sp.purchaseid IS NULL 限制，确保在万一有数据交叉时依然互斥)
    ROUND(SUM(CASE 
        WHEN sp.purchaseid IS NULL AND pm.purchaseid IS NOT NULL THEN pa.usd_amt 
        ELSE 0.0 
    END), 2) AS "积分商城收入 (USD)",
    
    -- 4) 游戏内直充 (除去主播和积分商城之外的纯游戏内购收入)
    ROUND(SUM(CASE 
        WHEN sp.purchaseid IS NULL AND pm.purchaseid IS NULL THEN pa.usd_amt 
        ELSE 0.0 
    END), 2) AS "游戏内充值 (USD)"
FROM PurchaseAll pa
LEFT JOIN StreamerPurchaseIds sp ON pa.purchaseid = sp.purchaseid
LEFT JOIN PointsMallPurchaseIds pm ON pa.purchaseid = pm.purchaseid
GROUP BY 1
ORDER BY 1 DESC;




/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 【V1 版本】每日充值分类汇总 (总收入、积分商城、主播分润、游戏内充值金额与占比)
Description : 由于常规充值 (PURCHASE)、积分商城与主播分润之间无法通过 order_id 完美对齐，
              本脚本改用“日维度聚合”进行差值计算：
              - 总收入：来自 PURCHASE 事件（扣除免费代币，折算 USD）
              - 积分商城：来自 WALLET_DIRECT_CHARGE_SPEND_TRANSACTION / WALLET_DIRECT_CHARGE_PURCHASE 且 channeltype = 'Points Mall'
              - 主播分润：来自 streamer_purchase 事件
              - 游戏内充值 (差值计算) = 总收入 - 积分商城 - 主播分润
Environment : Trino (TA)
================================================================================
*/

WITH daily_total AS (
    -- 1. 每日充值总收入 (包含所有常规充值大池子，扣除免费代币后折算 USD)
    SELECT 
        s1.part_date,
        SUM((CAST(s1.amt AS DOUBLE) - COALESCE(s2.freeamount, 0.0)) / s3.exchange) AS total_usd
    FROM (
        SELECT 
            "$part_date" AS part_date,
            payload.curamt AS amt,
            payload.cur AS cur,
            payload.purchaseid AS purchaseid
        FROM ta.v_event_23
        WHERE ${PartDate:date1} 
          AND "$part_event" = 'PURCHASE'
          AND COALESCE(payload.validationtype, '') <> 'SANDBOX_RECEIPT'
    ) s1
    LEFT JOIN (
        SELECT 
            lcxtransactionid, 
            ABS(freeamount) AS freeamount
        FROM ta.v_event_16
        WHERE ${PartDate:date1} 
          AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
    ) s2 ON s1.purchaseid = s2.lcxtransactionid
    LEFT JOIN ta_dim.ta_exchange s3 
        ON s1.part_date = s3.ex_date 
        AND s1.cur = s3.currency
    GROUP BY 1
),

daily_points_mall AS (
    -- 2. 每日积分商城总充值 (折算 USD)
    SELECT 
        s1."$part_date" AS part_date,
        SUM(CAST(s1.paidamount AS DOUBLE) / COALESCE(s2.exchange, 1.0)) AS points_mall_usd
    FROM ta.v_event_23 s1
    LEFT JOIN ta_dim.ta_exchange s2 
        ON s1."$part_date" = s2.ex_date 
        AND s1.currencycode = s2.currency
    WHERE ${PartDate:date1} 
      AND s1."$part_event" IN ('WALLET_DIRECT_CHARGE_SPEND_TRANSACTION', 'WALLET_DIRECT_CHARGE_PURCHASE')
      AND s1.channeltype = 'Points Mall'
      AND CAST(s1.paidamount AS DOUBLE) > 0
    GROUP BY 1
),

daily_streamer AS (
    -- 3. 每日主播分润总充值 (折算 USD)
    SELECT 
        s1."$part_date" AS part_date,
        SUM(CAST(s1.original_amount AS DOUBLE) / s2.exchange) AS streamer_usd
    FROM ta.v_event_23 s1
    LEFT JOIN ta_dim.ta_exchange s2 
        ON s1."$part_date" = s2.ex_date 
        AND s1.currency_code = s2.currency
    WHERE ${PartDate:date1} 
      AND s1."$part_event" = 'streamer_purchase'
    GROUP BY 1
)

-- 4. 汇总与占比计算
SELECT 
    t.part_date AS "日期",
    ROUND(COALESCE(t.total_usd, 0.0), 2) AS "总收入 (USD)",
    
    ROUND(COALESCE(pm.points_mall_usd, 0.0), 2) AS "积分商城充值 (USD)",
    ROUND(COALESCE(pm.points_mall_usd, 0.0) * 100.0 / NULLIF(t.total_usd, 0.0), 2) AS "积分商城占比 (%)",
    
    ROUND(COALESCE(sp.streamer_usd, 0.0), 2) AS "主播分润充值 (USD)",
    ROUND(COALESCE(sp.streamer_usd, 0.0) * 100.0 / NULLIF(t.total_usd, 0.0), 2) AS "主播分润占比 (%)",
    
    -- 游戏内充值 = 总收入 - 积分商城充值 - 主播分润充值
    ROUND(COALESCE(t.total_usd, 0.0) - COALESCE(pm.points_mall_usd, 0.0) - COALESCE(sp.streamer_usd, 0.0), 2) AS "游戏内充值 (USD)",
    ROUND((COALESCE(t.total_usd, 0.0) - COALESCE(pm.points_mall_usd, 0.0) - COALESCE(sp.streamer_usd, 0.0)) * 100.0 / NULLIF(t.total_usd, 0.0), 2) AS "游戏内充值占比 (%)"
FROM daily_total t
LEFT JOIN daily_points_mall pm ON t.part_date = pm.part_date
LEFT JOIN daily_streamer sp ON t.part_date = sp.part_date
ORDER BY 1 DESC;
