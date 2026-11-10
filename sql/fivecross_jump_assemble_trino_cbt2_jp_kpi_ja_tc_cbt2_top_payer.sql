/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese - TW/HK/MO)
Description: CBT2 (4/15 ~ 4/22) 充值排行 (Top Payer) 统计
             1. 排除测试黑名单用户 (internal_users, is_water)
             2. 统计非沙盒充值的累计 USD 金额
             3. 关联用户画像以获得国家、渠道、注册时间等基础信息
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    -- 排除内部测试与灌水黑名单用户
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

UserProfileDetail AS (
    -- 获取玩家维度的国家/地区、系统、渠道及注册时间等属性
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

UserCbt2Recharge AS (
    -- 统计有效玩家在 CBT2 期间 (4/15 ~ 4/22) 的累计真实充值 (USD)
    SELECT 
        v."#account_id" AS account_id,
        SUM(CAST(v.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1)) AS total_recharge_usd,
        COUNT(v.payload.purchaseid) AS purchase_count
    FROM ta.v_event_16 v
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND v.payload.cur = s5.currency
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-22'
      AND v."$part_event" = 'PURCHASE'
      AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
      AND ub.lcx_id IS NULL
    GROUP BY 1
)

SELECT 
    r.account_id AS "用户ID",
    ROUND(r.total_recharge_usd, 2) AS "总充值金额(USD)",
    r.purchase_count AS "充值次数",
    p.fixed_regdate AS "注册时间",
    p.fixed_country AS "国家/地区",
    p.fixed_affcode AS "渠道",
    p.fixed_os AS "系统"
FROM UserCbt2Recharge r
LEFT JOIN UserProfileDetail p ON r.account_id = p."#account_id"
ORDER BY r.total_recharge_usd DESC
LIMIT 10;
