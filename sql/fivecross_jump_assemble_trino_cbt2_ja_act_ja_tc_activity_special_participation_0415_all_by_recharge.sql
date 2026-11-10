/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 大盘用户 — 每日 (12:00-24:00) 特供活动参与深度分析 (按付费分层)
Cohort  : 2026-04-15 ~ 2026-04-17 期间 12:00-24:00 有活跃记录的全量用户
          排除黑名单 (internal_users, is_water)
分层逻辑 : 锁定用户【截至4月17日】的累计充值总额 (USD) 划分固定档位
样本校准 : 参与率分母调整为【当日该分层活跃人数(DAU)】，非三日累计总人数
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 大盘目标群体定义 (三天内 12:00-24:00 有活跃记录的用户)
--------------------------------------------------------------------------------
TargetCohort AS (
    SELECT DISTINCT
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'),
                 v.sdkcommon.lcx_id)                                            AS lcx_id
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'),
                    v.sdkcommon.lcx_id) = ub.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
      AND ub.lcx_id IS NULL
      AND COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'),
                   v.sdkcommon.lcx_id) IS NOT NULL
),

--------------------------------------------------------------------------------
-- 3. 累计充值分层 (锁定 4/15 - 4/17 累计充值)
--------------------------------------------------------------------------------
CumulativeRecharge AS (
    SELECT 
        v."#account_id" AS lcx_id,
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(ex.exchange, 1)) AS total_usd
    FROM ta.v_event_16 v
    INNER JOIN TargetCohort uw ON v."#account_id" = uw.lcx_id
    LEFT JOIN ta_dim.ta_exchange ex ON v."$part_date" = ex.ex_date 
        AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17' 
    GROUP BY 1
),

UserTiers AS (
    SELECT 
        uw.lcx_id,
        CASE 
            WHEN cr.total_usd IS NULL OR cr.total_usd = 0 THEN '0. 非充值用户'
            WHEN cr.total_usd <= 1   THEN 'a. (0,1]'
            WHEN cr.total_usd <= 10  THEN 'b. (1,10]'
            WHEN cr.total_usd <= 50  THEN 'c. (10,50]'
            WHEN cr.total_usd <= 100 THEN 'd. (50,100]'
            WHEN cr.total_usd <= 300 THEN 'e. (100,300]'
            WHEN cr.total_usd <= 500 THEN 'f. (300,500]'
            ELSE 'g. (500,∞]'
        END AS recharge_tier
    FROM TargetCohort uw
    LEFT JOIN CumulativeRecharge cr ON uw.lcx_id = cr.lcx_id
),

--------------------------------------------------------------------------------
-- 4. 样本基数：当日分层活跃人数 (DAU)
--------------------------------------------------------------------------------
DailyActiveTiers AS (
    SELECT 
        v."$part_date" AS log_date,
        ut.recharge_tier,
        COUNT(DISTINCT ut.lcx_id) AS tier_dau
    FROM ta.v_event_16 v
    INNER JOIN UserTiers ut 
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'),
                    v.sdkcommon.lcx_id) = ut.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 5. 活动数据提取
--------------------------------------------------------------------------------

PurchaseLogs AS (
    SELECT
        v."$part_date"                                                          AS log_date,
        v."#account_id"                                                         AS lcx_id,
        CASE
            WHEN JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid')
                 = 'com.dgames.g65002007.apple.CBT.nt330.gift4' THEN 'gift12 (含10张阅览券)'
            WHEN JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid')
                 = 'com.dgames.g65002007.apple.CBT.nt670.gift5'  THEN 'gift5 (含20张阅览券)'
            ELSE '其他付费礼包'
        END                                                                     AS action_name,
        CASE
            WHEN JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid')
                 = 'com.dgames.g65002007.apple.CBT.nt330.gift4' THEN 10
            WHEN JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid')
                 = 'com.dgames.g65002007.apple.CBT.nt670.gift5'  THEN 20
            ELSE 0
        END                                                                     AS voucher_per_order,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)
            / COALESCE(ex.exchange, 1)                                          AS usd_val
    FROM ta.v_event_16 v
    INNER JOIN TargetCohort tc ON v."#account_id" = tc.lcx_id
    LEFT JOIN ta_dim.ta_exchange ex
        ON v."$part_date" = ex.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid') IN (
              'com.dgames.g65002007.apple.CBT.nt670.gift5',
              'com.dgames.g65002007.apple.CBT.nt330.gift4',
              'com.dgames.g65002007.apple.CBT.nt290.gift13',
              'com.dgames.g65002007.apple.CBT.nt370.gift12',
              'com.dgames.g65002007.apple.CBT.nt370.gift19'
          )
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
),

PriceDim AS (
    SELECT
        CAST("os@goods_id" AS VARCHAR) AS goods_id,
        CAST("os@currency_id" AS INTEGER) AS currency_id,
        COALESCE(TRY_CAST("os@value_discount" AS DOUBLE), TRY_CAST("os@value" AS DOUBLE)) AS unit_price
    FROM ta_dim.dim_16_0_23696
),

ShopLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        CASE
            WHEN CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) = '208011' THEN '208011 (含5张阅览券)'
            WHEN CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) = '201004' THEN '201004 意志结晶'
            ELSE '其他商店商品'
        END AS action_name,
        v.buy_count AS order_count,
        CASE WHEN CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) = '208011' THEN 5 * v.buy_count ELSE 1 END AS voucher_gained,
        ROUND(CASE WHEN pd.currency_id = 2 THEN pd.unit_price * v.buy_count ELSE 0 END, 2) AS crystal_consumed,
        ROUND(CASE WHEN pd.currency_id IN (3, 8) THEN pd.unit_price * v.buy_count ELSE 0 END, 2) AS star_consumed
    FROM ta.v_event_16 v
    LEFT JOIN PriceDim pd ON CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) = pd.goods_id
    INNER JOIN TargetCohort tc ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = tc.lcx_id
    WHERE v."$part_event" = 'active_shop'
      AND CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) IN ('208011', '201004')
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
),

VoucherGainLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        SUM(CASE WHEN t.item_id = 14 AND t.diff > 0 THEN t.diff ELSE 0 END) AS diff,
        SUM(CASE WHEN t.item_id = 14 AND t.diff > 0 THEN t.diff ELSE 0 END) * 100 AS crystal_consumed
    FROM ta.v_event_16 v
    INNER JOIN TargetCohort tc ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = tc.lcx_id
    CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
    WHERE v."$part_event" = 'item_exchange'
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
    GROUP BY 1, 2
    HAVING SUM(CASE WHEN t.item_id = 14 AND t.diff > 0 THEN t.diff ELSE 0 END) > 0
),

VoucherConsumeLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        v."count" AS consume_count
    FROM ta.v_event_16 v
    INNER JOIN TargetCohort tc ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = tc.lcx_id
    WHERE v."$part_event" = 'active_gacha'
      AND CAST(v.gacha_id AS INTEGER) IN (2, 3)
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
),

SystemRewardLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        v."$part_event" AS event_name,
        SUM(CASE WHEN t.item_id = 14 AND t.diff > 0 THEN t.diff ELSE 0 END) AS voucher_gained
    FROM ta.v_event_16 v
    INNER JOIN TargetCohort tc ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = tc.lcx_id
    CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
    WHERE (v."$part_event" LIKE '%reward%' OR v."$part_event" LIKE '%mail%')
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      -- AND HOUR(v."#event_time") >= 12
    GROUP BY 1, 2, 3
    HAVING SUM(CASE WHEN t.item_id = 14 AND t.diff > 0 THEN t.diff ELSE 0 END) > 0
)

--------------------------------------------------------------------------------
-- 6. 汇总输出
--------------------------------------------------------------------------------

SELECT
    pl.log_date                                                                 AS "日期",
    ut.recharge_tier                                                            AS "付费分层",
    '直接购买 (PURCHASE)'                                                        AS "行为来源",
    pl.action_name                                                              AS "具体项",
    COUNT(DISTINCT pl.lcx_id)                                                   AS "参与人数",
    MAX(da.tier_dau)                                                            AS "当日活跃分层人数",
    ROUND(CAST(COUNT(DISTINCT pl.lcx_id) AS DOUBLE)
        / NULLIF(MAX(da.tier_dau), 0) * 100, 2)                                 AS "活跃参与率(%)",
    COUNT(*)                                                                    AS "购买次数",
    SUM(pl.voucher_per_order)                                                   AS "获得阅览券数",
    ROUND(SUM(pl.usd_val), 4)                                                   AS "付费金额(USD)",
    0                                                                           AS "消耗意志结晶",
    0                                                                           AS "消耗跃之星",
    NULL                                                                        AS "消耗次数",
    NULL                                                                        AS "消耗阅览券数"
FROM PurchaseLogs pl
INNER JOIN UserTiers ut ON pl.lcx_id = ut.lcx_id
INNER JOIN DailyActiveTiers da ON pl.log_date = da.log_date AND ut.recharge_tier = da.recharge_tier
GROUP BY 1, 2, 3, 4

UNION ALL

SELECT
    sl.log_date, ut.recharge_tier, '商店兑换 (active_shop)', sl.action_name,
    COUNT(DISTINCT sl.lcx_id), MAX(da.tier_dau),
    ROUND(CAST(COUNT(DISTINCT sl.lcx_id) AS DOUBLE) / NULLIF(MAX(da.tier_dau), 0) * 100, 2),
    SUM(sl.order_count), SUM(sl.voucher_gained), 0.0,
    SUM(sl.crystal_consumed), SUM(sl.star_consumed), NULL, NULL
FROM ShopLogs sl
INNER JOIN UserTiers ut ON sl.lcx_id = ut.lcx_id
INNER JOIN DailyActiveTiers da ON sl.log_date = da.log_date AND ut.recharge_tier = da.recharge_tier
GROUP BY 1, 2, 3, 4

UNION ALL

SELECT
    vg.log_date, ut.recharge_tier, '物品兑换 (item_exchange)', '阅览券获得(item_exchange)',
    COUNT(DISTINCT vg.lcx_id), MAX(da.tier_dau),
    ROUND(CAST(COUNT(DISTINCT vg.lcx_id) AS DOUBLE) / NULLIF(MAX(da.tier_dau), 0) * 100, 2),
    COUNT(*), SUM(vg.diff), 0.0, SUM(vg.crystal_consumed), 0, NULL, NULL
FROM VoucherGainLogs vg
INNER JOIN UserTiers ut ON vg.lcx_id = ut.lcx_id
INNER JOIN DailyActiveTiers da ON vg.log_date = da.log_date AND ut.recharge_tier = da.recharge_tier
GROUP BY 1, 2, 3, 4

UNION ALL

SELECT
    vc.log_date, ut.recharge_tier, '特供刊物抽取 (active_gacha)', '阅览券消耗(gacha_id=2/3)',
    COUNT(DISTINCT vc.lcx_id), MAX(da.tier_dau),
    ROUND(CAST(COUNT(DISTINCT vc.lcx_id) AS DOUBLE) / NULLIF(MAX(da.tier_dau), 0) * 100, 2),
    0, 0, 0.0, 0, 0,
    COUNT(*), SUM(vc.consume_count)
FROM VoucherConsumeLogs vc
INNER JOIN UserTiers ut ON vc.lcx_id = ut.lcx_id
INNER JOIN DailyActiveTiers da ON vc.log_date = da.log_date AND ut.recharge_tier = da.recharge_tier
GROUP BY 1, 2, 3, 4

UNION ALL

SELECT
    sr.log_date, ut.recharge_tier, '系统奖励 (reward)', sr.event_name,
    COUNT(DISTINCT sr.lcx_id), MAX(da.tier_dau),
    ROUND(CAST(COUNT(DISTINCT sr.lcx_id) AS DOUBLE) / NULLIF(MAX(da.tier_dau), 0) * 100, 2),
    COUNT(*), SUM(sr.voucher_gained), 0.0, 0, 0, NULL, NULL
FROM SystemRewardLogs sr
INNER JOIN UserTiers ut ON sr.lcx_id = ut.lcx_id
INNER JOIN DailyActiveTiers da ON sr.log_date = da.log_date AND ut.recharge_tier = da.recharge_tier
GROUP BY 1, 2, 3, 4

UNION ALL

SELECT
    summary.log_date, ut.recharge_tier, '【每日活跃分层汇总】', summary.direction,
    COUNT(DISTINCT summary.lcx_id), MAX(da.tier_dau),
    ROUND(CAST(COUNT(DISTINCT summary.lcx_id) AS DOUBLE) / NULLIF(MAX(da.tier_dau), 0) * 100, 2),
    COUNT(*), SUM(summary.voucher_count), ROUND(SUM(summary.usd_val), 4), 0, 0, NULL, NULL
FROM (
    SELECT log_date, lcx_id, '特供阅览券 累计兑换量' AS direction, voucher_per_order AS voucher_count, usd_val FROM PurchaseLogs
    UNION ALL
    SELECT log_date, lcx_id, '特供阅览券 累计兑换量' AS direction, voucher_gained, 0.0 FROM ShopLogs WHERE voucher_gained > 0
    UNION ALL
    SELECT log_date, lcx_id, '特供阅览券 累计兑换量' AS direction, ABS(diff), 0.0 FROM VoucherGainLogs
    UNION ALL
    SELECT log_date, lcx_id, '特供阅览券 累计兑换量' AS direction, voucher_gained, 0.0 FROM SystemRewardLogs
    UNION ALL
    SELECT log_date, lcx_id, '特供阅览券 累计消耗量' AS direction, consume_count, 0.0 FROM VoucherConsumeLogs
) summary
INNER JOIN UserTiers ut ON summary.lcx_id = ut.lcx_id
INNER JOIN DailyActiveTiers da ON summary.log_date = da.log_date AND ut.recharge_tier = da.recharge_tier
GROUP BY 1, 2, 3, 4

ORDER BY "日期" ASC, "付费分层" ASC, "行为来源" ASC, "具体项" ASC;
