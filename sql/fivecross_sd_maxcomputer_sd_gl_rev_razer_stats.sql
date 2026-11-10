WITH country_list AS ( 
    SELECT 
        lcm_id, 
        MAX(country_name) AS country_name
    FROM 
        dm_platform.daily_lcx_user_info
    WHERE 
        day >= 20251001 -- Modified to match the transaction window
        AND app_id = 63002013
    GROUP BY 
        lcm_id
),
transactions AS (
    -- 筛选交易数据
    SELECT
        lcx_user_id,
        game_id,
        channel_type,
        paid_amount,
        currency_code,
        SUBSTR(CAST(day AS STRING), 1, 6) AS months -- Derive months from day
    FROM
      dm_platform.transaction_wallet
    WHERE
      day BETWEEN 20251001 AND 20251231
      AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE')
      AND channel_type IN ('razer')
      AND game_id IN ('63002013')
),
exchange_rates AS (
    -- 处理汇率
    SELECT
      substr(day_hour, 1, 6) AS months,
      trans_from,
      max(exchange_rate) AS exchange_rate
    FROM
      dm_platform.itunes_exchange_rate_fmp
    WHERE
      trans_to = 'cny'
      AND day >= 20251001
    GROUP BY
      substr(day_hour, 1, 6),
      trans_from
)

SELECT
  COALESCE(b.country_name, 'Unknown') AS country_name,
  a.months,
  ROUND(SUM(a.paid_amount * c.exchange_rate), 2) AS sales,
  COUNT(DISTINCT a.lcx_user_id) AS pay_users
FROM
  transactions a
  LEFT JOIN country_list b ON a.lcx_user_id = b.lcm_id
  LEFT JOIN exchange_rates c ON a.months = c.months AND upper(a.currency_code) = c.trans_from
GROUP BY
  b.country_name,
  a.months
ORDER BY 
  a.months DESC, 
  sales DESC;
