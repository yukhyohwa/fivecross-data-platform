

/*
================================================================================
Game: Slam Dunk (event_20 / event_21 / event_22)
Description: Monthly wallet purchase revenue by project and channel.
Environment: Trino
Tables:
  - ta.v_event_20: 灌篮台湾
  - ta.v_event_21: 灌篮全球
  - ta.v_event_22: 灌篮韩国
Date filter: ${PartDate:date1}
================================================================================
*/

WITH WalletTransactions AS (
    SELECT
        'ta.v_event_20' AS event_table,
        '23002013' AS game_id,
        '灌篮台湾' AS region,
        "$part_date" AS day,
        channelno,
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(NULLIF(CAST(channeltype AS VARCHAR), ''), 'UNKNOWN') AS channel_type,
        'LCX_WALLET' AS store,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code,
        productid AS raw_productid,
        "$part_event"
    FROM ta.v_event_20
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('LCX_WALLET_PURCHASE_TRANSACTION','WALLET_DIRECT_CHARGE_PURCHASE')
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) > 0

    UNION ALL

    SELECT
        'ta.v_event_21' AS event_table,
        '63002013' AS game_id,
        '灌篮全球' AS region,
        "$part_date" AS day,
        channelno,
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(NULLIF(CAST(channeltype AS VARCHAR), ''), 'UNKNOWN') AS channel_type,
        'LCX_WALLET' AS store,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code,
        productid AS raw_productid,
        "$part_event"
    FROM ta.v_event_21
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('LCX_WALLET_PURCHASE_TRANSACTION','WALLET_DIRECT_CHARGE_PURCHASE')
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) > 0

    UNION ALL

    SELECT
        'ta.v_event_22' AS event_table,
        '33002013' AS game_id,
        '灌篮韩国' AS region,
        "$part_date" AS day,
        channelno,
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(NULLIF(CAST(channeltype AS VARCHAR), ''), 'UNKNOWN') AS channel_type,
        'LCX_WALLET' AS store,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code,
        productid AS raw_productid,
        "$part_event"
    FROM ta.v_event_22
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('LCX_WALLET_PURCHASE_TRANSACTION','WALLET_DIRECT_CHARGE_PURCHASE')
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) > 0
)

SELECT
    t.months,
    day,
    channelno channel_no,
    raw_productid productid,
    account_id lcm_id,
    t.game_id,
    COALESCE(t.store, 'UNKNOWN') AS store,
    COALESCE(t.channel_type, 'UNKNOWN') AS channel_type,
    paid_amount,
    currency_code,
    ex.exchange exchange_rate_usd,
    hkd.exchange exchange_rate_hkd,
    t.paid_amount / COALESCE(ex.exchange, 1.0) * COALESCE(hkd.exchange, 1.0) AS sales_hkd,
    "$part_event" transaction_type
FROM WalletTransactions t
LEFT JOIN ta_dim.ta_exchange ex
    ON t.day = ex.ex_date
    AND UPPER(t.currency_code) = UPPER(ex.currency)
LEFT JOIN ta_dim.ta_exchange hkd
    ON t.day = hkd.ex_date
    AND hkd.currency = 'HKD'
