/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Analysis of products purchased (Charge/IAP & srcoin_buy) during a specific period.
Period: 2026-02-05 11:30 ~ 23:59
================================================================================
*/

WITH product_prices AS (
    -- Reference price dimension: mapping cfg_id to its real-world price/currency
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) as rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND ${PartDate:date1} 
)

SELECT
    ${Selector:timerange}  AS part_date,
    evt.cfg_id AS "商品ID",
    dim."cfg_id@name" AS "商品名称",
    COUNT(DISTINCT evt."#user_id") AS "付费人数",
    COUNT(*) AS "订单总数",
    SUM(
        CASE 
            WHEN evt.pay_currency IN ('kuroko_pay') THEN COALESCE(pp.pay_amount,0) / ex_pp.exchange
            ELSE evt.pay_amount / ex.exchange 
        END
    ) AS "总流水/USD",
    evt."$part_event"
FROM ta.v_event_10 AS evt
LEFT JOIN ta_dim.dim_10_0_12842 AS dim
    ON evt.cfg_id = dim."cfg_id@shop_item_id"
LEFT JOIN ta_dim.ta_exchange AS ex
    ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
-- Join with reference price for virtual currency valuation
LEFT JOIN product_prices pp 
    ON evt.cfg_id = pp.cfg_id AND pp.rnk = 1
LEFT JOIN ta_dim.ta_exchange AS ex_pp 
    ON pp.pay_currency = ex_pp.currency AND evt."$part_date" = ex_pp.ex_date
WHERE
    evt.${PartDate:date1} 
    -- AND evt."#event_time" BETWEEN TIMESTAMP '2026-02-05 11:30:00' AND TIMESTAMP '2026-02-05 23:59:59'
    AND evt."$part_event" = 'charge'
    AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
    AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
    AND evt.pay_currency <> 'COIN'
GROUP BY
    1, 
    2,
    3,
    7
ORDER BY
    "总流水/USD" DESC;
