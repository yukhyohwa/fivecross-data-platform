/*
Slam Dunk TC / GL / KR shop tabs by VIP, rolling three-month window.
Window: 2026-06-21 through 2026-09-20 (inclusive; last complete day).
Grain: version + shop_id + VIP + shop item.
Purchase rate: distinct purchasing roles / distinct behavior-active roles in the same version and full window.
Sales amount: virtual-resource consumption in the same shop_buy event, retained by resource type; unlike cash revenue, unlike units cannot be added together.
*/
WITH vip_snapshot_ranked AS (
    SELECT version, day, role_id, total_pay,
           ROW_NUMBER() OVER (PARTITION BY version, day, role_id ORDER BY event_time DESC) AS rn
    FROM (
        SELECT '繁体' AS version, "$part_date" AS day, CAST(user_id AS VARCHAR) AS role_id,
               TRY_CAST(total_pay AS DOUBLE) AS total_pay, "#event_time" AS event_time
        FROM ta.v_event_20
        WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
          AND "$part_event" = 'user_snapshot'
        UNION ALL
        SELECT '全球', "$part_date", CAST(user_id AS VARCHAR), TRY_CAST(total_pay AS DOUBLE), "#event_time"
        FROM ta.v_event_21
        WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
          AND "$part_event" = 'user_snapshot'
        UNION ALL
        SELECT '韩国', "$part_date", CAST(user_id AS VARCHAR), TRY_CAST(total_pay AS DOUBLE), "#event_time"
        FROM ta.v_event_22
        WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
          AND "$part_event" = 'user_snapshot'
    ) s
    WHERE role_id IS NOT NULL
),
vip_daily AS (
    SELECT version, day, role_id,
           CASE
               WHEN COALESCE(total_pay, 0) = 0 THEN 'V0'
               WHEN total_pay < 34 THEN 'V1'
               WHEN total_pay < 171 THEN 'V2'
               WHEN total_pay < 501 THEN 'V3'
               WHEN total_pay < 2501 THEN 'V4'
               WHEN total_pay < 5001 THEN 'V5'
               WHEN total_pay < 15001 THEN 'V6'
               WHEN total_pay < 50001 THEN 'V7'
               WHEN total_pay < 200001 THEN 'V8'
               ELSE 'V9'
           END AS vip
    FROM vip_snapshot_ranked
    WHERE rn = 1
),
purchase_base AS (
    SELECT '繁体' AS version,
           "$part_date" AS day,
           SPLIT(a_usr, '@')[2] AS role_id,
           COALESCE(NULLIF(TRIM(shop_id_str), ''), 'UNKNOWN') AS shop_id,
           COALESCE(NULLIF(TRIM(item_id_str), ''), NULLIF(TRIM(item_id), ''), 'UNKNOWN') AS get_item_id,
           COALESCE(TRY_CAST(num_str AS DOUBLE), TRY_CAST(num AS DOUBLE), 1.0) AS get_item_nums
    FROM ta.v_event_20
    WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
      AND "$part_event" = 'shop_buy'

    UNION ALL

    SELECT '全球', "$part_date", SPLIT(a_usr, '@')[2],
           COALESCE(NULLIF(TRIM(shop_id_str), ''), 'UNKNOWN'),
           COALESCE(NULLIF(TRIM(item_id_str), ''), NULLIF(TRIM(item_id), ''), 'UNKNOWN'),
           COALESCE(TRY_CAST(num_str AS DOUBLE), TRY_CAST(num AS DOUBLE), 1.0)
    FROM ta.v_event_21
    WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
      AND "$part_event" = 'shop_buy'

    UNION ALL

    SELECT '韩国', "$part_date", SPLIT(a_usr, '@')[2],
           COALESCE(NULLIF(TRIM(shop_id_str), ''), 'UNKNOWN'),
           COALESCE(NULLIF(TRIM(item_id_str), ''), NULLIF(TRIM(item_id), ''), 'UNKNOWN'),
           COALESCE(TRY_CAST(num_str AS DOUBLE), TRY_CAST(num AS DOUBLE), 1.0)
    FROM ta.v_event_22
    WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
      AND "$part_event" = 'shop_buy'
),
purchases AS (
    SELECT p.version, p.day, p.role_id, p.shop_id, p.get_item_id, p.get_item_nums,
           COALESCE(v.vip, 'V0') AS vip
    FROM purchase_base p
    LEFT JOIN vip_daily v
      ON p.version = v.version
     AND p.day = v.day
     AND p.role_id = v.role_id
),
main_metrics AS (
    SELECT version, shop_id, vip, get_item_id,
           CAST(ROUND(SUM(get_item_nums)) AS BIGINT) AS get_item_nums,
           COUNT(*) AS buy_times,
           COUNT(DISTINCT role_id) AS cuu
    FROM purchases
    GROUP BY 1,2,3,4
),
cost_lines AS (
    SELECT '繁体' AS version,
           COALESCE(NULLIF(TRIM(e.shop_id_str), ''), 'UNKNOWN') AS shop_id,
           COALESCE(v.vip, 'V0') AS vip,
           COALESCE(NULLIF(TRIM(e.item_id_str), ''), NULLIF(TRIM(e.item_id), ''), 'UNKNOWN') AS get_item_id,
           JSON_EXTRACT_SCALAR(JSON_PARSE(x), '$.obj') AS cost_obj,
           -TRY_CAST(JSON_EXTRACT_SCALAR(JSON_PARSE(x), '$.diff') AS DOUBLE) AS cost_amount
    FROM ta.v_event_20 e
    CROSS JOIN UNNEST(FILTER(e.a_rst, x -> x IS NOT NULL AND x <> ''
        AND TRY_CAST(JSON_EXTRACT_SCALAR(JSON_PARSE(x), '$.diff') AS DOUBLE) < 0)) AS t(x)
    LEFT JOIN vip_daily v
      ON v.version = '繁体' AND v.day = e."$part_date" AND v.role_id = SPLIT(e.a_usr, '@')[2]
    WHERE e."$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
      AND e."$part_event" = 'shop_buy'

    UNION ALL

    SELECT '全球',
           COALESCE(NULLIF(TRIM(e.shop_id_str), ''), 'UNKNOWN'),
           COALESCE(v.vip, 'V0'),
           COALESCE(NULLIF(TRIM(e.item_id_str), ''), NULLIF(TRIM(e.item_id), ''), 'UNKNOWN'),
           obj,
           -TRY_CAST(diff AS DOUBLE)
    FROM ta.v_event_21 e
    CROSS JOIN UNNEST(FILTER(e.a_rst, x -> x IS NOT NULL AND TRY_CAST(x.diff AS DOUBLE) < 0))
        AS t(before_val, obj, diff, after_val)
    LEFT JOIN vip_daily v
      ON v.version = '全球' AND v.day = e."$part_date" AND v.role_id = SPLIT(e.a_usr, '@')[2]
    WHERE e."$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
      AND e."$part_event" = 'shop_buy'

    UNION ALL

    SELECT '韩国',
           COALESCE(NULLIF(TRIM(e.shop_id_str), ''), 'UNKNOWN'),
           COALESCE(v.vip, 'V0'),
           COALESCE(NULLIF(TRIM(e.item_id_str), ''), NULLIF(TRIM(e.item_id), ''), 'UNKNOWN'),
           JSON_EXTRACT_SCALAR(JSON_PARSE(x), '$.obj'),
           -TRY_CAST(JSON_EXTRACT_SCALAR(JSON_PARSE(x), '$.diff') AS DOUBLE)
    FROM ta.v_event_22 e
    CROSS JOIN UNNEST(FILTER(e.a_rst, x -> x IS NOT NULL AND x <> ''
        AND TRY_CAST(JSON_EXTRACT_SCALAR(JSON_PARSE(x), '$.diff') AS DOUBLE) < 0)) AS t(x)
    LEFT JOIN vip_daily v
      ON v.version = '韩国' AND v.day = e."$part_date" AND v.role_id = SPLIT(e.a_usr, '@')[2]
    WHERE e."$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
      AND e."$part_event" = 'shop_buy'
),
cost_by_type AS (
    SELECT version, shop_id, vip, get_item_id, cost_obj,
           SUM(cost_amount) AS cost_amount
    FROM cost_lines
    WHERE cost_obj IS NOT NULL AND cost_amount > 0
    GROUP BY 1,2,3,4,5
),
cost_summary AS (
    SELECT version, shop_id, vip, get_item_id,
           COUNT(*) AS cost_item_type_nums,
           ARRAY_JOIN(
               ARRAY_AGG(
                   CONCAT(
                       cost_obj, ':',
                       CASE
                           WHEN cost_amount = CAST(cost_amount AS BIGINT)
                               THEN CAST(CAST(cost_amount AS BIGINT) AS VARCHAR)
                           ELSE CAST(ROUND(cost_amount, 4) AS VARCHAR)
                       END
                   ) ORDER BY cost_obj
               ),
               ';'
           ) AS cost_item_detail
    FROM cost_by_type
    GROUP BY 1,2,3,4
),
active_roles AS (
    SELECT version, COUNT(DISTINCT role_id) AS active_uu
    FROM (
        SELECT '繁体' AS version, SPLIT(a_usr, '@')[2] AS role_id
        FROM ta.v_event_20
        WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
          AND NOT REGEXP_LIKE("$part_event", 'snapshot$')
          AND "$part_event" NOT IN ('NUU', 'PURCHASE', 'LOGIN_SUCCESS',
              'LCX_WALLET_SPEND_TRANSACTION', 'LCX_WALLET_PURCHASE_TRANSACTION')
          AND SPLIT(a_usr, '@')[2] IS NOT NULL
        UNION ALL
        SELECT '全球', SPLIT(a_usr, '@')[2]
        FROM ta.v_event_21
        WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
          AND NOT REGEXP_LIKE("$part_event", 'snapshot$')
          AND "$part_event" NOT IN ('NUU', 'PURCHASE', 'LOGIN_SUCCESS',
              'LCX_WALLET_SPEND_TRANSACTION', 'LCX_WALLET_PURCHASE_TRANSACTION')
          AND SPLIT(a_usr, '@')[2] IS NOT NULL
        UNION ALL
        SELECT '韩国', SPLIT(a_usr, '@')[2]
        FROM ta.v_event_22
        WHERE "$part_date" BETWEEN '2026-06-21' AND '2026-09-20'
          AND NOT REGEXP_LIKE("$part_event", 'snapshot$')
          AND "$part_event" NOT IN ('NUU', 'PURCHASE', 'LOGIN_SUCCESS',
              'LCX_WALLET_SPEND_TRANSACTION', 'LCX_WALLET_PURCHASE_TRANSACTION')
          AND SPLIT(a_usr, '@')[2] IS NOT NULL
    ) a
    GROUP BY 1
)
SELECT m.version,
       m.shop_id,
       m.vip,
       m.get_item_id,
       m.get_item_nums,
       m.buy_times,
       m.cuu,
       a.active_uu,
       ROUND(CAST(m.cuu AS DOUBLE) / NULLIF(a.active_uu, 0), 4) AS purchase_rate,
       COALESCE(CAST(c.cost_item_type_nums AS VARCHAR), 'N') AS cost_item_type_nums,
       COALESCE(c.cost_item_detail, 'N') AS cost_item_detail
FROM main_metrics m
JOIN active_roles a ON m.version = a.version
LEFT JOIN cost_summary c
  ON m.version = c.version
 AND m.shop_id = c.shop_id
 AND m.vip = c.vip
 AND m.get_item_id = c.get_item_id
ORDER BY
    CASE m.version WHEN '繁体' THEN 1 WHEN '韩国' THEN 2 WHEN '全球' THEN 3 ELSE 9 END,
    m.shop_id,
    CAST(SUBSTR(m.vip, 2) AS INTEGER),
    m.get_item_id;
