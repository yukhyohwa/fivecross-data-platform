/*
================================================================================
Game: Jump Assemble (众星之聚) - OBT
Description: 商城兑换行为统计（active_shop 获得 + resource_change 消耗 + 维表）
             - 价格来源：ta_dim.dim_16_0_23696
             - 商店维表：ta_dim.dim_16_0_24767
             - 商品维表：ta_dim.dim_16_0_24765
================================================================================
*/

WITH

-- 价格维表
PriceDim AS (
    SELECT
        CAST("os@goods_id" AS VARCHAR) AS goods_id,
        CAST("os@item_id" AS VARCHAR) AS item_id,
        CAST("os@currency_id" AS INTEGER) AS currency_id,
        COALESCE(TRY_CAST("os@value_discount" AS DOUBLE), TRY_CAST("os@value" AS DOUBLE)) AS unit_price,
        "os@item_name" AS item_name
    FROM ta_dim.dim_16_0_23696
),

-- active_shop 记录获得道具
ActiveShop AS (
    SELECT
        v."$part_date",
        v."#account_id" AS user_id,
        CAST(v."#event_time" AS timestamp(3)) AS event_time,
        COALESCE(CAST(CAST(TRY_CAST(v.shop_id AS DOUBLE) AS INTEGER) AS VARCHAR), CAST(v.shop_id AS VARCHAR)) AS shop_id,
        COALESCE(CAST(CAST(TRY_CAST(v.goods_id AS DOUBLE) AS INTEGER) AS VARCHAR), CAST(v.goods_id AS VARCHAR)) AS goods_id,
        COALESCE(MAX(TRY_CAST(v.buy_count AS BIGINT)), 1) AS buy_count,
        COALESCE(MAX(TRY_CAST(v.buy_nums AS BIGINT)), 1) AS buy_nums,

        ARRAY_JOIN(
            ARRAY_AGG(DISTINCT CAST(CAST(t.item_id AS INTEGER) AS VARCHAR))
                FILTER (WHERE TRY_CAST(t.diff AS BIGINT) > 0),
            '+'
        ) AS gain_item_ids,

        SUM(
            CASE
                WHEN TRY_CAST(t.diff AS BIGINT) > 0
                THEN TRY_CAST(t.diff AS BIGINT)
                ELSE 0
            END
        ) AS total_gain

    FROM ta.v_event_16 v
    LEFT JOIN UNNEST(resourceInfo) AS t(item_id, before, diff, after) ON TRUE
    WHERE ${PartDate:date1}
      AND v."#event_name" = 'active_shop'
      AND TRY_CAST(t.after AS BIGINT) > TRY_CAST(t.before AS BIGINT)
    GROUP BY 1, 2, 3, 4, 5
),

-- resource_change 记录消耗道具
ResourceConsume AS (
    SELECT
        "#account_id" AS user_id,
        CAST("#event_time" AS timestamp(3)) AS event_time,

        ARRAY_JOIN(
            ARRAY_AGG(DISTINCT CAST(CAST(id AS INTEGER) AS VARCHAR))
                FILTER (WHERE TRY_CAST(nums AS BIGINT) < 0),
            '+'
        ) AS consume_item_ids,

        SUM(ABS(TRY_CAST(nums AS BIGINT))) AS total_consume

    FROM ta.v_event_16
    WHERE ${PartDate:date1}
      AND "#event_name" = 'resource_change'
      AND TRY_CAST(nums AS BIGINT) < 0
      AND TRY_CAST(after AS BIGINT) < TRY_CAST(before AS BIGINT)
    GROUP BY 1, 2
),

-- 同一用户同一秒内，将 active_shop 获得与 resource_change 消耗拼回同一次兑换
ShopTrade AS (
    SELECT
        a."$part_date",
        a.user_id,
        a.event_time,
        a.shop_id,
        a.goods_id,
        a.buy_count,
        a.buy_nums,
        a.gain_item_ids,
        a.total_gain,
        c.consume_item_ids,
        c.total_consume
    FROM ActiveShop a
    LEFT JOIN ResourceConsume c
      ON a.user_id = c.user_id
     AND CAST(TO_UNIXTIME(CAST(a.event_time AS timestamp(3))) AS BIGINT)
       = CAST(TO_UNIXTIME(CAST(c.event_time AS timestamp(3))) AS BIGINT)
)

SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(st."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(st."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(st."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(st."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '已合并'
    END AS "时间维度",

    st.shop_id AS "商店ID",
    COALESCE(s3."shop_id@shopname", st.shop_id) AS "商店名称",
    st.goods_id AS "商品ID",
    COALESCE(pd.item_name, s4."goods_id@goods_name", st.goods_id) AS "商品名称",
    st.gain_item_ids AS "获得道具ID",
    st.consume_item_ids AS "消耗道具ID",

    SUM(st.total_gain) AS "获得总量",
    COUNT(*) AS "兑换次数",
    SUM(st.buy_count) AS "购买次数",
    SUM(st.buy_nums) AS "购买数量",
    COUNT(DISTINCT st.user_id) AS "兑换人数",
    COALESCE(SUM(st.total_consume), 0) AS "消耗道具数量",

    ROUND(SUM((CASE WHEN pd.currency_id = 1 THEN pd.unit_price ELSE 0 END) * st.buy_count), 2) AS "消耗纪念币数",
    ROUND(SUM((CASE WHEN pd.currency_id = 2 THEN pd.unit_price ELSE 0 END) * st.buy_count), 2) AS "消耗意志结晶数",
    ROUND(SUM((CASE WHEN pd.currency_id IN (3, 8) THEN pd.unit_price ELSE 0 END) * st.buy_count), 2) AS "消耗跃之星数",
    ROUND(SUM((CASE WHEN pd.currency_id = 7 THEN pd.unit_price ELSE 0 END) * st.buy_count), 2) AS "消耗觉醒币数",
    ROUND(SUM((CASE WHEN pd.currency_id = 9 THEN pd.unit_price ELSE 0 END) * st.buy_count), 2) AS "消耗天赋币数"

FROM ShopTrade st
LEFT JOIN PriceDim pd
  ON st.goods_id = pd.goods_id
LEFT JOIN ta_dim.dim_16_0_24767 s3
  ON st.shop_id = CAST(CAST(s3."shop_id@shopid" AS INTEGER) AS VARCHAR)
LEFT JOIN ta_dim.dim_16_0_24765 s4
  ON st.goods_id = CAST(CAST(s4."goods_id@goods_id" AS INTEGER) AS VARCHAR)
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY 1, 2, 4, 6, 7;
