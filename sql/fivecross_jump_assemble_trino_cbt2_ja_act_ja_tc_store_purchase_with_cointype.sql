/*
================================================================================
Game: Jump Assemble (众星之聚)
Description: 商城购买行为深度分析 (维表依赖+黑名单过滤)
             - 价格来源：ta_dim.dim_16_0_23696
             - 黑名单：排除 internal_users 与 is_water
             - 包含：常规商店 (active_shop) + 刊物兑换 (item_exchange)
================================================================================
*/

WITH DateRange AS (
    SELECT 
        ${Selector:timetype} AS time_dimension, 
        CONCAT(MIN("$part_date"), ' - ', MAX("$part_date")) AS date_range
    FROM ta.v_event_16
    WHERE "$part_event" = 'LOGIN_SUCCESS' AND ${PartDate:date1}
    GROUP BY 1
),

-- 1. 黑名单定义
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 2. 价格维表处理
PriceDim AS (
    SELECT 
        CAST("os@goods_id" AS VARCHAR) AS goods_id,
        CAST("os@item_id" AS VARCHAR) AS item_id,
        CAST("os@currency_id" AS INTEGER) AS currency_id,
        COALESCE(TRY_CAST("os@value_discount" AS DOUBLE), TRY_CAST("os@value" AS DOUBLE)) AS unit_price,
        "os@item_name" AS item_name
    FROM ta_dim.dim_16_0_23696
),

-- 3. 原始事件聚合
RawPurchases AS (
    SELECT 
       ${Selector:timetype} AS time_dimension,
       sdkcommon.lcx_id AS lcx_id,
       -- ID 格式清洗，确保匹配维表
       CAST(CAST(CAST(shop_id AS DOUBLE) AS INTEGER) AS VARCHAR) AS shop_id,
       CAST(CAST(CAST(goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) AS goods_id,
       buy_count,
       buy_nums
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub ON v.sdkcommon.lcx_id = ub.lcx_id
    WHERE v."$part_event" = 'active_shop' 
      AND v."$part_date" >= '2026-04-15'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL  -- 排除黑名单
),

-- 4. 统一数据格式计算消耗
CalculatedMid AS (
    -- 逻辑 A: 常规商店购买 (关联维表获取价格)
    SELECT 
        rp.time_dimension,
        rp.lcx_id,
        COALESCE(s3."shop_id@shopname", rp.shop_id) AS shop_name,
        COALESCE(pd.item_name, s4."goods_id@goods_name", rp.goods_id) AS goods_name,
        rp.buy_count,
        rp.buy_nums,
        ROUND((CASE WHEN pd.currency_id = 1 THEN pd.unit_price ELSE 0 END) * rp.buy_count, 2) AS cost_1,
        ROUND((CASE WHEN pd.currency_id = 2 THEN pd.unit_price ELSE 0 END) * rp.buy_count, 2) AS cost_2,
        ROUND((CASE WHEN pd.currency_id IN (3,8) THEN pd.unit_price ELSE 0 END) * rp.buy_count, 2) AS cost_3_8,
        ROUND((CASE WHEN pd.currency_id = 7 THEN pd.unit_price ELSE 0 END) * rp.buy_count, 2) AS cost_7,
        ROUND((CASE WHEN pd.currency_id = 9 THEN pd.unit_price ELSE 0 END) * rp.buy_count, 2) AS cost_9
    FROM RawPurchases rp
    LEFT JOIN PriceDim pd ON rp.goods_id = pd.goods_id
    LEFT JOIN ta_dim.dim_16_0_24767 s3 ON rp.shop_id = CAST(CAST(s3."shop_id@shopid" AS INTEGER) AS VARCHAR)
    LEFT JOIN ta_dim.dim_16_0_24765 s4 ON rp.goods_id = CAST(CAST(s4."goods_id@goods_id" AS INTEGER) AS VARCHAR)

    UNION ALL

    -- 逻辑 B: 物品兑换 (刊物类固定单价逻辑)
    SELECT 
        ${Selector:timetype} AS time_dimension,
        v.sdkcommon.lcx_id AS lcx_id,
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
    CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
    LEFT JOIN UserBlacklist ub ON v.sdkcommon.lcx_id = ub.lcx_id
    WHERE v."$part_event" = 'item_exchange'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL -- 排除黑名单
      AND t.item_id IN (10, 14, 32)
      AND t.diff > 0 -- 仅统计获得
)

-- 5. 最终汇总展示
SELECT 
    c.time_dimension,
    c.shop_name AS "商店名称",
    c.goods_name AS "商品名",
    SUM(c.cost_1) AS "消耗纪念币数",
    SUM(c.cost_2) AS "消耗意志结晶数",
    SUM(c.cost_3_8) AS "消耗跃之星数",
    SUM(c.cost_7) AS "消耗觉醒币数",
    SUM(c.cost_9) AS "消耗天赋币数",
    COUNT(DISTINCT c.lcx_id) AS "购买用户数",
    SUM(c.buy_count) AS "购买总次数",
    SUM(c.buy_nums) AS "购买总量",
    dr.date_range
FROM CalculatedMid c
LEFT JOIN DateRange dr ON c.time_dimension = dr.time_dimension
GROUP BY 1, 2, 3, dr.date_range
ORDER BY 1 DESC, 10 DESC;
