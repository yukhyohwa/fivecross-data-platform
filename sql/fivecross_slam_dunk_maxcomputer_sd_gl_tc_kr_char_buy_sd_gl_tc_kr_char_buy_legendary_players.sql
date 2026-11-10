--灌篮高手 KR  传奇球员礼包销售统计
--汇率基准：当月第1天, 兑换目标: CNY
--来源表: dm_platform.daily_lcx_user_purchase / dm_platform.itunes_exchange_rate_fmp
--注意: 此文件为 Hologres 兼容语法 (PostgreSQL), 所有子查询均带别名

-- ============================================================
-- 传奇仙道  25年6月5日 ~ 25年6月25日
-- package: 0034加速箱 / 0035奇遇箱 / 0036起跑禮 / 0037資料豪禮
-- ============================================================
SELECT app_id, region, '20250605~20250625' AS period, sku_type, COUNT(DISTINCT lcm_id) AS uu, SUM(price_show * exchange_rate) AS sales
FROM (
    SELECT
        CASE
            WHEN sku LIKE '%package0034' THEN '傳奇仙道加速箱'
            WHEN sku LIKE '%package0035' THEN '傳奇仙道奇遇箱'
            WHEN sku LIKE '%package0036' THEN '傳奇仙道起跑禮'
            WHEN sku LIKE '%package0037' THEN '傳奇仙道資料豪禮'
            ELSE 'other'
        END AS sku_type,
        CASE app_id
            WHEN '23002013' THEN '繁体(TC)'
            WHEN '33002013' THEN '韩国(KR)'
            WHEN '63002013' THEN '全球(GL)'
            ELSE app_id
        END AS region,
        app_id, event_time, lcm_id, sku, sku_name, unit_show, price_show
    FROM dm_platform.daily_lcx_user_purchase
    WHERE day BETWEEN 20250605 AND 20250625
      AND app_id IN ('23002013','33002013','63002013')
) AS a
LEFT OUTER JOIN (
    SELECT substr(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, tolower(trans_from) AS trans_from, exchange_rate,
               row_number() OVER (PARTITION BY trans_to, trans_from, substr(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp
        WHERE trans_to = 'cny'
          AND day = 20250601
    ) AS ranked_0605
    WHERE rank1 = 1
) b ON lower(a.unit_show) = b.trans_from
GROUP BY app_id, region, period, sku_type

UNION ALL

-- ============================================================
-- 传奇池上  25年7月10日 ~ 25年7月30日
-- package: 0041加速箱 / 0042奇遇箱 / 0043起跑禮 / 0044轉盤禮
-- ============================================================
SELECT app_id, region, '20250710~20250730' AS period, sku_type, COUNT(DISTINCT lcm_id) AS uu, SUM(price_show * exchange_rate) AS sales
FROM (
    SELECT
        CASE
            WHEN sku LIKE '%package0041' THEN '傳奇池上加速箱'
            WHEN sku LIKE '%package0042' THEN '傳奇池上奇遇箱'
            WHEN sku LIKE '%package0043' THEN '陵南池上起跑禮'
            WHEN sku LIKE '%package0044' THEN '傳奇池上轉盤禮'
            ELSE 'other'
        END AS sku_type,
        CASE app_id
            WHEN '23002013' THEN '繁体(TC)'
            WHEN '33002013' THEN '韩国(KR)'
            WHEN '63002013' THEN '全球(GL)'
            ELSE app_id
        END AS region,
        app_id, event_time, lcm_id, sku, sku_name, unit_show, price_show
    FROM dm_platform.daily_lcx_user_purchase
    WHERE day BETWEEN 20250710 AND 20250730
      AND app_id IN ('23002013','33002013','63002013')
) AS a
LEFT OUTER JOIN (
    SELECT substr(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, tolower(trans_from) AS trans_from, exchange_rate,
               row_number() OVER (PARTITION BY trans_to, trans_from, substr(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp
        WHERE trans_to = 'cny'
          AND day = 20250701
    ) AS ranked_0710
    WHERE rank1 = 1
) b ON lower(a.unit_show) = b.trans_from
GROUP BY app_id, region, period, sku_type

UNION ALL

-- ============================================================
-- 传奇越野  25年8月14日 ~ 25年9月3日
-- package: 0055加速箱 / 0056奇遇箱 / 0057起跑禮 / 0058轉盤禮
-- ============================================================
SELECT app_id, region, '20250814~20250903' AS period, sku_type, COUNT(DISTINCT lcm_id) AS uu, SUM(price_show * exchange_rate) AS sales
FROM (
    SELECT
        CASE
            WHEN sku LIKE '%package0055' THEN '傳奇越野加速箱'
            WHEN sku LIKE '%package0056' THEN '傳奇越野奇遇箱'
            WHEN sku LIKE '%package0057' THEN '陵南越野起跑禮'
            WHEN sku LIKE '%package0058' THEN '傳奇越野轉盤禮'
            ELSE 'other'
        END AS sku_type,
        CASE app_id
            WHEN '23002013' THEN '繁体(TC)'
            WHEN '33002013' THEN '韩国(KR)'
            WHEN '63002013' THEN '全球(GL)'
            ELSE app_id
        END AS region,
        app_id, event_time, lcm_id, sku, sku_name, unit_show, price_show
    FROM dm_platform.daily_lcx_user_purchase
    WHERE day BETWEEN 20250814 AND 20250903
      AND app_id IN ('23002013','33002013','63002013')
) AS a
LEFT OUTER JOIN (
    SELECT substr(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, tolower(trans_from) AS trans_from, exchange_rate,
               row_number() OVER (PARTITION BY trans_to, trans_from, substr(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp
        WHERE trans_to = 'cny'
          AND day = 20250801
    ) AS ranked_0814
    WHERE rank1 = 1
) b ON lower(a.unit_show) = b.trans_from
GROUP BY app_id, region, period, sku_type

UNION ALL

-- ============================================================
-- 传奇宮益  26年2月5日 ~ 26年2月18日
-- 加速箱: ..._tier27.package0094 / 起跑禮: ..._tier55.package0094
-- 奇遇箱: ..._tier14.package0095 / 轉盤禮: ..._tier53.package0095
-- 注意: 數字後綴 0094/0095 相同，但完整 SKU 中 _tier 不同，為獨立 SKU
-- ============================================================
SELECT app_id, region, '20260205~20260218' AS period, sku_type, COUNT(DISTINCT lcm_id) AS uu, SUM(price_show * exchange_rate) AS sales
FROM (
    SELECT
        CASE
            WHEN sku LIKE '%tier27%.package0094' THEN '傳奇宮益加速箱'
            WHEN sku LIKE '%tier55%.package0094' THEN '傳奇宮益起跑禮'
            WHEN sku LIKE '%tier14%.package0095' THEN '傳奇宮益奇遇箱'
            WHEN sku LIKE '%tier53%.package0095' THEN '傳奇宮益轉盤禮'
            ELSE 'other'
        END AS sku_type,
        CASE app_id
            WHEN '23002013' THEN '繁体(TC)'
            WHEN '33002013' THEN '韩国(KR)'
            WHEN '63002013' THEN '全球(GL)'
            ELSE app_id
        END AS region,
        app_id, event_time, lcm_id, sku, sku_name, unit_show, price_show
    FROM dm_platform.daily_lcx_user_purchase
    WHERE day BETWEEN 20260205 AND 20260218
      AND app_id IN ('23002013','33002013','63002013')
) AS a
LEFT OUTER JOIN (
    SELECT substr(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, tolower(trans_from) AS trans_from, exchange_rate,
               row_number() OVER (PARTITION BY trans_to, trans_from, substr(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp
        WHERE trans_to = 'cny'
          AND day = 20260201
    ) AS ranked_0205
    WHERE rank1 = 1
) b ON lower(a.unit_show) = b.trans_from
GROUP BY app_id, region, period, sku_type;
