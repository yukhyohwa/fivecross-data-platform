/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 物品/道具销售流水报表 (排除内部测试账号)
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. 内部用户名单 (黑名单)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users')
),

-- 2. 免费福利币消耗明细
WalletSpend AS (
    SELECT 
        lcxtransactionid,
        ABS(freeamount) AS freeamount
    FROM ta.v_event_16
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
),

-- 3. 基础流水数据 (关联黑名单过滤)
BaseSales AS (
    SELECT 
        v."$part_date",
        v."#account_id",
        v.payload.productid AS productid,
        v.payload.curamt AS amt,
        v.payload.cur AS cur,
        v.payload.purchaseid AS purchaseid
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'PURCHASE'
      AND v.payload.validationtype <>'SANDBOX_RECEIPT'
      AND ub."#account_id" IS NULL -- 排除内部号
)

SELECT 
    ${Selector:timetype} AS time_dimension,
    s4."payload.productid@product_category" AS "物品分类",
    s1.productid AS "物品ID",
    s4."payload.productid@product_name" AS "物品名称",
    COUNT(DISTINCT s1."#account_id") AS "付费人数(PU)",
    SUM((CAST(s1.amt AS DOUBLE) - COALESCE(s2.freeamount, 0)) / s3.exchange) AS "总流水(USD)",
    CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) AS "日期范围"
FROM BaseSales s1
LEFT JOIN WalletSpend s2 ON s1.purchaseid = s2.lcxtransactionid
LEFT JOIN ta_dim.ta_exchange s3 ON s1."$part_date" = s3.ex_date AND s1.cur = s3.currency
LEFT JOIN ta_dim.dim_16_0_23989 s4 ON s1.productid = s4."payload.productid@product_id"
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 6 DESC;
