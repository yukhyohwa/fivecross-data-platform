/*
================================================================================
项目    : 蜡笔小新 - TC 繁体大区 OBT
表名    : ta.v_event_18 / user_result_cluster_18 / ta_dim.dim_18_0_52801 /
          ta_dim.ta_exchange
描述    : 按商品统计充值和晶钻消耗，账号口径使用 fc_id。

口径：
1. 统计时间直接使用 ${PartDate:date1}，不关联注册事件，不额外限定开服日期。
2. 同一 fc_id 的多个角色合并为一个账号。
3. 充值黑名单：is_water_new、is_windows_new。
4. 晶钻消耗黑名单：is_water_new、is_windows_new、internal_users_new。
5. 黑名单账号字段使用 user_result_cluster_18."#varchar_id"。
6. a_rst 商品名称先按字典序严格排序后再拼接，避免同一商品组合仅因数组顺序不同而拆成多行。
7. 充值与晶钻数据按时间、商品ID、排序后商品内容关联，避免不同内容之间产生多对多重复计算。
8. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/
WITH
ChargeBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

GemsBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new', 'internal_users_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

ProductDim AS (
    -- 商品维表，用于统一名称、类别和 ID；每个商品 ID 只保留一行，避免维表重复放大指标
    SELECT
        CAST("product_id@product_id" AS INTEGER) AS pid,
        MAX("product_id@product_name_tc") AS pname,
        MAX("product_id@product_type") AS pcategory
    FROM ta_dim.dim_18_0_52801
    GROUP BY 1
),

ChargeData AS (
    -- 充值数据：按 fc_id 去重，排除水军和 Windows 黑名单
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,
        CAST(v.product_id AS INTEGER) AS pid,
        ARRAY_JOIN(
            ARRAY_SORT(
                FILTER(
                    TRANSFORM(v.a_rst, x -> CAST(x.name AS VARCHAR)),
                    x -> x IS NOT NULL
                )
            ),
            '+'
        ) AS content,
        COUNT(DISTINCT TRIM(CAST(v.fc_id AS VARCHAR))) AS pu,
        COUNT(1) AS buy_count,
        SUM(CAST(v.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1)) AS revenue_usd
    FROM ta.v_event_18 v
    LEFT JOIN ChargeBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ta_dim.ta_exchange s5
        ON v."$part_date" = s5.ex_date
       AND v.pay_currency = s5.currency
    WHERE v."$part_event" = 'charge'
      AND v.${PartDate:date1}
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND b.fc_id IS NULL
    GROUP BY 1, 2, 3
),

GemsData AS (
    -- 晶钻购买数据：额外排除 internal_users_new
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,
        CAST(v.shop_item[1].shop_id AS INTEGER) AS pid,
        ARRAY_JOIN(
            ARRAY_SORT(
                FILTER(
                    TRANSFORM(v.a_rst, x -> CAST(x.name AS VARCHAR)),
                    x -> x IS NOT NULL
                )
            ),
            '+'
        ) AS content,
        COUNT(DISTINCT TRIM(CAST(v.fc_id AS VARCHAR))) AS gems_pu,
        COUNT(1) AS gems_count,
        SUM(CASE WHEN v.shop_item[1].item_id = 10206 THEN v.shop_item[1].num END) / 100.0 AS gems_amount
    FROM ta.v_event_18 v
    LEFT JOIN GemsBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v."$part_event" = 'shop_buy'
      AND v.${PartDate:date1}
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND v.shop_item[1].item_id = 10206
      AND b.fc_id IS NULL
    GROUP BY 1, 2, 3
)

SELECT
    COALESCE(c.time_dimension, g.time_dimension) AS "时间维度",
    dp.pcategory AS "商品类别",
    COALESCE(c.pid, g.pid) AS "商品ID",
    dp.pname AS "商品名称",
    COALESCE(c.content, g.content) AS "商品内容",

    COALESCE(c.pu, 0) AS "充值人数",
    COALESCE(c.buy_count, 0) AS "充值笔数",
    COALESCE(c.revenue_usd, 0) AS "充值总金额(USD)",

    COALESCE(g.gems_pu, 0) AS "晶钻消耗人数",
    COALESCE(g.gems_count, 0) AS "晶钻消耗笔数",
    COALESCE(g.gems_amount, 0) AS "消耗晶钻总数"
FROM ChargeData c
FULL OUTER JOIN GemsData g
    ON c.time_dimension = g.time_dimension
   AND c.pid = g.pid
   AND c.content IS NOT DISTINCT FROM g.content
LEFT JOIN ProductDim dp
    ON COALESCE(c.pid, g.pid) = dp.pid
ORDER BY 1 DESC, 8 DESC;
