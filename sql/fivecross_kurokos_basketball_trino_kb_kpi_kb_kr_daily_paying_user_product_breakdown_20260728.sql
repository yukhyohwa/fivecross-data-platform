/*
================================================================================
Game    : Kuroko's Basketball (黑子的篮球)
Region  : TC (繁体大区, AppID=10, v_event_10)
Report  : 2026-07-28 昨日大额付费用户明细与购买商品花费分布 (Top Paying Users & Item Spend Breakdown)
Date    : 2026-07-28 (支持数数后台时间筛选宏 ${PartDate:date1})
User ID : uuid (以 uuid 作为主要玩家标识)
Reg Date: 提取该 uuid 在 ta.v_event_10 中的最早日志日期作为注册时间 reg_date
================================================================================
*/

WITH product_prices AS (
    -- 1. 映射虚拟货币商品 (kuroko_pay) 到法币真实标价
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) AS rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND ${PartDate:date1}
),

-- 2. 提取用户 (uuid) 在全表的最早出现日期作为注册时间 (reg_date)
UserRegDate AS (
    SELECT
        uuid,
        MIN("$part_date") AS reg_date
    FROM ta.v_event_10
    WHERE uuid IS NOT NULL AND uuid <> ''
    GROUP BY 1
),

-- 3. 提取昨日 (2026-07-28) 用户的具体商品购买明细
YesterdayUserPurchases AS (
    SELECT
        evt.uuid,
        evt.cfg_id,
        COALESCE(dim."cfg_id@name", CAST(evt.cfg_id AS VARCHAR)) AS product_name,
        COUNT(*) AS order_count,
        SUM(
            CASE 
                WHEN evt.pay_currency IN ('kuroko_pay') THEN COALESCE(pp.pay_amount, 0.0) / COALESCE(ex_pp.exchange, 1.0)
                ELSE evt.pay_amount / COALESCE(ex.exchange, 1.0)
            END
        ) AS item_revenue_usd
    FROM ta.v_event_10 evt
    LEFT JOIN ta_dim.dim_10_0_12842 dim
        ON evt.cfg_id = dim."cfg_id@shop_item_id"
    LEFT JOIN ta_dim.ta_exchange ex
        ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
    LEFT JOIN product_prices pp 
        ON evt.cfg_id = pp.cfg_id AND pp.rnk = 1
    LEFT JOIN ta_dim.ta_exchange ex_pp 
        ON pp.pay_currency = ex_pp.currency AND evt."$part_date" = ex_pp.ex_date
    WHERE evt.${PartDate:date1}   -- 默认筛选 2026-07-28
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt.uuid IS NOT NULL AND evt.uuid <> ''
    GROUP BY evt.uuid, evt.cfg_id, COALESCE(dim."cfg_id@name", CAST(evt.cfg_id AS VARCHAR))
),

-- 4. 汇总每个用户在昨日的总充值流水 (USD)
UserDailyTotals AS (
    SELECT
        uuid,
        SUM(item_revenue_usd) AS total_user_revenue_usd,
        SUM(order_count) AS total_user_orders
    FROM YesterdayUserPurchases
    GROUP BY uuid
)

-- 5. 最终报表：按用户充值金额降序排列，展开显示各个大额付费玩家的注册时间及购买商品花费明细
SELECT
    DENSE_RANK() OVER (ORDER BY t.total_user_revenue_usd DESC)                            AS "昨日付费排名",
    p.uuid                                                                                AS "用户UUID",
    COALESCE(r.reg_date, '未知')                                                           AS "注册日期",
    ROUND(t.total_user_revenue_usd, 2)                                                    AS "昨日个人总充值(USD)",
    t.total_user_orders                                                                   AS "昨日总订单数",
    p.cfg_id                                                                              AS "商品ID",
    p.product_name                                                                        AS "商品名称",
    p.order_count                                                                         AS "该商品购买笔数",
    ROUND(p.item_revenue_usd, 2)                                                          AS "该商品消费总额(USD)",
    CONCAT(CAST(ROUND(p.item_revenue_usd * 100.0 / NULLIF(t.total_user_revenue_usd, 0), 1) AS VARCHAR), '%') AS "占个人昨日总消费比例"
FROM YesterdayUserPurchases p
INNER JOIN UserDailyTotals t ON p.uuid = t.uuid
LEFT JOIN UserRegDate r ON p.uuid = r.uuid
ORDER BY t.total_user_revenue_usd DESC, p.item_revenue_usd DESC;
