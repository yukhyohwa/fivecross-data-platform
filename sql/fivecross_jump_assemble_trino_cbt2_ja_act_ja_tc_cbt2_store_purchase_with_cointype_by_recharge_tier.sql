/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 4月15日-4月20日 iOS 用户每日消耗分析 (按截至4月17日累计充值分层)
Description: 
  - 统计逻辑：常规商店 (active_shop) + 刊物兑换 (item_exchange)
  - 分层逻辑：锁定用户【截至4月17日】的累计充值总额 (USD) 划分固定档位
  - 黑名单：排除 internal_users 与 is_water
  - 时间范围：消耗统计 (4/15 - 4/20), 充值统计 (4/15 - 4/17)
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 1. 基础过滤：iOS 用户 + 黑名单
--------------------------------------------------------------------------------
UserWhitelist AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    WHERE t1.cluster_name = 'fixed_os' AND t1.tag_value = 'iOS'
      AND t1."#varchar_id" NOT IN (
          SELECT "#varchar_id" FROM user_result_cluster_16 
          WHERE cluster_name IN ('internal_users', 'is_water')
      )
),

--------------------------------------------------------------------------------
-- 2. 累计充值档位计算 (截至 4月17日)
--------------------------------------------------------------------------------
CumulativeRecharge AS (
    SELECT 
        v."#account_id" AS lcx_id,
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(ex.exchange, 1)) AS total_usd
    FROM ta.v_event_16 v
    INNER JOIN UserWhitelist uw ON v."#account_id" = uw.lcx_id
    LEFT JOIN ta_dim.ta_exchange ex ON v."$part_date" = ex.ex_date 
        AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17' -- 锁定统计截止日期
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
    FROM UserWhitelist uw
    LEFT JOIN CumulativeRecharge cr ON uw.lcx_id = cr.lcx_id
),

--------------------------------------------------------------------------------
-- 3. 价格维表处理
--------------------------------------------------------------------------------
PriceDim AS (
    SELECT 
        CAST("os@goods_id" AS VARCHAR) AS goods_id,
        CAST("os@item_id" AS VARCHAR) AS item_id,
        CAST("os@currency_id" AS INTEGER) AS currency_id,
        COALESCE(TRY_CAST("os@value_discount" AS DOUBLE), TRY_CAST("os@value" AS DOUBLE)) AS unit_price,
        "os@item_name" AS item_name
    FROM ta_dim.dim_16_0_23696
),

--------------------------------------------------------------------------------
-- 4. 消耗数据采集 (4/15 - 4/20)
--------------------------------------------------------------------------------
RawConsumption AS (
    -- A: 常规商店购买
    SELECT 
       v."$part_date" AS log_date,
       COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
       COALESCE(s3."shop_id@shopname", CAST(CAST(CAST(v.shop_id AS DOUBLE) AS INTEGER) AS VARCHAR)) AS shop_name,
       COALESCE(pd.item_name, s4."goods_id@goods_name", CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR)) AS goods_name,
       v.buy_count,
       v.buy_nums,
       ROUND((CASE WHEN pd.currency_id = 1 THEN pd.unit_price ELSE 0 END) * v.buy_count, 2) AS cost_1,
       ROUND((CASE WHEN pd.currency_id = 2 THEN pd.unit_price ELSE 0 END) * v.buy_count, 2) AS cost_2,
       ROUND((CASE WHEN pd.currency_id IN (3,8) THEN pd.unit_price ELSE 0 END) * v.buy_count, 2) AS cost_3_8,
       ROUND((CASE WHEN pd.currency_id = 7 THEN pd.unit_price ELSE 0 END) * v.buy_count, 2) AS cost_7,
       ROUND((CASE WHEN pd.currency_id = 9 THEN pd.unit_price ELSE 0 END) * v.buy_count, 2) AS cost_9
    FROM ta.v_event_16 v
    INNER JOIN UserWhitelist uw ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = uw.lcx_id
    LEFT JOIN PriceDim pd ON CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) = pd.goods_id
    LEFT JOIN ta_dim.dim_16_0_24767 s3 ON CAST(CAST(CAST(v.shop_id AS DOUBLE) AS INTEGER) AS VARCHAR) = CAST(CAST(s3."shop_id@shopid" AS INTEGER) AS VARCHAR)
    LEFT JOIN ta_dim.dim_16_0_24765 s4 ON CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) = CAST(CAST(s4."goods_id@goods_id" AS INTEGER) AS VARCHAR)
    WHERE v."$part_event" = 'active_shop' 
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'

    UNION ALL

    -- B: 物品兑换 (刊物类)
    SELECT 
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        CASE 
            WHEN t.item_id = 10 THEN '限时刊物'
            WHEN t.item_id = 14 THEN '特供刊物'
            WHEN t.item_id = 32 THEN '普通刊物'
            ELSE '其他' END AS shop_name,
        CASE 
            WHEN t.item_id = 10 THEN '限时阅览券'
            WHEN t.item_id = 14 THEN '特供阅览券'
            WHEN t.item_id = 32 THEN '普通阅览券'
            ELSE '其他' END AS goods_name,
        t.diff AS buy_count,
        t.diff AS buy_nums,
        0 AS cost_1,
        CASE WHEN t.item_id = 14 THEN 100 * t.diff WHEN t.item_id = 32 THEN 50 * t.diff ELSE 0 END AS cost_2,
        CASE WHEN t.item_id = 10 THEN 150 * t.diff ELSE 0 END AS cost_3_8,
        0 AS cost_7,
        0 AS cost_9
    FROM ta.v_event_16 v
    INNER JOIN UserWhitelist uw ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = uw.lcx_id
    CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
    WHERE v."$part_event" = 'item_exchange'
      AND v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      AND t.item_id IN (10, 14, 32)
      AND t.diff > 0
)

--------------------------------------------------------------------------------
-- 5. 最终汇总展示
--------------------------------------------------------------------------------
SELECT 
    c.log_date AS "日期",
    ut.recharge_tier AS "截至4月17日累计充值档位 (USD)",
    c.shop_name AS "商店名称",
    c.goods_name AS "商品名",
    SUM(c.cost_1) AS "消耗纪念币数",
    SUM(c.cost_2) AS "消耗意志结晶数",
    SUM(c.cost_3_8) AS "消耗跃之星数",
    SUM(c.cost_7) AS "消耗觉醒币数",
    SUM(c.cost_9) AS "消耗天赋币数",
    COUNT(DISTINCT c.lcx_id) AS "购买用户数",
    SUM(c.buy_count) AS "购买总次数",
    SUM(c.buy_nums) AS "购买总量"
FROM RawConsumption c
INNER JOIN UserTiers ut ON c.lcx_id = ut.lcx_id
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 2 ASC, 10 DESC;
