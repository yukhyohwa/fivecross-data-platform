/*
================================================================================
Game: Captain Tsubasa (足球小将) - GL
Description: Monthly Revenue and Paying Users by Channel (Feb 2026)
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH transactions AS (
    -- 'wallet'
    SELECT
        'wallet' AS source,
        "#account_id" AS lcx_user_id,
        regexp_extract(productid, 'g(\d+)', 1) AS game_id,
        "channeltype" AS channel_type,
        CAST(paidamount AS DOUBLE) AS paid_amount,
        "currencycode" AS currency_code,
        "$part_date",
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months
    FROM
        ta.v_event_19
    WHERE
        "$part_date" BETWEEN '2026-02-01' AND '2026-02-28'
        AND "$part_event" = 'WALLET_DIRECT_CHARGE_PURCHASE'
        AND regexp_extract(productid, 'g(\d+)', 1) = '65002005'

    UNION ALL

    -- 'store'
    SELECT
        'store' AS source,
        "#account_id" AS lcx_user_id,
        '65002005' AS game_id,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.store') AS channel_type,
        CAST(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.curamt') AS DOUBLE) AS paid_amount,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.cur') AS currency_code,
        "$part_date",
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months
    FROM
        ta.v_event_19
    WHERE
        "$part_date" BETWEEN '2026-02-01' AND '2026-02-28'
        AND "$part_event" = 'PURCHASE'
        AND JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
        AND (
            applicationid IN ('65002005') 
            OR productid IN ('65002005') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002005')
            OR substring(affcode, -8) IN ('65002005') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002005')
        )
        AND payload.channeltype <> 'LCX_WALLET'
) 

SELECT
    a.months,
    a.source,
    a.channel_type,
    ROUND(SUM(a.paid_amount / COALESCE(s5.exchange, 1.0) * COALESCE(s_cny.exchange, 1.0)), 2) AS sales,
    COUNT(DISTINCT a.lcx_user_id) AS pay_users
FROM
    transactions a
    LEFT JOIN ta_dim.ta_exchange s5 
        ON a."$part_date" = s5.ex_date 
        AND UPPER(a.currency_code) = UPPER(s5.currency)
    LEFT JOIN ta_dim.ta_exchange s_cny 
        ON a."$part_date" = s_cny.ex_date 
        AND s_cny.currency = 'CNY'
GROUP BY
    a.months,
    a.source,
    a.channel_type
ORDER BY
    a.months DESC,
    sales DESC;
