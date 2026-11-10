/*
================================================================================
Game: Slam Dunk
Region: KR (Korea)
Description: 韩国订单明细流水 (Today's Order Details)
================================================================================
*/

WITH 
-- 1. 注册时间 (基于 user_snapshot 事件)
-- 注：在 TA 系统中，历史老用户的快照信息每日通过 user_snapshot 事件上报。
-- 可以通过 mbga_uid 对应 lcx_id (#account_id)，且由于单账号多角色，取 min(reg_date)
UserRegRaw AS (
    -- 1.1 历史老用户：从最近的快照中提取注册时间

    SELECT
        mbga_uid AS lcx_id,
        MIN(FROM_UNIXTIME(CAST(reg_date AS BIGINT))) AS reg_time
    FROM ta.v_event_22
    WHERE "$part_event" = 'user_snapshot'
      AND "$part_date" = CAST(CURRENT_DATE AS VARCHAR)
      AND mbga_uid IS NOT NULL
      AND mbga_uid <> ''
    GROUP BY 1

    UNION 

    -- 1.2 当天新注册用户：快照是凌晨生成的，还没包含今天新进的人，所以要把当天 NUU 补上
    SELECT
        CAST("#account_id" AS VARCHAR) AS lcx_id,
        MIN("#event_time") AS reg_time
    FROM ta.v_event_22
    WHERE "$part_event" = 'NUU'
      AND "$part_date" = CAST(CURRENT_DATE AS VARCHAR)
      AND "#account_id" IS NOT NULL
      AND "#account_id" <> ''
    GROUP BY 1
),

-- 1.3 去重并取每个账号的最小注册时间
UserRegDate AS (
    SELECT lcx_id, MIN(reg_time) AS reg_time
    FROM UserRegRaw
    GROUP BY 1
),


WalletSpend AS (
    -- 2. 提取代币/钱包消耗明细，用于计算净收入
    SELECT 
        lcxtransactionid,
        ABS(freeamount) AS free_amount,
        ABS(paidamount) AS paid_amount
    FROM ta.v_event_20
    WHERE ${PartDate:date1} 
      AND "$part_event" IN ('LCX_WALLET_SPEND_TRANSACTION')
)


SELECT
    "$part_date",
    evt."#account_id" AS "lcx_id", 
    u.reg_time AS "注册时间",
    evt."ostype" AS "os",
    evt."affcode" AS "affcode",
    UPPER(JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.cur')) AS "原货币",
    TRY_CAST(JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.curamt') AS DOUBLE) AS "原金额",
    -- SD 充值大多在 payload 里，结合 ta_exchange 换算为美元
    CAST(
        TRY_CAST(JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.curamt') AS DOUBLE) 
        / COALESCE(ex.exchange, 1.0)  * ex_cny.exchange
        AS DOUBLE
    ) AS "折算RMB金额",
    evt."#event_time" AS "订单时间",

    JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.productid') AS product_id,
    dp."payload.productid@product_name" AS product_name,
    
    JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.storeorderid') AS store_order_id,
    JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.purchaseid') AS purchase_id,
    evt."$part_event" AS "事件类型",
    CASE WHEN ws.lcxtransactionid IS NOT NULL THEN '福利币订单' END AS "订单类型"
FROM ta.v_event_22 AS evt

LEFT JOIN UserRegDate u
    ON CAST(evt."#account_id" AS VARCHAR) = u.lcx_id

LEFT JOIN ta_dim.ta_exchange ex
    ON evt."$part_date" = ex.ex_date 
    AND UPPER(JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.cur')) = ex.currency
    
LEFT JOIN ta_dim.ta_exchange ex_cny 
    ON evt."$part_date" = ex_cny.ex_date 
    AND ex_cny.currency = 'CNY'
    
LEFT JOIN ta_dim.dim_20_0_28490 dp 
    ON JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.productid') = dp."payload.productid@product_id"
    
LEFT JOIN WalletSpend ws 
    ON JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.purchaseid')  = ws.lcxtransactionid
    
WHERE
    evt.${PartDate:date1} 
    AND evt."$part_event" = 'PURCHASE'
    AND COALESCE(JSON_EXTRACT_SCALAR(CAST(evt.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
ORDER BY
    evt."#event_time" DESC;
