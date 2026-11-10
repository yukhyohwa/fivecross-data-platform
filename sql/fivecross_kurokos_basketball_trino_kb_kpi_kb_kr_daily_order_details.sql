/*
================================================================================
Game: Kuroko's Basketball
Region: KR (Korea)
Description: 韩国订单明细流水 (Today's Order Details)
================================================================================
*/

WITH 
-- 1. 黑名单逻辑 (基于 #user_id)
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-- 2. uuid 注册时间 (最早login时间)
UuidBase AS (
    SELECT 
        uuid, 
        reg_time
    FROM (
        SELECT 
            s1.uuid, 
            s1."#event_time" AS reg_time,
            ROW_NUMBER() OVER (PARTITION BY s1.uuid ORDER BY s1."$part_date" ASC, s1."#event_time" ASC) as rn
        FROM ta.v_event_12 s1
        LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
        WHERE s1."$part_event" = 'login'
          AND s1."$part_date" >= '2024-01-24'
          -- AND b."#user_id" IS NULL
          AND s1.uuid IS NOT NULL AND s1.uuid <> ''
    ) WHERE rn = 1
)

SELECT
    "$part_date",
    evt.uuid AS "uuid",
    evt."#account_id" AS "gid", 
    u.reg_time AS "注册时间",
    evt."#os" AS "os",
    evt.pay_currency AS "原货币",
    evt.pay_amount AS "原金额",
    CAST(evt.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE) AS "折算美元金额",
    evt."#event_time" AS "订单时间",
    evt.cfg_id AS "商品ID",
    dim."cfg_id@name" AS "商品名称",
    evt.order_id AS "订单ID"
FROM ta.v_event_12 AS evt
LEFT JOIN UuidBase u
    ON evt.uuid = u.uuid
LEFT JOIN ta_dim.ta_exchange AS ex
    ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
LEFT JOIN ta_dim.dim_10_0_12842 AS dim
    ON evt.cfg_id = dim."cfg_id@shop_item_id"
WHERE
    evt.${PartDate:date1} 
    AND evt."$part_event" = 'charge'
    AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
    AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
    AND evt.pay_currency NOT IN ('COIN', 'kuroko_pay')
ORDER BY
    evt."#event_time" DESC;
