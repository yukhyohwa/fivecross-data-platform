/*
================================================================================
Game: Saint Seiya 2 (SS2) - GL
Description: Internal Orders Reconcile Script.
             Extracts orders with free amount usage and sandbox receipts.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH IdentifiedEvents AS (
    SELECT 
        v.*,
        CASE 
            WHEN 
               applicationid IN ('23000113','seiya30tw') 
            OR productid IN ('23000113','seiya30tw') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('23000113')
            OR substring(affcode, -8) IN ('23000113') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('23000113','seiya30tw')
            THEN 'Saint Seiya (TC)' 
            WHEN 
               applicationid IN ('60000001') 
            OR productid IN ('60000001') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('60000001')
            OR substring(affcode, -8) IN ('60000001') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('60000001')
            THEN 'Saint Seiya (SEA)' 
            WHEN 
               applicationid IN ('65002004') 
            OR productid IN ('65002004') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002004')
            OR substring(affcode, -8) IN ('65002004') 
            OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('65002004')
            THEN 'Three Kingdoms' 
            WHEN 
               applicationid IN ('65002005') 
            OR productid IN ('65002005') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002005')
            OR substring(affcode, -8) IN ('65002005') 
            OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('65002005')
            THEN 'Captain Tsubasa' 
            ELSE 'UNKNOWN' 
        END AS game_name
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1}
),

TargetGameEvents AS (
    SELECT *
    FROM IdentifiedEvents
    WHERE game_name IN ('Saint Seiya (TC)','Saint Seiya (SEA)' )
),

PurchaseEvents AS (
    SELECT 
        "$part_date",
        "#account_id",
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid') AS product_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.curamt') AS DOUBLE) AS amt,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.cur') AS cur,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.storeorderid') AS store_order_id,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.purchaseid') AS purchase_id
    FROM TargetGameEvents
    WHERE "$part_event" = 'PURCHASE'
),

WalletSpend AS (
    SELECT 
        lcxtransactionid,
        ABS(freeamount) AS free_amount,
        ABS(paidamount) AS paid_amount
    FROM TargetGameEvents
    WHERE "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
      AND ABS(freeamount) > 0
),

PurchaseEventinSandBox AS (
    SELECT 
        "$part_date",
        "#account_id",
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid') AS product_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.curamt') AS DOUBLE) AS curamt,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.cur') AS cur,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.storeorderid') AS store_order_id,
        JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.purchaseid') AS purchase_id
    FROM TargetGameEvents
    WHERE "$part_event" = 'PURCHASE'
    AND JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.validationtype') = 'SANDBOX_RECEIPT'
)

-- 汇总扣除部分（福利币抵扣 + 沙盒订单）
SELECT purchase_id AS order_id, s2.free_amount
FROM PurchaseEvents s1
INNER JOIN WalletSpend s2 
    ON s1.purchase_id = s2.lcxtransactionid

UNION ALL

SELECT purchase_id AS order_id, curamt AS free_amount
FROM PurchaseEventinSandBox s1;
