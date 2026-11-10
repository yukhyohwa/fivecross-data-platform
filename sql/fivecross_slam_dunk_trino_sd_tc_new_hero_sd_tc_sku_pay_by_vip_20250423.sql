-- ================================================================================
-- Report  : Slam Dunk TC — SKU Payment by VIP Segment (Final Optimized)
-- Game    : Slam Dunk TC (23002013)
-- Date    : 2026-04-23
-- Metrics : VIP Level, SKU, Revenue(CNY), Payer Count, Order Count, ARPPU
-- Engine  : MaxCompute (ODPS)
-- ================================================================================

WITH

ExRate AS (
    SELECT
        month,
        trans_from,
        exchange_rate
    FROM (
        SELECT
            SUBSTR(day_hour, 1, 6)  AS month,
            LOWER(trans_from)       AS trans_from,
            exchange_rate,
            ROW_NUMBER() OVER (
                PARTITION BY SUBSTR(day_hour, 1, 6), LOWER(trans_from)
                ORDER BY day_hour ASC
            )                       AS rn
        FROM dm_platform.itunes_exchange_rate_fmp
        WHERE trans_to = 'cny'
          AND day >= 20250401
    ) t
    WHERE rn = 1
),

-- 用户 VIP 等级（基于指定日期的累计付费，取用户最高的一条记录防止重复）
UserVip AS (
    SELECT 
        mbga_uid,
        CASE
            WHEN total_pay_max = 0 THEN 'V0'
            WHEN total_pay_max BETWEEN 1 AND 6 THEN 'V1'
            WHEN total_pay_max BETWEEN 7 AND 30 THEN 'V2'
            WHEN total_pay_max BETWEEN 31 AND 100 THEN 'V3'
            WHEN total_pay_max BETWEEN 101 AND 500 THEN 'V4'
            WHEN total_pay_max BETWEEN 501 AND 1000 THEN 'V5'
            WHEN total_pay_max BETWEEN 1001 AND 3000 THEN 'V6' 
            WHEN total_pay_max BETWEEN 3001 AND 10000 THEN 'V7' 
            WHEN total_pay_max BETWEEN 10001 AND 30000 THEN 'V8' 
            WHEN total_pay_max >= 30001 THEN 'V9' 
            ELSE 'V0'
        END AS vip_level
    FROM (
        SELECT mbga_uid, MAX(CAST(total_pay AS DOUBLE)) as total_pay_max
        FROM g23002013.daily_user_snapshot
        WHERE day = 20260423
        GROUP BY mbga_uid
    ) u_raw
),

-- 排除福利号/内部号 (is_water)
ActiveUserFilter AS (
    SELECT DISTINCT lcm_id
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = '23002013'
      AND day = 20260423
      AND is_water = '不是水'
),

-- SKU 购买明细
SkuDetail AS (
    SELECT
        a.lcm_id,
        COALESCE(v.vip_level, 'V0')                                     AS vip_level,
        COALESCE(
            SPLIT(GET_JSON_OBJECT(a.memo1, '$.purchasePayload'), ',')[1],
            a.sku
        )                                                               AS item_id,
        a.sku,
        a.sku_name,
        (COALESCE(b.exchange_rate, 0) * a.price_show)                   AS sales_cny
    FROM dm_platform.daily_lcx_user_purchase a
    INNER JOIN ActiveUserFilter f ON a.lcm_id = f.lcm_id                -- 过滤内部号/福利号
    LEFT JOIN ExRate b
        ON SUBSTR(CAST(a.day AS STRING), 1, 6) = b.month
       AND LOWER(a.unit_show) = b.trans_from
    LEFT JOIN UserVip v
        ON a.lcm_id = v.mbga_uid
    WHERE a.day = 20260423
      AND a.app_id = '23002013'
      AND a.price_show > 0
      AND SUBSTR(GET_JSON_OBJECT(a.memo1, '$.zoneId'), 1, 1) IN ('1', '2', '3')
)

-- 按 VIP + SKU 聚合
SELECT
    vip_level                                                               AS `VIP等级`,
    item_id                                                                 AS `item_id`,
    sku                                                                     AS `SKU`,
    sku_name                                                                AS `SKU名称`,
    COUNT(*)                                                                AS `付费次数`,
    COUNT(DISTINCT lcm_id)                                                  AS `付费人数`,
    ROUND(SUM(sales_cny), 2)                                                AS `付费金额CNY`,
    ROUND(SUM(sales_cny) / NULLIF(COUNT(DISTINCT lcm_id), 0), 2)           AS `ARPPU`
FROM SkuDetail
GROUP BY vip_level, item_id, sku, sku_name
ORDER BY vip_level ASC, `付费金额CNY` DESC;
