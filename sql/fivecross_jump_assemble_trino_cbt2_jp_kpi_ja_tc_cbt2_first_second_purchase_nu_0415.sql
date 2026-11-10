/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 4/15 新用户 3天内充值行为链路分析
Cohort  : 2026-04-15 注册的 iOS 新用户（fixed_regdate 标签，排除黑名单）
Window  : 2026-04-15 ~ 2026-04-17（注册日起 3 天）

需求1   : 首充是什么商品 → 各商品的首充人数
需求2   : 首充为 gift11 的用户 → 二充了什么（横向展示：首充 | 二充）
需求3   : 二充为 gift10 的用户 → 三充了什么（横向展示：首充 | 二充 | 三充）

输出格式：每行包含 首充/二充/三充 的商品ID、名称、子分类，横向对齐
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
-- 2. 4/15 注册的 iOS 新用户队列
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND t1.tag_value    = '2026-04-15'
      AND ub.lcx_id IS NULL
      AND EXISTS (
          SELECT 1
          FROM user_result_cluster_16 t2
          WHERE t2."#varchar_id" = t1."#varchar_id"
            AND t2.cluster_name  = 'fixed_os'
            AND t2.tag_value     = 'iOS'
      )
),

--------------------------------------------------------------------------------
-- 3. 3天内的购买事件，按时间排序打序号
--------------------------------------------------------------------------------
PurchaseRanked AS (
    SELECT
        v."#account_id"                 AS lcx_id,
        v."#event_time",
        v.payload.productid             AS productid,
        ROW_NUMBER() OVER (
            PARTITION BY v."#account_id"
            ORDER BY v."#event_time" ASC
        )                               AS purchase_rank
    FROM ta.v_event_16 v
    INNER JOIN NewUsers nu ON v."#account_id" = nu.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-17'
      AND v."$part_event" = 'PURCHASE'
      AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
),

--------------------------------------------------------------------------------
-- 4. 拆出第1、2、3笔
--------------------------------------------------------------------------------
FirstPurchase AS (
    SELECT lcx_id, productid AS first_product
    FROM PurchaseRanked WHERE purchase_rank = 1
),
SecondPurchase AS (
    SELECT lcx_id, productid AS second_product
    FROM PurchaseRanked WHERE purchase_rank = 2
),
ThirdPurchase AS (
    SELECT lcx_id, productid AS third_product
    FROM PurchaseRanked WHERE purchase_rank = 3
),

--------------------------------------------------------------------------------
-- 5. 商品维表（含 sub_category）
--    product_category = '躍之星'          → 躍之星
--    product_name 含 閱覽/刊物            → 抽卷
--    product_name 含 成長/覺醒/天賦        → 養成
--    其他                                 → 其他
--------------------------------------------------------------------------------
ProductDim AS (
    SELECT
        CAST("payload.productid@product_id"  AS VARCHAR) AS productid,
        "payload.productid@product_name"                 AS product_name,
        "payload.productid@product_category"             AS product_category,
        CASE
            WHEN "payload.productid@product_category" = '躍之星'    THEN '躍之星'
            WHEN "payload.productid@product_name" LIKE '%閱覽%'
              OR "payload.productid@product_name" LIKE '%刊物%'      THEN '抽卷'
            WHEN "payload.productid@product_name" LIKE '%成長%'
              OR "payload.productid@product_name" LIKE '%覺醒%'
              OR "payload.productid@product_name" LIKE '%天賦%'      THEN '養成'
            ELSE '其他'
        END                                              AS sub_category
    FROM ta_dim.dim_16_0_23989
)

-- ============================================================
-- 需求1：首充商品分布
-- ============================================================
SELECT
    '需求1: 首充商品分布'                                   AS "分析维度",
    CAST(f.first_product AS VARCHAR)                        AS "首充商品ID",
    COALESCE(pd1.product_name,     '未知商品')              AS "首充商品名称",
    COALESCE(pd1.product_category, '未知分类')              AS "首充商品类别",
    COALESCE(pd1.sub_category,     '其他')                  AS "首充商品子分类",
    COUNT(DISTINCT f.lcx_id)                                AS "首充人数",
    NULL                                                    AS "二充商品ID",
    NULL                                                    AS "二充商品名称",
    NULL                                                    AS "二充商品子分类",
    NULL                                                    AS "二充人数",
    NULL                                                    AS "三充商品ID",
    NULL                                                    AS "三充商品名称",
    NULL                                                    AS "三充商品子分类",
    NULL                                                    AS "三充人数"
FROM FirstPurchase f
LEFT JOIN ProductDim pd1 ON CAST(f.first_product AS VARCHAR) = pd1.productid
GROUP BY 1, 2, 3, 4, 5

UNION ALL

-- ============================================================
-- 需求2：首充 gift11 → 二充了什么（首充 | 二充 横向）
-- ============================================================
SELECT
    '需求2: 首充gift11后的二充行为'                          AS "分析维度",
    NULL                                                    AS "首充商品ID",
    NULL                                                    AS "首充商品名称",
    NULL                                                    AS "首充商品类别",
    NULL                                                    AS "首充商品子分类",
    NULL                                                    AS "首充人数",
    COALESCE(CAST(s.second_product AS VARCHAR), '（无二充）') AS "二充商品ID",
    COALESCE(pd2.product_name,
        CASE WHEN s.lcx_id IS NULL THEN '（无二充）' ELSE '未知商品' END)
                                                            AS "二充商品名称",
    COALESCE(pd2.sub_category,
        CASE WHEN s.lcx_id IS NULL THEN '—' ELSE '其他' END)
                                                            AS "二充商品子分类",
    COUNT(DISTINCT f.lcx_id)                                AS "二充人数",
    NULL                                                    AS "三充商品ID",
    NULL                                                    AS "三充商品名称",
    NULL                                                    AS "三充商品子分类",
    NULL                                                    AS "三充人数"
FROM FirstPurchase f
LEFT JOIN SecondPurchase s  ON f.lcx_id = s.lcx_id
LEFT JOIN ProductDim pd2    ON CAST(s.second_product AS VARCHAR) = pd2.productid
WHERE CAST(f.first_product AS VARCHAR) = 'com.dgames.g65002007.apple.CBT.nt33.gift11'
GROUP BY 1, 2, 3, 4, 5, 7, 8, 9

UNION ALL

-- ============================================================
-- 需求3：首充 gift11 且 二充 gift10 → 三充了什么
-- ============================================================
SELECT
    '需求3: 首充gift11且二充gift10后的三充行为'              AS "分析维度",
    NULL                                                    AS "首充商品ID",
    NULL                                                    AS "首充商品名称",
    NULL                                                    AS "首充商品类别",
    NULL                                                    AS "首充商品子分类",
    NULL                                                    AS "首充人数",
    NULL                                                    AS "二充商品ID",
    NULL                                                    AS "二充商品名称",
    NULL                                                    AS "二充商品子分类",
    NULL                                                    AS "二充人数",
    COALESCE(CAST(t.third_product AS VARCHAR), '（无三充）') AS "三充商品ID",
    COALESCE(pd3.product_name,
        CASE WHEN t.lcx_id IS NULL THEN '（无三充）' ELSE '未知商品' END)
                                                            AS "三充商品名称",
    COALESCE(pd3.sub_category,
        CASE WHEN t.lcx_id IS NULL THEN '—' ELSE '其他' END)
                                                            AS "三充商品子分类",
    COUNT(DISTINCT f.lcx_id)                                AS "三充人数"
FROM FirstPurchase f
INNER JOIN SecondPurchase s ON f.lcx_id = s.lcx_id
LEFT JOIN  ThirdPurchase  t ON f.lcx_id = t.lcx_id
LEFT JOIN  ProductDim pd3   ON CAST(t.third_product AS VARCHAR) = pd3.productid
WHERE CAST(f.first_product  AS VARCHAR) = 'com.dgames.g65002007.apple.CBT.nt33.gift11'
  AND CAST(s.second_product AS VARCHAR) = 'com.dgames.g65002007.apple.CBT.nt100.gift10'
GROUP BY 1, 11, 12, 13

ORDER BY
    "分析维度" ASC,
    "首充人数" DESC;
