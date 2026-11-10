/*
================================================================================
Game: Saint Seiya 2 / event_19 shared GL projects
Description: Monthly wallet purchase sales and paying users by game and channel.
Environment: MaxCompute (ODPS)
Table: dm_platform.transaction_wallet
Date filter: ${PartDate:date1}
================================================================================
*/

WITH transactions AS (
    SELECT
        SUBSTR(CAST(day AS STRING), 1, 6) AS months,
        lcx_user_id,
        game_id,
        CASE game_id
            WHEN '23000113' THEN 'Saint Seiya (TC)'
            WHEN '60000001' THEN 'Saint Seiya (SEA)'
            WHEN '65002004' THEN 'Three Kingdoms'
            WHEN '65002005' THEN 'Captain Tsubasa'
            ELSE 'UNKNOWN'
        END AS game_name,
        COALESCE(NULLIF(CAST(channel_type AS STRING), ''), 'UNKNOWN') AS channel_type,
        CAST(paid_amount AS DOUBLE) AS paid_amount,
        currency_code,
        day
    FROM
        dm_platform.transaction_wallet
    WHERE
        day >= CAST(REPLACE('${PartDate:date1}', '-', '') AS BIGINT)
        AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE')
        AND game_id IN ('23000113', '60000001', '65002004', '65002005')
),

exchange_rates AS (
    SELECT
        SUBSTR(day_hour, 1, 6) AS months,
        trans_from,
        MAX(exchange_rate) AS exchange_rate
    FROM
        dm_platform.itunes_exchange_rate_fmp
    WHERE
        trans_to = 'cny'
        AND day >= CAST(REPLACE('${PartDate:date1}', '-', '') AS BIGINT)
    GROUP BY
        SUBSTR(day_hour, 1, 6),
        trans_from
)

SELECT
    a.months,
    a.game_id,
    a.game_name,
    a.channel_type,
    ROUND(SUM(a.paid_amount * COALESCE(ex.exchange_rate, 1.0)), 2) AS sales_rmb,
    COUNT(DISTINCT a.lcx_user_id) AS pay_users
FROM
    transactions a
LEFT JOIN exchange_rates ex
    ON a.months = ex.months
    AND UPPER(a.currency_code) = UPPER(ex.trans_from)
GROUP BY
    a.months,
    a.game_id,
    a.game_name,
    a.channel_type
ORDER BY
    a.months DESC,
    a.game_id ASC,
    sales_rmb DESC;
