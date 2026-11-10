WITH transactions AS (
    SELECT
        lcm_id,
        dena_id,
        order_id,
        trade_no,
        SUBSTR(day, 1, 6) AS months,
        day,
        t_hour,
        t_minute,
        price_show,
        unit_show,
        GET_JSON_OBJECT(memo1, '$.zoneId') AS zoneid
    FROM
        dm_platform.daily_lcx_user_purchase
    WHERE
        day BETWEEN 20260114 AND 20260116
        AND app_id = '65002004'
        AND GET_JSON_OBJECT(memo1, '$.zoneId') = '11067'
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
        AND day >= 20260101
    GROUP BY
        SUBSTR(day_hour, 1, 6),
        trans_from
)
SELECT
    t.*,
    ROUND(t.price_show * COALESCE(er.exchange_rate, 1), 2) AS rmb
FROM
    transactions AS t
LEFT JOIN exchange_rates AS er
    ON t.months = er.months
    AND LOWER(t.unit_show) = LOWER(er.trans_from);
