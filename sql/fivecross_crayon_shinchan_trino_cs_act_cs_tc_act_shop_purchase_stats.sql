/*
蜡笔小新繁中 OBT｜商店购买与伙伴技能抽卡。
日期：${PartDate:date}；粒度：${Selector:timetype}（D/W/M/S/A）。
人数按 fc_id 去重；排除 OBT 内部、Windows、水号；不依赖注册时间。
仅读取所选日期、2026-10-14 起的 login/item_change/shop_buy/skill_get/Companion_get。
商品维表按 ID 去重；消耗取 before-after 的正数；晶钻原始值除以 100。
shop_buy 优先采用 shop_item 明确上报的支付额，其余以同日、同账号、同角色、同秒 item_change 补充。
注意：缺少交易 ID 时，同秒多笔购买/抽卡仍可能重复匹配消耗，不能视为交易级精确归因。
抽卡兑换量沿用原口径：红钻消耗 / 15；晶钻商城兑换量沿用每条 shop_buy 计 1。
输出字段名称、顺序不变。活跃人数使用 login。
URL:https://ss-web.5xgames.com/#/tga/ide/18_4762?fromPanel=18_913
*/
WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_windows_new', 'is_water_new', 'internal_users_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
ProductDim AS (
    SELECT
        TRY_CAST("product_id@product_id" AS BIGINT) AS product_id,
        MAX(NULLIF(TRIM("product_id@product_name_tc"), '')) AS product_name
    FROM ta_dim.dim_18_0_52801
    GROUP BY 1
),
ActiveUsers AS (
    SELECT
        CASE ${Selector:timetype}
            WHEN 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'A' THEN '已合并'
        END AS time_dim,
        COUNT(DISTINCT TRIM(CAST(v.fc_id AS VARCHAR))) AS active_users
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'login'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),
CurrencyChange AS (
    SELECT
        v."$part_date" AS dt,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        DATE_TRUNC('second', CAST(v."#event_time" AS TIMESTAMP)) AS event_second,
        SUM(REDUCE(v.a_rst, CAST(0 AS BIGINT),
            (s, x) -> s + CASE
                WHEN TRY_CAST(x.id AS BIGINT) = 10009
                 AND TRY_CAST(x.before AS BIGINT) > TRY_CAST(x.after AS BIGINT)
                THEN TRY_CAST(x.before AS BIGINT) - TRY_CAST(x.after AS BIGINT)
                ELSE 0 END, s -> s)) AS red_consumed,
        SUM(REDUCE(v.a_rst, CAST(0 AS BIGINT),
            (s, x) -> s + CASE
                WHEN TRY_CAST(x.id AS BIGINT) = 10206
                 AND TRY_CAST(x.before AS BIGINT) > TRY_CAST(x.after AS BIGINT)
                THEN TRY_CAST(x.before AS BIGINT) - TRY_CAST(x.after AS BIGINT)
                ELSE 0 END, s -> s)) AS gems_consumed
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'item_change'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND ANY_MATCH(v.a_rst, x -> TRY_CAST(x.id AS BIGINT) IN (10009, 10206)
          AND TRY_CAST(x.before AS BIGINT) > TRY_CAST(x.after AS BIGINT))
    GROUP BY 1, 2, 3, 4
),
PurchaseEvents AS (
    SELECT
        v."$part_date" AS dt,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        DATE_TRUNC('second', CAST(v."#event_time" AS TIMESTAMP)) AS event_second,
        v."$part_event" AS event_name,
        CASE ${Selector:timetype}
            WHEN 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'A' THEN '已合并'
        END AS time_dim,
        v.shop_item,
        v.a_rst
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" IN ('shop_buy', 'skill_get', 'Companion_get')
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),
PurchaseCosts AS (
    SELECT
        p.*,
        CASE WHEN p.event_name = 'shop_buy'
             THEN REDUCE(p.shop_item, CAST(0 AS DOUBLE), (s, x) -> s +
                  CASE WHEN TRY_CAST(x.item_id AS BIGINT) = 10009
                       THEN COALESCE(TRY_CAST(x.num AS DOUBLE), 0) ELSE 0 END, s -> s)
        END AS direct_red,
        CASE WHEN p.event_name = 'shop_buy'
             THEN REDUCE(p.shop_item, CAST(0 AS DOUBLE), (s, x) -> s +
                  CASE WHEN TRY_CAST(x.item_id AS BIGINT) = 10206
                       THEN COALESCE(TRY_CAST(x.num AS DOUBLE), 0) ELSE 0 END, s -> s)
        END AS direct_gems,
        ic.red_consumed,
        ic.gems_consumed
    FROM PurchaseEvents p
    LEFT JOIN CurrencyChange ic
      ON p.dt = ic.dt AND p.fc_id = ic.fc_id AND p.role_id = ic.role_id
     AND p.event_second = ic.event_second
),
PurchaseRows AS (
    SELECT
        p.time_dim,
        p.fc_id,
        CASE WHEN p.event_name <> 'shop_buy' THEN '伙伴技能抽卡'
             WHEN TRY_CAST(p.shop_item[1].shop_id AS BIGINT) > 10000 THEN '晶钻商城'
             ELSE '红钻商城' END AS shop_name,
        CASE p.event_name
            WHEN 'skill_get' THEN '10066'
            WHEN 'Companion_get' THEN '10170'
            ELSE COALESCE(CAST(d.product_id AS VARCHAR),
                ARRAY_JOIN(TRANSFORM(p.a_rst, x -> CAST(TRY_CAST(x.id AS BIGINT) AS VARCHAR)), '+'))
        END AS item_id,
        CASE p.event_name
            WHEN 'skill_get' THEN '技能券'
            WHEN 'Companion_get' THEN '伙伴券'
            ELSE COALESCE(d.product_name, ARRAY_JOIN(TRANSFORM(p.a_rst, x -> CAST(x.name AS VARCHAR)), '+'))
        END AS item_name,
        CASE WHEN p.event_name <> 'shop_buy' THEN COALESCE(p.red_consumed, 0) / 15.0
             WHEN TRY_CAST(p.shop_item[1].shop_id AS BIGINT) > 10000 THEN 1.0
             ELSE TRY_CAST(p.a_rst[1].diff AS DOUBLE) END AS exchange_qty,
        CASE WHEN p.event_name = 'shop_buy'
             THEN COALESCE(NULLIF(p.direct_gems, 0),
                  CASE WHEN COALESCE(p.direct_red, 0) = 0 THEN p.gems_consumed END, 0)
             ELSE COALESCE(p.gems_consumed, 0) END / 100.0 AS gems_cost,
        CASE WHEN p.event_name = 'shop_buy'
             THEN COALESCE(NULLIF(p.direct_red, 0),
                  CASE WHEN COALESCE(p.direct_gems, 0) = 0 THEN p.red_consumed END, 0)
             ELSE COALESCE(p.red_consumed, 0) END AS red_cost
    FROM PurchaseCosts p
    LEFT JOIN ProductDim d
      ON p.event_name = 'shop_buy'
     AND TRY_CAST(p.shop_item[1].shop_id AS BIGINT) = d.product_id
    WHERE p.event_name = 'shop_buy' OR p.red_consumed > 0
)
SELECT
    p.time_dim AS "时间维度",
    p.shop_name AS "商店ID",
    p.item_id AS "道具ID",
    p.item_name AS "道具名称",
    SUM(p.exchange_qty) AS "兑换总量",
    COUNT(DISTINCT p.fc_id) AS "兑换人数",
    COALESCE(MAX(a.active_users), 0) AS "活跃人数",
    SUM(p.gems_cost) AS "消耗晶钻数",
    SUM(p.red_cost) AS "消耗红钻数"
FROM PurchaseRows p
LEFT JOIN ActiveUsers a ON p.time_dim = a.time_dim
GROUP BY 1, 2, 3, 4
HAVING SUM(p.gems_cost) > 0 OR SUM(p.red_cost) > 0
ORDER BY "商店ID", "兑换总量" DESC;
