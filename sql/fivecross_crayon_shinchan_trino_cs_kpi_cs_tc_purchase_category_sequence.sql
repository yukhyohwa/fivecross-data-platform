/*
================================================================================
Game    : Crayon Shinchan (蜡笔小新) - TC Region (Project 13)
Report  : 用户充值行为链路分析（精确到商品类别）
描述    : 统计用户历史上第一笔、第二笔、第三笔订单购买的商品类别链路。
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

--------------------------------------------------------------------------------
-- 2. 目标时间内的购买事件，按时间排序打序号
--------------------------------------------------------------------------------
PurchaseRanked AS (
    SELECT
        v."#user_id",
        v."#event_time",
        v.product_id,
        ROW_NUMBER() OVER (
            PARTITION BY v."#user_id"
            ORDER BY v."#event_time" ASC
        ) AS purchase_rank
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND ub."#user_id" IS NULL
),

--------------------------------------------------------------------------------
-- 3. 拆出第1、2、3笔
--------------------------------------------------------------------------------
FirstPurchase AS (
    SELECT "#user_id", product_id AS first_product
    FROM PurchaseRanked WHERE purchase_rank = 1
),
SecondPurchase AS (
    SELECT "#user_id", product_id AS second_product
    FROM PurchaseRanked WHERE purchase_rank = 2
),
ThirdPurchase AS (
    SELECT "#user_id", product_id AS third_product
    FROM PurchaseRanked WHERE purchase_rank = 3
),

--------------------------------------------------------------------------------
-- 4. 商品维表 (精确到类别)
--------------------------------------------------------------------------------
ProductDim AS (
    SELECT
        CAST("product_id@product_id" AS VARCHAR) AS product_id,
        "product_id@product_type"                AS product_category
    FROM ta_dim.dim_18_0_52801
)

-- ============================================================
-- 需求1：首充类别分布
-- ============================================================
SELECT
    '需求1: 首充类别分布'                                    AS "分析维度",
    COALESCE(pd1.product_category, '未知分类')              AS "首充商品类别",
    NULL                                                    AS "二充商品类别",
    NULL                                                    AS "三充商品类别",
    COUNT(DISTINCT f."#user_id")                            AS "人数"
FROM FirstPurchase f
LEFT JOIN ProductDim pd1 ON CAST(f.first_product AS VARCHAR) = pd1.product_id
GROUP BY 1, 2, 3, 4

UNION ALL

-- ============================================================
-- 需求2：首充类别 -> 二充类别
-- ============================================================
SELECT
    '需求2: 首充->二充类别链路'                              AS "分析维度",
    COALESCE(pd1.product_category, '未知分类')              AS "首充商品类别",
    COALESCE(pd2.product_category,
        CASE WHEN s."#user_id" IS NULL THEN '（无二充）' ELSE '未知分类' END)
                                                            AS "二充商品类别",
    NULL                                                    AS "三充商品类别",
    COUNT(DISTINCT f."#user_id")                            AS "人数"
FROM FirstPurchase f
LEFT JOIN SecondPurchase s  ON f."#user_id" = s."#user_id"
LEFT JOIN ProductDim pd1    ON CAST(f.first_product AS VARCHAR) = pd1.product_id
LEFT JOIN ProductDim pd2    ON CAST(s.second_product AS VARCHAR) = pd2.product_id
GROUP BY 1, 2, 3, 4

UNION ALL

-- ============================================================
-- 需求3：首充类别 -> 二充类别 -> 三充类别
-- ============================================================
SELECT
    '需求3: 首充->二充->三充类别链路'                        AS "分析维度",
    COALESCE(pd1.product_category, '未知分类')              AS "首充商品类别",
    COALESCE(pd2.product_category,
        CASE WHEN s."#user_id" IS NULL THEN '（无二充）' ELSE '未知分类' END)
                                                            AS "二充商品类别",
    COALESCE(pd3.product_category,
        CASE WHEN t."#user_id" IS NULL THEN '（无三充）' ELSE '未知分类' END)
                                                            AS "三充商品类别",
    COUNT(DISTINCT f."#user_id")                            AS "人数"
FROM FirstPurchase f
LEFT JOIN SecondPurchase s  ON f."#user_id" = s."#user_id"
LEFT JOIN ThirdPurchase  t  ON f."#user_id" = t."#user_id"
LEFT JOIN ProductDim pd1    ON CAST(f.first_product AS VARCHAR) = pd1.product_id
LEFT JOIN ProductDim pd2    ON CAST(s.second_product AS VARCHAR) = pd2.product_id
LEFT JOIN ProductDim pd3    ON CAST(t.third_product AS VARCHAR) = pd3.product_id
GROUP BY 1, 2, 3, 4

ORDER BY
    "分析维度" ASC,
    "人数" DESC;
