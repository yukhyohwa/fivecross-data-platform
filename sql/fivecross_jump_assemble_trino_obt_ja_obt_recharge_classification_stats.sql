/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 充值分类汇总统计 (主播充值、积分商城、其他充值金额与占比)
Description : 将常规充值明细数据 (general_purchases, 即 PURCHASE 事件) 
              根据 order_id 划分为以下三类进行汇总，并计算金额和订单量占比：
              1. 主播充值 (能关联到 streamer_purchase 表的订单)
              2. 积分商城 (能关联到积分商城专属充值事件的订单)
              3. 其他充值 (其余常规充值订单)
Environment : Trino (TA)
================================================================================
*/

WITH streamer_purchases AS (
    -- 1. 获取主播充值的所有订单号
    SELECT DISTINCT order_id
    FROM ta.v_event_23
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'streamer_purchase'
),

points_mall_purchases AS (
    -- 2. 获取积分商城的所有订单号
    SELECT DISTINCT payload.storeorderid AS order_id
    FROM ta.v_event_23
    WHERE ${PartDate:date1} 
      AND "$part_event" IN ('DIRECT_CHARGE_PURCHASE_TRANSACTION','WALLET_DIRECT_CHARGE_PURCHASE_TRANSACTION')
      AND COALESCE(payload.validationtype, '') <> 'SANDBOX_RECEIPT'
      AND payload.channelType = 'Points Mall'
),

general_purchases AS (
    -- 3. 总充值明细池子 (包含所有常规充值，包括已包含在 PURCHASE 事件中的主播与积分商城订单)
    SELECT 
        s1."$part_date" AS part_date,
        s1."#account_id" AS account_id,
        s1.order_id,
        (CAST(s1.amt AS DOUBLE) - COALESCE(s2.freeamount, 0)) / COALESCE(s3.exchange, 1.0) AS revenue_usd
    FROM (
        SELECT 
            "$part_date",
            "#account_id",
            payload.curamt AS amt,
            payload.cur AS cur,
            payload.storeorderid AS order_id,
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
        ON s1."$part_date" = s3.ex_date 
        AND s1.cur = s3.currency
),

classified_purchases AS (
    -- 4. 关联后打标签分类
    SELECT 
        gp.part_date,
        gp.account_id,
        gp.order_id,
        gp.revenue_usd,
        CASE 
            WHEN sp.order_id IS NOT NULL THEN '主播充值'
            WHEN pm.order_id IS NOT NULL THEN '积分商城'
            ELSE '其他充值'
        END AS recharge_type
    FROM general_purchases gp
    LEFT JOIN streamer_purchases sp ON gp.order_id = sp.order_id
    LEFT JOIN points_mall_purchases pm ON gp.order_id = pm.order_id
),

aggregated_stats AS (
    -- 5. 按照充值类型汇总
    SELECT 
        recharge_type,
        SUM(revenue_usd) AS amount_usd,
        COUNT(DISTINCT order_id) AS order_num,
        COUNT(DISTINCT account_id) AS pu
    FROM classified_purchases
    GROUP BY recharge_type
)

-- 6. 输出结果，计算金额与订单量的占比及付费人数
SELECT 
    recharge_type AS "充值类型",
    ROUND(amount_usd, 2) AS "充值金额 (USD)",
    ROUND(amount_usd * 100.0 / SUM(amount_usd) OVER(), 2) AS "金额占比 (%)",
    order_num AS "订单量",
    ROUND(order_num * 100.0 / SUM(order_num) OVER(), 2) AS "订单量占比 (%)",
    pu AS "付费人数"
FROM aggregated_stats
ORDER BY amount_usd DESC;
