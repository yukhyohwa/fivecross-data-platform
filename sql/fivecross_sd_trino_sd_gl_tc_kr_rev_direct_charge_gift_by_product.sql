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
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(NULLIF(CAST(channeltype AS VARCHAR), ''), 'UNKNOWN') AS channel_type,
        store,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code
    FROM ta.v_event_20
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('LCX_WALLET_SPEND_TRANSACTION')
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) < 0

    UNION ALL

    SELECT
        'ta.v_event_21' AS event_table,
        '63002013' AS game_id,
        '灌篮全球' AS region,
        "$part_date" AS day,
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(NULLIF(CAST(channeltype AS VARCHAR), ''), 'UNKNOWN') AS channel_type,
        store,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code
    FROM ta.v_event_21
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('LCX_WALLET_SPEND_TRANSACTION')
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) < 0

    UNION ALL

    SELECT
        'ta.v_event_22' AS event_table,
        '33002013' AS game_id,
        '灌篮韩国' AS region,
        "$part_date" AS day,
        SUBSTR(REPLACE("$part_date", '-', ''), 1, 6) AS months,
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(NULLIF(CAST(channeltype AS VARCHAR), ''), 'UNKNOWN') AS channel_type,
        store,
        TRY_CAST(paidamount AS DOUBLE) AS paid_amount,
        currencycode AS currency_code
    FROM ta.v_event_22
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('LCX_WALLET_SPEND_TRANSACTION')
      AND COALESCE(TRY_CAST(paidamount AS DOUBLE), 0) < 0
)

SELECT
    t.months,
    t.event_table,
    t.game_id,
    t.region,
    COALESCE(t.channel_type, 'UNKNOWN') AS channel_type,
    COALESCE(t.store, 'UNKNOWN') AS store,
    ROUND(SUM(t.paid_amount / COALESCE(ex.exchange, 1.0) * COALESCE(cny.exchange, 1.0)), 2) AS sales_rmb,
    COUNT(DISTINCT t.account_id) AS pay_users
FROM WalletTransactions t
LEFT JOIN ta_dim.ta_exchange ex
    ON t.day = ex.ex_date
    AND UPPER(t.currency_code) = UPPER(ex.currency)
LEFT JOIN ta_dim.ta_exchange cny
    ON t.day = cny.ex_date
    AND cny.currency = 'CNY'
GROUP BY
    t.months,
    t.event_table,
    t.game_id,
    t.region,
    t.channel_type,
    t.store
ORDER BY
    t.months DESC,
    t.event_table ASC,
    sales_rmb DESC;
