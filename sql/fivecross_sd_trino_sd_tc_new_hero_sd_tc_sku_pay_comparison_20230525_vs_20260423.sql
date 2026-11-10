-- ================================================================================
-- Report  : Slam Dunk TC — SKU Payment Comparison
-- Game    : Slam Dunk TC (g23002013)
-- Dates   : 2023-05-25  vs  2026-04-23
-- Metrics : SKU, revenue(CNY), payer count, order count, ARPPU
-- Engine  : Holo (PostgreSQL)
-- Notes   :
--   - item_id extracted from memo1 field (purchasePayload)
--   - zone filter: left(zoneId, 1) IN ('1','2','3')
--   - exchange rate from dm_dimension.dim_itunes_exchange_rate_fmp
-- ================================================================================

WITH

ExRate AS (
    SELECT
        month,
        trans_from,
        exchange_rate
    FROM (
        SELECT
            LEFT(day_hour, 6)       AS month,
            trans_from,
            exchange_rate,
            ROW_NUMBER() OVER (
                PARTITION BY LEFT(day_hour, 6), trans_from
                ORDER BY day_hour ASC
            )                       AS rn
        FROM dm_dimension.dim_itunes_exchange_rate_fmp
        WHERE trans_to = 'cny'
    ) t
    WHERE rn = 1
),

-- SKU 明细（两个日期，用户级别）
SkuDetail AS (
    SELECT
        a.day,
        a.lcm_id,
        SPLIT_PART(SPLIT_PART(a.memo1, 'purchasePayload', 2), ',', 2)  AS item_id,
        a.sku,
        a.sku_name,
        SUM(b.exchange_rate * a.price_show)                             AS sales_cny
    FROM g23002013.lcx_user_purchase a
    LEFT JOIN ExRate b
        ON LEFT(CAST(a.day AS TEXT), 6) = b.month
       AND a.unit_show = b.trans_from
    WHERE a.day IN (20230525, 20260423)
      AND a.price_show > 0
      AND LEFT(SPLIT_PART(SPLIT_PART(a.memo1, '"zoneId":"', 2), '"', 1), 1)
          IN ('1', '2', '3')
    GROUP BY a.day, a.lcm_id, a.sku, a.sku_name,
             SPLIT_PART(SPLIT_PART(a.memo1, 'purchasePayload', 2), ',', 2)
),

-- 按日期 + SKU 聚合
SkuAgg AS (
    SELECT
        day,
        item_id,
        sku,
        sku_name,
        COUNT(*)                                                                AS order_cnt,
        COUNT(DISTINCT lcm_id)                                                  AS payer_cnt,
        ROUND(CAST(SUM(sales_cny) AS NUMERIC), 2)                               AS revenue_cny,
        ROUND(CAST(SUM(sales_cny) / NULLIF(COUNT(DISTINCT lcm_id), 0) AS NUMERIC), 2)
                                                                                AS arppu
    FROM SkuDetail
    GROUP BY day, item_id, sku, sku_name
),

-- Top 10 排名（按收入）
SkuRanked AS (
    SELECT
        day, item_id, sku, sku_name, order_cnt, payer_cnt, revenue_cny, arppu,
        ROW_NUMBER() OVER (PARTITION BY day ORDER BY revenue_cny DESC)          AS rev_rank
    FROM SkuAgg
),

-- ── Part 1: All SKUs 两日期并排 ───────────────────────────────────────────────
Part1 AS (
    SELECT
        'Part1_AllSKU'                                                          AS part,
        COALESCE(a.item_id,  b.item_id)                                         AS item_id,
        COALESCE(a.sku,      b.sku)                                             AS sku,
        COALESCE(a.sku_name, b.sku_name)                                        AS sku_name,
        a.revenue_cny                                                           AS rev_2023,
        a.order_cnt                                                             AS ord_2023,
        a.payer_cnt                                                             AS pay_2023,
        a.arppu                                                                 AS arppu_2023,
        b.revenue_cny                                                           AS rev_2026,
        b.order_cnt                                                             AS ord_2026,
        b.payer_cnt                                                             AS pay_2026,
        b.arppu                                                                 AS arppu_2026,
        COALESCE(b.revenue_cny, 0) + COALESCE(a.revenue_cny, 0)                AS sort_key
    FROM
        (SELECT * FROM SkuAgg WHERE day = 20230525) a
    FULL OUTER JOIN
        (SELECT * FROM SkuAgg WHERE day = 20260423) b
        ON a.sku = b.sku
),

-- ── Part 2: Top 10 SKUs 两日期并排 ───────────────────────────────────────────
Part2 AS (
    SELECT
        'Part2_Top10SKU'                                                        AS part,
        COALESCE(a.item_id,  b.item_id)                                         AS item_id,
        COALESCE(a.sku,      b.sku)                                             AS sku,
        COALESCE(a.sku_name, b.sku_name)                                        AS sku_name,
        a.revenue_cny                                                           AS rev_2023,
        a.order_cnt                                                             AS ord_2023,
        a.payer_cnt                                                             AS pay_2023,
        a.arppu                                                                 AS arppu_2023,
        b.revenue_cny                                                           AS rev_2026,
        b.order_cnt                                                             AS ord_2026,
        b.payer_cnt                                                             AS pay_2026,
        b.arppu                                                                 AS arppu_2026,
        COALESCE(b.revenue_cny, 0) + COALESCE(a.revenue_cny, 0)                AS sort_key
    FROM
        (SELECT * FROM SkuRanked WHERE day = 20230525 AND rev_rank <= 10) a
    FULL OUTER JOIN
        (SELECT * FROM SkuRanked WHERE day = 20260423 AND rev_rank <= 10) b
        ON a.sku = b.sku
)

SELECT
    part                AS "part",
    item_id             AS "item_id",
    sku                 AS "SKU",
    sku_name            AS "SKU名称",
    rev_2023            AS "付费金额CNY(2023-05-25)",
    ord_2023            AS "付费次数(2023-05-25)",
    pay_2023            AS "付费人数(2023-05-25)",
    arppu_2023          AS "ARPPU(2023-05-25)",
    rev_2026            AS "付费金额CNY(2026-04-23)",
    ord_2026            AS "付费次数(2026-04-23)",
    pay_2026            AS "付费人数(2026-04-23)",
    arppu_2026          AS "ARPPU(2026-04-23)",
    sort_key
FROM Part1

UNION ALL

SELECT
    part, item_id, sku, sku_name,
    rev_2023, ord_2023, pay_2023, arppu_2023,
    rev_2026, ord_2026, pay_2026, arppu_2026,
    sort_key
FROM Part2

ORDER BY part ASC, sort_key DESC;
