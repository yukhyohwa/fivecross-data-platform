/*
================================================================================
Game: Saint Seiya GL (TC & SEA)
Description: Match 0-price orders (potential welfare coin payments) with 
             wallet consumption records to verify balance usage.
Environment: MaxCompute (ODPS)
Tables: 
  - dm_platform.daily_lcx_user_purchase (Order details)
  - dm_platform.transaction_wallet (Wallet/Balance consumption)
================================================================================
*/
SELECT
    p.day,
    p.app_id,
    p.lcm_id,
    p.order_id,
    p.price_show,
    p.unit_show,
    p.channel_type,
    p.store,
    w.paid_amount as wallet_paid,
    w.free_amount as wallet_free,
    w.currency_code as wallet_currency
FROM 
    dm_platform.daily_lcx_user_purchase p
LEFT JOIN 
    (SELECT * FROM dm_platform.transaction_wallet WHERE transaction_type = 'SPEND' AND day BETWEEN '20250701' AND '20250930') w 
ON 
    p.order_id = w.lcx_transaction_id
WHERE 
    p.app_id IN ('60000001', '23000113')
    AND p.day BETWEEN '20250701' AND '20250930'

UNION ALL

-- daily_lcx_user_purchase 不记录纯免费L币订单，这部分只能用transaction_wallet做补充
SELECT 
    day, 
    game_id AS app_id, 
    lcx_user_id AS lcm_id,
    lcx_transaction_id AS order_id, 
    0 AS price_show,
    '' AS unit_show,
    channel_type, 
    store,
    paid_amount AS wallet_paid, 
    free_amount AS wallet_free,
    currency_code AS wallet_currency
FROM 
    dm_platform.transaction_wallet 
WHERE 
    transaction_type = 'SPEND' 
    AND day BETWEEN '20250701' AND '20250930'
    AND game_id IN ('60000001', '23000113')
    AND (ABS(paid_amount) = 0 OR paid_amount IS NULL)
