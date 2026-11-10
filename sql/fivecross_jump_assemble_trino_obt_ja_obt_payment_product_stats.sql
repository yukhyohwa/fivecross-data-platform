/*
================================================================================
Game    : Jump Assemble - OBT
Report  : 付费商品流水及用户统计 (Product Revenue & Purchase Stats)
Description: 统计各商品分类、商品 ID 及商品名称的付费人数 (PU) 与 USD 净流水 (扣除免费币 / 代币卡)
================================================================================
*/

SELECT 
    ${Selector:timetype} AS time_dimension,
    s4."payload.productid@product_category" AS product_category,
    regexp_replace(element_at(split(s1.productid, '.'), -1), 'KOL$', '') AS productid,
    s4."payload.productid@product_name" AS product_name,
    COUNT(DISTINCT s1."#account_id") AS pu,
    SUM((CAST(s1.amt AS DOUBLE) - COALESCE(s2.freeamount, 0)) / s3.exchange) AS revenue_usd
FROM (
    SELECT 
        "$part_date",
        "#account_id",
        payload.productid AS productid,
        payload.curamt AS amt,
        payload.cur AS cur,
        payload.storeorderid AS storeorderid,
        payload.purchaseid AS purchaseid
    FROM ta.v_event_23
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'PURCHASE'
      AND payload.validationtype <> 'SANDBOX_RECEIPT'
) s1

LEFT JOIN (
    SELECT 
        lcxtransactionid,
        ABS(freeamount) AS freeamount,
        ABS(paidamount) AS paidamount
    FROM ta.v_event_16
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
) s2
ON s1.purchaseid = s2.lcxtransactionid

LEFT JOIN ta_dim.ta_exchange s3 
ON s1."$part_date" = s3.ex_date 
AND s1.cur = s3.currency

LEFT JOIN ta_dim.dim_23_0_51243 s4 
ON (
    s1.productid NOT LIKE 'dirc.%'
    AND s1.productid = s4."payload.productid@product_id"
)
OR (
    s1.productid LIKE 'dirc.%'
    AND regexp_replace(element_at(split(s1.productid, '.'), -1), 'KOL$', '') = element_at(
        split(element_at(split(s4."payload.productid@product_id", '.'), -1), '_'),
        1
    )
    AND lower(s4."payload.productid@product_id") LIKE '%google.open%'
)

GROUP BY 1, 2, 3, 4;
