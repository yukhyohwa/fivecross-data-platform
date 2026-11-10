/*
================================================================================
Game    : Kuroko's Basketball (黑子的篮球)
Region  : TC (繁体大区, AppID=10, v_event_10)
Report  : 2026-08-08 当日付费较多的用户及其付费花费在哪里 (Top Paying Users & Product Breakdown)
================================================================================
*/
WITH product_prices AS (
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) AS rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND "$part_date" = '2026-08-08'
),
YesterdayUserPurchases AS (
    SELECT
        evt.uuid,
        CAST(CAST(TRY_CAST(evt.cfg_id AS DOUBLE) AS BIGINT) AS VARCHAR) AS clean_cfg_id,
        COALESCE(
            dim."cfg_id@name", 
            CAST(CAST(TRY_CAST(evt.cfg_id AS DOUBLE) AS BIGINT) AS VARCHAR)
        ) AS product_name,
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
    WHERE evt."$part_date" = '2026-08-08'
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt.uuid IS NOT NULL AND evt.uuid <> ''
    GROUP BY 
        evt.uuid, 
        CAST(CAST(TRY_CAST(evt.cfg_id AS DOUBLE) AS BIGINT) AS VARCHAR),
        COALESCE(dim."cfg_id@name", CAST(CAST(TRY_CAST(evt.cfg_id AS DOUBLE) AS BIGINT) AS VARCHAR))
),
UserDailyTotals AS (
    SELECT
        uuid,
        SUM(item_revenue_usd) AS total_user_revenue_usd,
        SUM(order_count) AS total_user_orders
    FROM YesterdayUserPurchases
    GROUP BY uuid
)
SELECT
    DENSE_RANK() OVER (ORDER BY t.total_user_revenue_usd DESC) AS "付费排名",
    p.uuid AS "用户UUID",
    ROUND(t.total_user_revenue_usd, 2) AS "当日个人总充值(USD)",
    t.total_user_orders AS "当日总订单数",
    p.clean_cfg_id AS "购买商品ID",
    p.product_name AS "商品名称",
    p.order_count AS "该商品购买笔数",
    ROUND(p.item_revenue_usd, 2) AS "该商品消费总额(USD)",
    CONCAT(CAST(ROUND(p.item_revenue_usd * 100.0 / NULLIF(t.total_user_revenue_usd, 0), 1) AS VARCHAR), '%') AS "占个人当日总消费比例"
FROM YesterdayUserPurchases p
INNER JOIN UserDailyTotals t ON p.uuid = t.uuid
ORDER BY t.total_user_revenue_usd DESC, p.item_revenue_usd DESC;
