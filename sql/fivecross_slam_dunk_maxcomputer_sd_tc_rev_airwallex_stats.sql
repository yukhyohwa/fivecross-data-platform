-- Calculate AirWallex recharge list with currency exchange and user info
-- Environment: MaxCompute (ODPS)
-- Filter: Game ID 23002013, AirWallex Channel

WITH transactions AS (
    -- Step 1: Filter and prepare raw transaction data
    SELECT 
        SUBSTR(day, 1, 6) AS months,
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
        day BETWEEN 20260101 AND 20260107 
        AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE') 
        AND game_id = '23002013' 
        AND channel_type = 'AirWallex' 
),

exchange_rates AS (
    -- Step 2: Get the maximum exchange rate per month/currency
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
),

user_profiles AS (
    -- Step 3: Get user level and zone from the latest snapshot
    SELECT 
        mbga_uid,
        user_id,
        zone,
        level
    FROM (
        SELECT 
            mbga_uid,
            user_id,
            zone,
            level,
            ROW_NUMBER() OVER (PARTITION BY mbga_uid ORDER BY level DESC) AS ranks
        FROM 
            g23002013.daily_user_snapshot 
        WHERE 
            day = 20260107
    ) ff 
    WHERE 
        ranks = 1
)

-- Final assembly: Join transactions with rates and user profiles
SELECT 
    t.months,
    t.day,
    t.channel_no,
    t.product_id,
    t.lcm_id,
    t.game_id,
    t.store,
    t.channel_type,
    t.paid_amount,
    t.currency_code,
    e.exchange_rate,
    t.transaction_type,
    u.user_id,
    u.zone,
    u.level
FROM 
    transactions t
LEFT JOIN 
    exchange_rates e ON t.months = e.months 
    AND UPPER(t.currency_code) = e.trans_from
LEFT JOIN 
    user_profiles u ON t.lcm_id = u.mbga_uid
ORDER BY 
    t.day DESC, 
    t.lcm_id;