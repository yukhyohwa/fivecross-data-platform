/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 商城兑换统计
描述：按商品统计商城兑换量、兑换账号数和晶钻消耗。

口径：
1. 兑换人数按 fc_id 去重，同账号多角色合并。
2. shop_buy 直接使用 ${PartDate:date1} 筛选，不关联注册事件，不额外限定开服日期。
3. 黑名单使用 #varchar_id，排除 is_water_new、is_windows_new、internal_users_new。
4. 商品维表使用 App 18 的 ta_dim.dim_18_0_52801。
5. 原 SQL 的 ItemChange CTE 未参与输出计算，OBT 版本删除该无效关联，避免重复行。
6. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/

WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new', 'internal_users_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

ShopData AS (
    SELECT
        v."$part_date",
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        v.shop_item,
        v.a_rst
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'shop_buy'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
)

SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
    END AS "时间维度",
    CASE
        WHEN v.shop_item[1].shop_id > 10000 THEN '晶钻商城'
        ELSE '红钻商城'
    END AS "商店ID",
    COALESCE(
        CAST(CAST(dp."product_id@product_id" AS INTEGER) AS VARCHAR),
        ARRAY_JOIN(TRANSFORM(v.a_rst, x -> CAST(CAST(x.id AS INTEGER) AS VARCHAR)), '+')
    ) AS "道具ID",
    COALESCE(
        dp."product_id@product_name_tc",
        ARRAY_JOIN(TRANSFORM(v.a_rst, x -> CAST(x.name AS VARCHAR)), '+')
    ) AS "道具名称",
    ARRAY_JOIN(TRANSFORM(v.a_rst, x -> CAST(x.name AS VARCHAR)), '+') AS "道具内容",
    SUM(
        CASE
            WHEN v.shop_item[1].shop_id > 10000 THEN 1
            ELSE TRY_CAST(v.a_rst[1].diff AS BIGINT)
        END
    ) AS "兑换总量",
    COUNT(DISTINCT v.fc_id) AS "兑换人数",
    SUM(
        CASE WHEN v.shop_item[1].item_id = 10206 THEN v.shop_item[1].num END
    ) / 100.0 AS "消耗晶钻数"
FROM ShopData v
LEFT JOIN ta_dim.dim_18_0_52801 dp
    ON CAST(v.shop_item[1].shop_id AS INTEGER)
       = CAST(dp."product_id@product_id" AS INTEGER)
GROUP BY 1, 2, 3, 4, 5
HAVING SUM(
    CASE WHEN v.shop_item[1].item_id = 10206 THEN v.shop_item[1].num END
) / 100.0 > 0
ORDER BY "商店ID", "兑换总量" DESC;
