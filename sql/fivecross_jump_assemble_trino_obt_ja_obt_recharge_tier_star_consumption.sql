/*
================================================================================
Game: Jump Assemble (众星之聚)
Description: 商城购买行为分析 - 分充值档的跃之星消耗统计
             - 充值分档以指定期间 ${PartDate:date1} 用户的累计充值金额(美元)为准
             - 跃之星价格来源：ta_dim.dim_16_0_23696 (进行 goods_id 唯一化聚合)
             - 黑名单：排除 internal_users 与 is_water
================================================================================
*/

WITH 
-- 1. 黑名单定义
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 2. 统计周期内活跃用户（用于做充值分档的基准用户集）
ActiveUsers AS (
    SELECT DISTINCT v."#account_id" AS lcx_id
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub.lcx_id
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'LOGIN_SUCCESS'
      AND ub.lcx_id IS NULL
),

-- 3. 计算每个活跃用户在统计周期内的累计充值金额(USD)
UserCumulativeRevenue AS (
    SELECT 
        t.lcx_id,
        COALESCE(SUM(v.payload.curamt / s3.exchange), 0) AS total_revenue_usd
    FROM ActiveUsers t
    LEFT JOIN ta.v_event_23 v ON t.lcx_id = v."#account_id"
        AND v."$part_event" = 'PURCHASE'
        AND ${PartDate:date1}
    LEFT JOIN ta_dim.ta_exchange s3 
        ON v."$part_date" = s3.ex_date 
        AND v.payload.cur = s3.currency
    GROUP BY 1
),

-- 4. 根据累计充值金额(USD)划分付费档位
UserTierAssignment AS (
    SELECT 
        lcx_id,
        CASE 
            WHEN total_revenue_usd = 0 THEN '0.免费用户'
            WHEN total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS pay_tier
    FROM UserCumulativeRevenue
),

-- 5. 价格维表唯一化聚合（仅提取 3 和 8 跃之星代币单价）
PriceDimPivot AS (
    SELECT 
        goods_id,
        MAX(item_name) AS item_name,
        MAX(CASE WHEN currency_id IN (3,8) THEN unit_price ELSE 0.0 END) AS unit_price_3_8
    FROM (
        SELECT 
            CAST(TRY_CAST(TRY_CAST("os@goods_id" AS DOUBLE) AS INTEGER) AS VARCHAR) AS goods_id,
            CAST("os@currency_id" AS INTEGER) AS currency_id,
            COALESCE(TRY_CAST("os@value_discount" AS DOUBLE), TRY_CAST("os@value" AS DOUBLE)) AS unit_price,
            "os@item_name" AS item_name
        FROM ta_dim.dim_16_0_23696
    )
    GROUP BY 1
),

-- 6. 原始商店购买事件集
RawPurchases AS (
    SELECT 
       CASE
           WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
           WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
           WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
           WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
           WHEN ${Selector:timetype} = 'A' THEN '已合并'
       END AS time_dimension,
       COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) AS lcx_id,
       CAST(CAST(CAST(shop_id AS DOUBLE) AS INTEGER) AS VARCHAR) AS shop_id,
       CAST(CAST(CAST(goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) AS goods_id,
       buy_count,
       buy_nums
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) = ub.lcx_id
    WHERE v."$part_event" = 'active_shop' 
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL
),

-- 7. 统一计算跃之星消耗明细
CalculatedMid AS (
    -- 逻辑 A: 常规商店购买
    SELECT 
        rp.time_dimension,
        rp.lcx_id,
        COALESCE(s3."shop_id@shopname", rp.shop_id) AS shop_name,
        COALESCE(pd.item_name, s4."goods_id@goods_name", rp.goods_id) AS goods_name,
        rp.buy_count,
        rp.buy_nums,
        ROUND(COALESCE(pd.unit_price_3_8, 0.0) * rp.buy_count, 2) AS cost_3_8
    FROM RawPurchases rp
    LEFT JOIN PriceDimPivot pd ON rp.goods_id = pd.goods_id
    LEFT JOIN ta_dim.dim_16_0_24767 s3 ON rp.shop_id = CAST(CAST(s3."shop_id@shopid" AS INTEGER) AS VARCHAR)
    LEFT JOIN ta_dim.dim_16_0_24765 s4 ON rp.goods_id = CAST(CAST(s4."goods_id@goods_id" AS INTEGER) AS VARCHAR)

    UNION ALL

    -- 逻辑 B: 物品兑换 (刊物类)
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) AS lcx_id,
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
        CASE WHEN t.item_id = 10 THEN 150 * t.diff ELSE 0 END AS cost_3_8
    FROM ta.v_event_23 v
    CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
    LEFT JOIN UserBlacklist ub ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) = ub.lcx_id
    WHERE v."$part_event" = 'item_exchange'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND t.item_id IN (10, 14, 32)
      AND t.diff > 0
)

-- 8. 按时间、付费档位、商店、商品聚合跃之星消耗
SELECT 
    c.time_dimension AS "时间维度",
    u.pay_tier AS "付费档位",
    c.shop_name AS "商店名称",
    c.goods_name AS "商品名",
    COUNT(DISTINCT c.lcx_id) AS "购买用户数",
    SUM(c.buy_count) AS "购买总次数",
    SUM(c.buy_nums) AS "购买总量",
    SUM(c.cost_3_8) AS "消耗跃之星数"
FROM CalculatedMid c
INNER JOIN UserTierAssignment u ON c.lcx_id = u.lcx_id
GROUP BY 1, 2, 3, 4
HAVING SUM(c.cost_3_8) > 0
ORDER BY 1 DESC, 2 ASC, 8 DESC;
