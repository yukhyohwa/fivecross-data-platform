WITH transactions AS (
    SELECT
        SUBSTR(CAST(day AS STRING), 1, 6) AS months,
        day,
        channel_no,
        product_id,
        paid_amount,
        lcx_user_id AS lcm_id,
        game_id,
        store,
        channel_type,
        currency_code,
        transaction_type
    FROM
        dm_platform.transaction_wallet
    WHERE
        day BETWEEN 20260301 AND 20260331
        AND transaction_type IN ('SPEND')
        AND game_id IN ('63002013', '23002013', '33002013')
),
exchange_rates AS (
    -- 处理汇率
    SELECT
        SUBSTR(day_hour, 1, 6) AS months,
        trans_from,
        MAX(exchange_rate) AS exchange_rate
    FROM
        dm_platform.itunes_exchange_rate_fmp
    WHERE
        trans_to = 'cny'
        AND day = 20260301
    GROUP BY
        SUBSTR(day_hour, 1, 6),
        trans_from
)
SELECT
    CASE
        WHEN t.game_id = '23002013' THEN '灌篮繁体'
        WHEN t.game_id = '33002013' THEN '灌篮韩国'
        WHEN t.game_id = '63002013' THEN '灌篮全球'
    END AS region,
    t.channel_type,
    store,
    ROUND(SUM(t.paid_amount * er.exchange_rate), 2) AS sales--,
    -- t.day
FROM
    transactions AS t
    LEFT JOIN exchange_rates AS er 
        ON t.months = er.months 
        AND UPPER(t.currency_code) = er.trans_from
GROUP BY
    CASE
        WHEN t.game_id = '23002013' THEN '灌篮繁体'
        WHEN t.game_id = '33002013' THEN '灌篮韩国'
        WHEN t.game_id = '63002013' THEN '灌篮全球'
    END,
    t.channel_type,
    store--,
   -- t.day;