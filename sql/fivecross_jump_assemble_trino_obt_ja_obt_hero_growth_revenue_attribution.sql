/*
================================================================================
Game    : Jump Assemble - OBT
Report  : 英雄养成收入归因（按跃之星等价成本分摊）
Purpose :
  先把各品质、各英雄的胚子 / 觉醒 / 天赋币养成换算成跃之星等价成本，
  再在每个付费档位内按英雄养成星耗占比分配该档位的跃之星收入池。

Date rule:
  ${PartDate:date1} 选择的是 daily_role_card_snapshot 的快照日期。
  因为 daily_role_card_snapshot 是次日凌晨更新，所以业务统计截止日 = 快照日期 - 1。
  例如选择快照日 2026-07-08，则收入、付费档位和养成都按截至 2026-07-07 计算。

Key assumptions:
  1. 收入池 = PURCHASE 有效收入 * 商品跃之星收入占比。
     ProductStarRatio 里配置每个付费商品的跃之星收入占比。
     当前未配置商品默认按 1.0 计入，便于先跑估算；严格口径可改为 0.0。
  2. 一个已持有英雄 = 1 个胚子。
  3. 每次觉醒额外消耗 1 个同品质胚子，最多 3 次。
  4. 天赋币按当前已开天赋槽数量 * 130 跃之星计算，最多 32 个。
  5. 付费档位按 OBT 起始日至业务统计截止日的累计充值 USD 计算。
================================================================================
*/

WITH
SnapshotParam AS (
    SELECT MAX(CAST(v."$part_date" AS DATE)) AS snapshot_date
    FROM ta.v_event_23 v
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'daily_role_card_snapshot'
),

Params AS (
    SELECT
        DATE '2026-06-24' AS start_date,
        COALESCE(snapshot_date, CURRENT_DATE) AS snapshot_date,
        DATE_ADD('day', -1, COALESCE(snapshot_date, CURRENT_DATE)) AS as_of_date
    FROM SnapshotParam
),

UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

/*
在这里补各付费商品的跃之星收入占比。

例：
  纯跃之星商品：
    ('product_a', 1.0000)
  礼包中跃之星付费价值占 60%，其它内容占 40%：
    ('product_b', 0.6000)

如果礼包里的意志结晶是免费赠送价值，不要把它放入分母；这样可以规避
“免费赠送意志结晶与跃之星等价”对收入分配的影响。
*/
ProductStarRatio AS (
    SELECT product_id, star_revenue_ratio
    FROM (
        VALUES
            ('__fill_me__', CAST(1.0000 AS DOUBLE))
    ) AS t(product_id, star_revenue_ratio)
    WHERE product_id <> '__fill_me__'
),

PurchaseDetail AS (
    SELECT
        v."#account_id" AS lcx_id,
        CAST(v."$part_date" AS DATE) AS pay_date,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid') AS product_id,
        COALESCE(
            s4."payload.productid@product_name",
            JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'),
            'unknown'
        ) AS product_name,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)
            / COALESCE(ex.exchange, 1.0) AS revenue_usd,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)
            / COALESCE(ex.exchange, 1.0)
            * COALESCE(psr.star_revenue_ratio, 1.0) AS jump_star_revenue_usd,
        CASE WHEN psr.product_id IS NULL THEN 1 ELSE 0 END AS is_unmapped_product
    FROM ta.v_event_23 v
    CROSS JOIN Params p
    LEFT JOIN UserBlacklist ub
        ON v."#account_id" = ub.lcx_id
    LEFT JOIN ta_dim.ta_exchange ex
        ON v."$part_date" = ex.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    LEFT JOIN ta_dim.dim_23_0_51243 s4
        ON JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid')
         = s4."payload.productid@product_id"
    LEFT JOIN ProductStarRatio psr
        ON JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid') = psr.product_id
    WHERE v."$part_event" = 'PURCHASE'
      AND CAST(v."$part_date" AS DATE) BETWEEN p.start_date AND p.as_of_date
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND ub.lcx_id IS NULL
),

UserRevenue AS (
    SELECT
        lcx_id,
        SUM(revenue_usd) AS total_revenue_usd
    FROM PurchaseDetail
    GROUP BY 1
),

LatestCardSnapshot AS (
    SELECT *
    FROM (
        SELECT
            COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
            TRY_CAST(v.card_id AS INTEGER) AS card_id,
            v.card_name,
            CASE
                WHEN TRY_CAST(v.card_id AS INTEGER) IN (126, 145) THEN 'S'
                WHEN TRY_CAST(v.card_id AS INTEGER) IN (135, 125, 158, 122, 110, 134, 113, 127, 157, 159, 132) THEN 'A'
                ELSE 'R/B'
            END AS card_quality,
            LEAST(COALESCE(cardinality(v.card_awake), 0), 3) AS awaken_count,
            LEAST(
                COALESCE(cardinality(filter(v.card_talent_slot, x -> x <> '0' AND x <> '')), 0),
                32
            ) AS talent_count,
            ROW_NUMBER() OVER (
                PARTITION BY
                    COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id"),
                    TRY_CAST(v.card_id AS INTEGER)
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 v
        CROSS JOIN Params p
        LEFT JOIN UserBlacklist ub
            ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
        WHERE v."$part_event" = 'daily_role_card_snapshot'
          AND CAST(v."$part_date" AS DATE) = p.snapshot_date
          AND ub.lcx_id IS NULL
          AND TRY_CAST(v.card_id AS INTEGER) IS NOT NULL
    )
    WHERE rn = 1
),

BaseUsers AS (
    SELECT lcx_id FROM UserRevenue
    UNION
    SELECT lcx_id FROM LatestCardSnapshot
),

UserTier AS (
    SELECT
        bu.lcx_id,
        COALESCE(ur.total_revenue_usd, 0.0) AS total_revenue_usd,
        CASE
            WHEN COALESCE(ur.total_revenue_usd, 0.0) = 0 THEN '0.免费用户'
            WHEN ur.total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN ur.total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN ur.total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN ur.total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,+)'
        END AS pay_tier
    FROM BaseUsers bu
    LEFT JOIN UserRevenue ur
        ON bu.lcx_id = ur.lcx_id
),

RevenuePoolByTier AS (
    SELECT
        ut.pay_tier,
        ROUND(SUM(pd.revenue_usd), 2) AS total_revenue_usd,
        ROUND(SUM(pd.jump_star_revenue_usd), 2) AS jump_star_revenue_pool_usd,
        ROUND(SUM(CASE WHEN pd.is_unmapped_product = 1 THEN pd.revenue_usd ELSE 0.0 END), 2) AS unmapped_revenue_usd,
        COUNT(DISTINCT pd.product_id) AS paid_product_cnt,
        COUNT(DISTINCT CASE WHEN pd.is_unmapped_product = 1 THEN pd.product_id END) AS unmapped_product_cnt
    FROM PurchaseDetail pd
    INNER JOIN UserTier ut
        ON pd.lcx_id = ut.lcx_id
    GROUP BY 1
),

HeroGrowthBase AS (
    SELECT
        lcs.lcx_id,
        ut.pay_tier,
        lcs.card_id,
        COALESCE(lcs.card_name, CAST(lcs.card_id AS VARCHAR)) AS card_name,
        lcs.card_quality,
        CASE
            WHEN lcs.card_quality = 'S' THEN 'S级角色'
            WHEN lcs.card_quality = 'A' THEN 'A级角色'
            ELSE 'R/B级角色'
        END AS quality_group,
        CASE
            WHEN lcs.card_quality = 'S' THEN 6000
            WHEN lcs.card_quality = 'A' THEN 4000
            ELSE 2000
        END AS embryo_star_price,
        lcs.awaken_count,
        lcs.talent_count
    FROM LatestCardSnapshot lcs
    INNER JOIN UserTier ut
        ON lcs.lcx_id = ut.lcx_id
),

GrowthCostRows AS (
    SELECT
        pay_tier,
        quality_group,
        card_quality,
        card_id,
        card_name,
        '1.胚子' AS component,
        lcx_id,
        1 AS unit_count,
        embryo_star_price AS jump_star_cost
    FROM HeroGrowthBase

    UNION ALL

    SELECT
        pay_tier,
        quality_group,
        card_quality,
        card_id,
        card_name,
        '2.觉醒' AS component,
        lcx_id,
        awaken_count AS unit_count,
        awaken_count * embryo_star_price AS jump_star_cost
    FROM HeroGrowthBase
    WHERE awaken_count > 0

    UNION ALL

    SELECT
        pay_tier,
        quality_group,
        card_quality,
        card_id,
        card_name,
        '3.天赋币' AS component,
        lcx_id,
        talent_count AS unit_count,
        talent_count * 130 AS jump_star_cost
    FROM HeroGrowthBase
    WHERE talent_count > 0
),

GrowthCostRowsGrouped AS (
    SELECT
        pay_tier,
        quality_group,
        card_id,
        card_name,
        component,
        lcx_id,
        unit_count,
        jump_star_cost
    FROM GrowthCostRows
),

CostAgg AS (
    SELECT
        pay_tier,
        quality_group,
        card_id,
        card_name,
        component,
        COUNT(DISTINCT CONCAT(COALESCE(lcx_id, 'unknown'), '#', CAST(card_id AS VARCHAR))) AS user_card_cnt,
        SUM(unit_count) AS unit_count,
        SUM(jump_star_cost) AS jump_star_cost
    FROM GrowthCostRowsGrouped
    GROUP BY 1, 2, 3, 4, 5
),

CostAggWithSubtotal AS (
    SELECT
        pay_tier,
        quality_group,
        card_id,
        card_name,
        component,
        user_card_cnt,
        unit_count,
        jump_star_cost
    FROM CostAgg

    UNION ALL

    SELECT
        pay_tier,
        quality_group,
        card_id,
        card_name,
        '4.胚子+觉醒小计' AS component,
        COUNT(DISTINCT CONCAT(COALESCE(lcx_id, 'unknown'), '#', CAST(card_id AS VARCHAR))) AS user_card_cnt,
        SUM(unit_count) AS unit_count,
        SUM(jump_star_cost) AS jump_star_cost
    FROM GrowthCostRowsGrouped
    WHERE component IN ('1.胚子', '2.觉醒')
    GROUP BY 1, 2, 3, 4

    UNION ALL

    SELECT
        pay_tier,
        quality_group,
        card_id,
        card_name,
        '5.全部养成合计' AS component,
        COUNT(DISTINCT CONCAT(COALESCE(lcx_id, 'unknown'), '#', CAST(card_id AS VARCHAR))) AS user_card_cnt,
        SUM(unit_count) AS unit_count,
        SUM(jump_star_cost) AS jump_star_cost
    FROM GrowthCostRowsGrouped
    GROUP BY 1, 2, 3, 4
),

CostTotalByTier AS (
    SELECT
        pay_tier,
        SUM(jump_star_cost) AS tier_growth_jump_star_cost
    FROM GrowthCostRows
    GROUP BY 1
),

AttributionByTier AS (
    SELECT
        p.start_date,
        p.as_of_date,
        p.snapshot_date,
        c.pay_tier,
        c.quality_group,
        c.card_id,
        c.card_name,
        c.component,
        c.user_card_cnt,
        c.unit_count,
        c.jump_star_cost,
        t.tier_growth_jump_star_cost,
        COALESCE(rp.total_revenue_usd, 0.0) AS total_revenue_usd,
        COALESCE(rp.jump_star_revenue_pool_usd, 0.0) AS jump_star_revenue_pool_usd,
        ROUND(c.jump_star_cost * 1.0000 / NULLIF(t.tier_growth_jump_star_cost, 0), 4) AS tier_growth_star_ratio,
        ROUND(
            COALESCE(rp.jump_star_revenue_pool_usd, 0.0)
                * c.jump_star_cost / NULLIF(t.tier_growth_jump_star_cost, 0),
            2
        ) AS attributed_revenue_usd,
        COALESCE(rp.unmapped_revenue_usd, 0.0) AS unmapped_revenue_usd,
        COALESCE(rp.unmapped_product_cnt, 0) AS unmapped_product_cnt,
        COALESCE(rp.paid_product_cnt, 0) AS paid_product_cnt
    FROM CostAggWithSubtotal c
    INNER JOIN CostTotalByTier t
        ON c.pay_tier = t.pay_tier
    LEFT JOIN RevenuePoolByTier rp
        ON c.pay_tier = rp.pay_tier
    CROSS JOIN Params p
)

SELECT
    CAST(start_date AS VARCHAR) || ' ~ ' || CAST(as_of_date AS VARCHAR) AS "业务统计区间",
    CAST(snapshot_date AS VARCHAR) AS "使用快照日期",
    pay_tier AS "付费档位",
    quality_group AS "角色组",
    card_id AS "英雄ID",
    card_name AS "英雄名",
    component AS "养成项",
    user_card_cnt AS "用户-英雄数",
    unit_count AS "消耗单位数",
    jump_star_cost AS "跃之星等价成本",
    tier_growth_jump_star_cost AS "该付费档总养成星耗",
    tier_growth_star_ratio AS "该付费档养成星耗占比",
    total_revenue_usd AS "该付费档总收入USD",
    jump_star_revenue_pool_usd AS "该付费档跃之星收入池USD",
    attributed_revenue_usd AS "估算分摊收入USD",
    ROUND(attributed_revenue_usd / NULLIF(total_revenue_usd, 0), 4) AS "占该档总收入",
    unmapped_revenue_usd AS "未配置商品收入USD",
    unmapped_product_cnt AS "未配置商品数",
    paid_product_cnt AS "付费商品数"
FROM AttributionByTier
ORDER BY
    CASE
        WHEN pay_tier = '0.免费用户' THEN 0
        WHEN pay_tier = 'a.(0,10]' THEN 1
        WHEN pay_tier = 'b.(10,50]' THEN 2
        WHEN pay_tier = 'c.(50,100]' THEN 3
        WHEN pay_tier = 'd.(100,300]' THEN 4
        WHEN pay_tier = 'e.(300,+)' THEN 5
        ELSE 9
    END,
    CASE
        WHEN quality_group = 'R/B级角色' THEN 1
        WHEN quality_group = 'A级角色' THEN 2
        WHEN quality_group = 'S级角色' THEN 3
        ELSE 5
    END,
    attributed_revenue_usd DESC,
    card_id,
    component;
