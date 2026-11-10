/*
================================================================================
Game: Jump Assemble (众星之聚) - OBT
Description: 商城购买与兑换行为分析 - 区分充值区间的消耗统计
             - 常规 active_shop 消耗来自价格维表 ta_dim.dim_16_0_23696
             - gacha / 刊物类兑换：
               1) item_exchange 识别获得的道具
               2) 用同账号 + 同秒 关联 resource_change
               3) resource_change 中负向 diff / nums 作为真实货币消耗
             - 黑名单：排除 internal_users 与 is_water
================================================================================
*/

WITH
-------------------------------------------------------
-- 1. 黑名单定义
-------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-------------------------------------------------------
-- 2. 统计周期内充值金额与充值区间
-------------------------------------------------------
UserRecharge AS (
    SELECT
        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
        COALESCE(SUM(v.payload.curamt / s3.exchange), 0) AS total_revenue_usd
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
    LEFT JOIN ta_dim.ta_exchange s3
        ON v."$part_date" = s3.ex_date
       AND v.payload.cur = s3.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL
    GROUP BY 1
),

UserRechargeTier AS (
    SELECT
        lcx_id,
        CASE
            WHEN total_revenue_usd = 0 THEN '0.未充值'
            WHEN total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM UserRecharge
),

-------------------------------------------------------
-- 3. 价格维表：active_shop 专用
-------------------------------------------------------
PriceDimPivot AS (
    SELECT
        goods_id,
        MAX(item_name) AS item_name,
        MAX(CASE WHEN currency_id = 1 THEN unit_price ELSE 0.0 END) AS unit_price_1,
        MAX(CASE WHEN currency_id = 2 THEN unit_price ELSE 0.0 END) AS unit_price_2,
        MAX(CASE WHEN currency_id IN (3) THEN unit_price ELSE 0.0 END) AS unit_price_3_8, --,8
        MAX(CASE WHEN currency_id = 7 THEN unit_price ELSE 0.0 END) AS unit_price_7,
        MAX(CASE WHEN currency_id = 9 THEN unit_price ELSE 0.0 END) AS unit_price_9
    FROM (
        SELECT
            CAST(TRY_CAST(TRY_CAST("os@goods_id" AS DOUBLE) AS INTEGER) AS VARCHAR) AS goods_id,
            CAST("os@currency_id" AS INTEGER) AS currency_id,
            COALESCE(
                TRY_CAST("os@value_discount" AS DOUBLE),
                TRY_CAST("os@value" AS DOUBLE)
            ) AS unit_price,
            "os@item_name" AS item_name
        FROM ta_dim.dim_16_0_23696
    )
    GROUP BY 1
),

-------------------------------------------------------
-- 4. 常规商城购买 active_shop
-------------------------------------------------------
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

        CAST(CAST(CAST(v.shop_id AS DOUBLE) AS INTEGER) AS VARCHAR) AS shop_id,
        CAST(CAST(CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR) AS goods_id,

        v.buy_count,
        v.buy_nums
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) = ub.lcx_id
    WHERE v."$part_event" = 'active_shop'
      AND v."$part_date" >= '2026-04-15'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL
),

-------------------------------------------------------
-- 5. item_exchange：只识别兑换获得的目标道具
-------------------------------------------------------
ItemExchangeTargets AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,

        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) AS lcx_id,
        DATE_TRUNC('second', CAST(v."#event_time" AS timestamp(3))) AS event_time_sec,

        t.item_id,
        SUM(t.diff) AS buy_nums,
        COUNT(*) AS buy_count
    FROM ta.v_event_23 v
    CROSS JOIN UNNEST(v.resourceInfo) AS t(item_id, prev, diff, after)
    LEFT JOIN UserBlacklist ub
        ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) = ub.lcx_id
    WHERE v."$part_event" = 'item_exchange'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND t.item_id IN (10, 14, 32)
      AND t.diff > 0
    GROUP BY 1, 2, 3, 4
),

-------------------------------------------------------
-- 6. resource_change：同账号 + 同秒真实货币消耗
-- 注意：这里只取 resource_change，不取 resource_exchange
-------------------------------------------------------
ResourceChangeCosts AS (
    SELECT
        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) AS lcx_id,
        DATE_TRUNC('second', CAST(v."#event_time" AS timestamp(3))) AS event_time_sec,

        SUM(CASE WHEN v.id = 1 AND v.nums < 0 THEN ABS(v.nums) ELSE 0 END) AS cost_1,
        SUM(CASE WHEN v.id = 2 AND v.nums < 0 THEN ABS(v.nums) ELSE 0 END) AS cost_2,
        SUM(CASE WHEN v.id IN (3, 8) AND v.nums < 0 THEN ABS(v.nums) ELSE 0 END) AS cost_3_8,
        SUM(CASE WHEN v.id = 7 AND v.nums < 0 THEN ABS(v.nums) ELSE 0 END) AS cost_7,
        SUM(CASE WHEN v.id = 9 AND v.nums < 0 THEN ABS(v.nums) ELSE 0 END) AS cost_9

    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
        ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) = ub.lcx_id
    WHERE v."$part_event" = 'resource_change'
      AND ${PartDate:date1}
      AND ub.lcx_id IS NULL
      AND v.id IN (2, 3)  --,8
      AND v.nums < 0
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 7. item_exchange 关联 resource_change
-------------------------------------------------------
ItemExchangeCalculated AS (
    SELECT
        t.time_dimension,
        t.lcx_id,

        CASE
            WHEN t.item_id = 10 THEN '限时刊物'
            WHEN t.item_id = 14 THEN '特供刊物'
            WHEN t.item_id = 32 THEN '普通刊物'
            ELSE '其他'
        END AS shop_name,

        CASE
            WHEN t.item_id = 10 THEN '限时阅览券'
            WHEN t.item_id = 14 THEN '特供阅览券'
            WHEN t.item_id = 32 THEN '普通阅览券'
            ELSE '其他'
        END AS goods_name,

        t.buy_count,
        t.buy_nums,

        COALESCE(rc.cost_1, 0.0) AS cost_1,
        COALESCE(rc.cost_2, 0.0) AS cost_2,
        COALESCE(rc.cost_3_8, 0.0) AS cost_3_8,
        COALESCE(rc.cost_7, 0.0) AS cost_7,
        COALESCE(rc.cost_9, 0.0) AS cost_9

    FROM ItemExchangeTargets t
    LEFT JOIN ResourceChangeCosts rc
        ON t.lcx_id = rc.lcx_id
       AND t.event_time_sec = rc.event_time_sec
),

-------------------------------------------------------
-- 8. 统一计算
-------------------------------------------------------
CalculatedMid AS (
    ---------------------------------------------------
    -- A. active_shop：价格维表计算消耗
    ---------------------------------------------------
    SELECT
        rp.time_dimension,
        rp.lcx_id,

        COALESCE(s3."shop_id@shopname", rp.shop_id) AS shop_name,
        COALESCE(pd.item_name, s4."goods_id@goods_name", rp.goods_id) AS goods_name,

        rp.buy_count,
        rp.buy_nums,

        ROUND(COALESCE(pd.unit_price_1, 0.0) * rp.buy_count, 2) AS cost_1,
        ROUND(COALESCE(pd.unit_price_2, 0.0) * rp.buy_count, 2) AS cost_2,
        ROUND(COALESCE(pd.unit_price_3_8, 0.0) * rp.buy_count, 2) AS cost_3_8,
        ROUND(COALESCE(pd.unit_price_7, 0.0) * rp.buy_count, 2) AS cost_7,
        ROUND(COALESCE(pd.unit_price_9, 0.0) * rp.buy_count, 2) AS cost_9

    FROM RawPurchases rp
    LEFT JOIN PriceDimPivot pd
        ON rp.goods_id = pd.goods_id
    LEFT JOIN ta_dim.dim_16_0_24767 s3
        ON rp.shop_id = CAST(CAST(s3."shop_id@shopid" AS INTEGER) AS VARCHAR)
    LEFT JOIN ta_dim.dim_16_0_24765 s4
        ON rp.goods_id = CAST(CAST(s4."goods_id@goods_id" AS INTEGER) AS VARCHAR)

    UNION ALL

    ---------------------------------------------------
    -- B. item_exchange + resource_change
    ---------------------------------------------------
    SELECT
        time_dimension,
        lcx_id,
        shop_name,
        goods_name,
        buy_count,
        buy_nums,
        cost_1,
        cost_2,
        cost_3_8,
        cost_7,
        cost_9
    FROM ItemExchangeCalculated
)

-------------------------------------------------------
-- 9. 最终汇总
-------------------------------------------------------
SELECT
    c.time_dimension AS "时间维度",
    COALESCE(rt.recharge_tier, '0.未充值') AS "充值区间",
    c.shop_name AS "商店名称",
    c.goods_name AS "商品名",

    COUNT(DISTINCT c.lcx_id) AS "购买用户数",
    SUM(c.buy_count) AS "购买总次数",
    SUM(c.buy_nums) AS "购买总量",

    ROUND(SUM(c.cost_1), 2) AS "消耗纪念币数",
    ROUND(SUM(c.cost_2), 2) AS "消耗意志结晶数",
    ROUND(SUM(c.cost_3_8), 2) AS "消耗跃之星数",
    ROUND(SUM(c.cost_7), 2) AS "消耗觉醒币数",
    ROUND(SUM(c.cost_9), 2) AS "消耗天赋币数"

FROM CalculatedMid c
LEFT JOIN UserRechargeTier rt
    ON c.lcx_id = rt.lcx_id
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 2 ASC, 6 DESC;
