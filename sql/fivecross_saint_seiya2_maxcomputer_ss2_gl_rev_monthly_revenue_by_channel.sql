/*
================================================================================
Game: Saint Seiya Overseas (TC & SEA)
Region: Overseas (TC & SEA)
Description: Daily successful recharge orders and revenue summary for June 2025.
Environment: MaxCompute (ODPS)
Game IDs: '60000001' (TC/SEA), '23000113' (Overseas)
Table: dm_platform.daily_lcx_user_purchase (formerly suggested as daily_lcx_purchase)
================================================================================
*/

-- Configuration
--------------------------------------------------------------------------------
-- Section: Daily Summary (Daily Orders & Revenue)
--------------------------------------------------------------------------------
WITH transactions AS (
  SELECT 
    day,
    SUBSTR(CAST(day AS STRING), 1, 6) AS months,
    app_id,
    lcm_id,
    order_id,
    trade_no,
    price_show,
    unit_show,
    channel_type,
    store
  FROM 
    dm_platform.daily_lcx_user_purchase
  WHERE 
    day BETWEEN 20260201 AND 20260228
    AND app_id IN ('60000001', '23000113','65002004')
    AND price_show > 0 -- Only successful/paid orders
),
exchange_rates AS (
  -- Retrieve CNY exchange rates for conversion
  SELECT 
    SUBSTR(day_hour, 1, 6) AS months, 
    TOLOWER(trans_from) AS trans_from, 
    exchange_rate
  FROM (
    SELECT 
      day_hour, 
      TOLOWER(trans_from) AS trans_from, 
      exchange_rate,
      ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour DESC) AS rank
    FROM dm_platform.itunes_exchange_rate_fmp 
    WHERE trans_to = 'cny'
     AND day BETWEEN 20260201 AND 20260228
  ) tmp 
  WHERE rank = 1
)

SELECT 
  SUBSTR(CAST(day AS STRING), 1, 6) AS months,
  t.day,
  t.app_id,
  CASE 
    WHEN t.app_id = '60000001' THEN 'Saint Seiya (SEA)'
    WHEN t.app_id = '23000113' THEN 'Saint Seiya (TC)'
    WHEN t.app_id = '65002004' THEN 'New Three Kingdoms'
    ELSE 'Unknown'
  END AS app_name,
  t.lcm_id,
  t.order_id,
  t.trade_no,
  t.price_show,
  t.unit_show,
  ROUND(t.price_show * COALESCE(er.exchange_rate, 1), 2) AS price_rmb,
  t.channel_type,
  t.store
FROM 
  transactions t
LEFT JOIN 
  exchange_rates er ON t.months = er.months AND LOWER(t.unit_show) = er.trans_from
ORDER BY 
  t.day ASC, 
  t.app_id ASC;
