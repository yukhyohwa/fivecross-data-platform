-- Calculate daily revenue by region and channel for SlamDunk (GL, KR, TC)
-- Converts foreign currencies to CNY using exchange rates.

WITH transaction_data AS (
    SELECT
        day,
        SUBSTR(day, 1, 6) AS month_str,
        game_id,
        channel_type,
        paid_amount,
        UPPER(currency_code) AS currency_code
    FROM dm_platform.transaction_wallet
    WHERE day BETWEEN 20241201 AND 20241231
      AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE')
      AND game_id IN ('63002013', '23002013', '33002013')
),

exchange_rates AS (
    SELECT
        SUBSTR(day_hour, 1, 6) AS month_str,
        trans_from,
        MAX(exchange_rate) AS exchange_rate
    FROM dm_platform.itunes_exchange_rate_fmp
    WHERE trans_to = 'cny'
      AND day = 20241201 -- Using exchange rate from the start of the month/period
    GROUP BY SUBSTR(day_hour, 1, 6), trans_from
),

enriched_data AS (
    SELECT
        t.day,
        CASE
            WHEN t.game_id = '23002013' THEN '繁体' -- TC (Traditional Chinese)
            WHEN t.game_id = '33002013' THEN '韩国' -- KR (Korea)
            WHEN t.game_id = '63002013' THEN '全球' -- GL
            ELSE 'Other'
        END AS region,
        t.channel_type,
        t.paid_amount,
        COALESCE(e.exchange_rate, 1) AS exchange_rate
    FROM transaction_data t
    LEFT JOIN exchange_rates e
        ON t.month_str = e.month_str
        AND t.currency_code = e.trans_from
)

SELECT
    region,
    channel_type,
    ROUND(SUM(paid_amount * exchange_rate), 2) AS sales,
    day
FROM enriched_data
GROUP BY region, channel_type, day
ORDER BY day, region;