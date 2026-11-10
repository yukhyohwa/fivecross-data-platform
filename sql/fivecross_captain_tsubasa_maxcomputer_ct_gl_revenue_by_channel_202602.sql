WITH transactions AS (
    -- 'wallet'
    SELECT
        'wallet' source,
        lcx_user_id,
        game_id,
        channel_type,
        CAST(paid_amount AS DOUBLE) paid_amount,
        currency_code,
        SUBSTR(CAST(day AS STRING), 1, 6) AS months -- Derive months from day
    FROM
      dm_platform.transaction_wallet
    WHERE
      day BETWEEN 20260201 AND 20260228
      AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE')
      AND game_id IN ('65002005')

   UNION ALL
   -- 'store'
    SELECT
        'store' source,
        lcm_id lcx_user_id,
        app_id game_id,
        store channel_type,
        CAST(price_show AS DOUBLE) paid_amount,
        unit_show currency_code,
        SUBSTR(CAST(day AS STRING), 1, 6) AS months
    FROM
        dm_platform.daily_lcx_user_purchase
    WHERE
        day BETWEEN 20260201 AND 20260228
        AND app_id = '65002005'
        AND channel_type <> 'LCX_WALLET'
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
      AND day >= 20260201
    GROUP BY
      substr(day_hour, 1, 6),
      trans_from
)

SELECT
  a.months,a.source,a.channel_type,
  ROUND(SUM(a.paid_amount * c.exchange_rate), 2) AS sales,
  COUNT(DISTINCT a.lcx_user_id) AS pay_users
FROM
  transactions a
  LEFT JOIN exchange_rates c ON a.months = c.months AND upper(a.currency_code) = c.trans_from
GROUP BY
  a.months,a.source,a.channel_type
ORDER BY
  a.months DESC,
  sales DESC;