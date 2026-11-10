/*
================================================================================
Game: Saint Seiya 2 / event_19 shared GL projects
Description: Monthly wallet purchase sales and paying users by game and channel.
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

WalletTransactions AS (
    SELECT
        "#account_id" AS lcx_user_id,
        CASE game_name
            WHEN 'Saint Seiya (TC)' THEN '23000113'
            WHEN 'Saint Seiya (SEA)' THEN '60000001'
            WHEN 'Three Kingdoms' THEN '65002004'
            WHEN 'Captain Tsubasa' THEN '65002005'
            ELSE 'UNKNOWN'
        END AS game_id,
        game_name,
        COALESCE(
            NULLIF(CAST(channelno AS VARCHAR), ''),
            NULLIF(CAST(channeltype AS VARCHAR), ''),
            'UNKNOWN'
        ) AS channel_type,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code,
        "$part_date",
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months
    FROM IdentifiedEvents
    WHERE game_name <> 'UNKNOWN'
      AND (
            ("$part_event" = 'LCX_WALLET_PURCHASE_TRANSACTION' AND game_name <> 'Captain Tsubasa')
         OR ("$part_event" = 'WALLET_DIRECT_CHARGE_PURCHASE' AND game_name = 'Captain Tsubasa')
      )
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) > 0
)

SELECT
    a.months,
    a.game_id,
    a.game_name,
    COALESCE(a.channel_type, 'UNKNOWN') AS channel_type,
    ROUND(SUM(a.paid_amount / COALESCE(ex.exchange, 1.0) * COALESCE(cny.exchange, 1.0)), 2) AS sales_rmb,
    COUNT(DISTINCT a.lcx_user_id) AS pay_users
FROM WalletTransactions a
LEFT JOIN ta_dim.ta_exchange ex
    ON a."$part_date" = ex.ex_date
    AND UPPER(a.currency_code) = UPPER(ex.currency)
LEFT JOIN ta_dim.ta_exchange cny
    ON a."$part_date" = cny.ex_date
    AND cny.currency = 'CNY'
GROUP BY
    a.months,
    a.game_id,
    a.game_name,
    a.channel_type
ORDER BY
    a.months DESC,
    a.game_id ASC,
    sales_rmb DESC;
