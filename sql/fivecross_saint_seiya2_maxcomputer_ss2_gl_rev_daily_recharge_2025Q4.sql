/*
================================================================================
Game: Saint Seiya GL (TC & SEA) & New Three Kingdoms
Region: GL
Description: Daily successful recharge orders and revenue details for 2025 Q4 (Oct-Dec).
Environment: MaxCompute (ODPS)
Game IDs: '60000001' (SS SEA), '23000113' (SS TC), '65002004' (NTK)
Table: dm_platform.daily_lcx_user_purchase
================================================================================
*/

-- Configuration
--------------------------------------------------------------------------------
-- Section: Detailed Order List
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
        day BETWEEN 20251001 AND 20251231
        AND app_id IN ('60000001', '23000113', '65002004')
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
          AND day BETWEEN 20251001 AND 20251231
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
