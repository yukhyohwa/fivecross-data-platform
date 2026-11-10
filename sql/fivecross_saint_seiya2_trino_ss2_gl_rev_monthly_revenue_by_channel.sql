/*
================================================================================
Game: Saint Seiya 2 / event_19 shared GL projects
Description: Purchase order details and CNY revenue by game and channel.
Environment: Trino
Table: ta.v_event_19
Date filter: ${PartDate:date1}
================================================================================
*/

WITH BaseEvents AS (
    SELECT
        v.*,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid') AS payload_productid
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1}
),

IdentifiedEvents AS (
    SELECT
        *,
        CASE
            WHEN
                   applicationid IN ('23000113','seiya30tw')
                OR productid IN ('23000113','seiya30tw')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('23000113')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('23000113')
                OR substring(affcode, -8) IN ('23000113')
                OR regexp_extract(payload_productid, 'g(\d+)', 1) IN ('23000113','seiya30tw')
            THEN 'Saint Seiya (TC)'
            WHEN
                   applicationid IN ('60000001')
                OR productid IN ('60000001')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('60000001')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('60000001')
                OR substring(affcode, -8) IN ('60000001')
                OR regexp_extract(payload_productid, 'g(\d+)', 1) IN ('60000001')
            THEN 'Saint Seiya (SEA)'
            WHEN
                   applicationid IN ('65002004')
                OR productid IN ('65002004')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002004')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('65002004')
                OR substring(affcode, -8) IN ('65002004')
                OR regexp_extract(payload_productid, 'g(\d+)', 1) IN ('65002004')
            THEN 'Three Kingdoms'
            WHEN
                   applicationid IN ('65002005')
                OR productid IN ('65002005')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002005')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('65002005')
                OR substring(affcode, -8) IN ('65002005')
                OR regexp_extract(payload_productid, 'g(\d+)', 1) IN ('65002005')
            THEN 'Captain Tsubasa'
            ELSE 'UNKNOWN'
        END AS game_name
    FROM BaseEvents
),

PurchaseTransactions AS (
    SELECT
        "$part_date" AS day,
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CASE game_name
            WHEN 'Saint Seiya (TC)' THEN '23000113'
            WHEN 'Saint Seiya (SEA)' THEN '60000001'
            WHEN 'Three Kingdoms' THEN '65002004'
            WHEN 'Captain Tsubasa' THEN '65002005'
            ELSE 'UNKNOWN'
        END AS app_id,
        game_name AS app_name,
        "#account_id" AS lcm_id,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.purchaseid') AS order_id,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.storeorderid') AS trade_no,
        TRY_CAST(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.curamt') AS DOUBLE) AS price_show,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.cur') AS unit_show,
        COALESCE(
            NULLIF(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.channeltype'), ''),
            NULLIF(CAST(channeltype AS VARCHAR), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.store'), ''),
            'UNKNOWN'
        ) AS channel_type,
        COALESCE(
            NULLIF(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.store'), ''),
            'UNKNOWN'
        ) AS store
    FROM IdentifiedEvents
    WHERE "$part_event" = 'PURCHASE'
      AND game_name <> 'UNKNOWN'
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND COALESCE(TRY_CAST(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.curamt') AS DOUBLE), 0) > 0
)

SELECT
    t.months,
    t.day,
    t.app_id,
    t.app_name,
    t.lcm_id,
    t.order_id,
    t.trade_no,
    t.price_show,
    t.unit_show,
    ROUND(t.price_show / COALESCE(ex.exchange, 1.0) * COALESCE(cny.exchange, 1.0), 2) AS price_rmb,
    t.channel_type,
    t.store
FROM PurchaseTransactions t
LEFT JOIN ta_dim.ta_exchange ex
    ON t.day = ex.ex_date
    AND UPPER(t.unit_show) = UPPER(ex.currency)
LEFT JOIN ta_dim.ta_exchange cny
    ON t.day = cny.ex_date
    AND cny.currency = 'CNY'
ORDER BY
    t.day ASC,
    t.app_id ASC,
    t.order_id ASC;
