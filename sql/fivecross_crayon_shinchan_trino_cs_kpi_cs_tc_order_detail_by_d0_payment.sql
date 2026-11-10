WITH D0NewUsers AS (
    SELECT DISTINCT "#account_id" AS account_id
    FROM ta.v_event_18
    WHERE "$part_date" = '2026-07-29'
      AND "$part_event" = 'new_role'
),
D0Payers AS (
    SELECT DISTINCT "#account_id" AS account_id
    FROM ta.v_event_18
    WHERE "$part_date" = '2026-07-29'
      AND "$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
),
D1NewUsers AS (
    SELECT DISTINCT "#account_id" AS account_id
    FROM ta.v_event_18
    WHERE "$part_date" = '2026-07-30'
      AND "$part_event" = 'new_role'
),
TargetOrders AS (
    SELECT
        s1."$part_date",
        s1."#event_time",
        s1."#account_id",
        CASE
            WHEN d0n.account_id IS NOT NULL AND d0p.account_id IS NOT NULL THEN '7/29 D0已充值新用户'
            WHEN d0n.account_id IS NOT NULL THEN '7/29 D0未充值新用户'
            WHEN d1n.account_id IS NOT NULL THEN '7/30 新用户'
            ELSE '其他老用户'
        END AS user_segment,
        dp."product_id@product_type" AS product_category,
        s1.product_id,
        dp."product_id@product_name_tc" AS product_name,
        ROUND(CAST(s1.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1), 2) AS pay_amount_usd,
        s1.pay_amount,
        s1.pay_currency,
        s1.pay_amount_usd AS pay_amount_usd_original,
        s1.pay_type,
        ARRAY_JOIN(TRANSFORM(s1.a_rst, x -> CAST(x.name AS VARCHAR)), '+') AS "礼包内容",
        ARRAY_JOIN(TRANSFORM(s1.a_rst, x -> CAST(CAST(x.id AS INTEGER) AS VARCHAR)), '+') AS "道具ID",
        s1.sandbox,
        s1.is_freebuy
    FROM ta.v_event_18 s1
    LEFT JOIN D0NewUsers d0n ON s1."#account_id" = d0n.account_id
    LEFT JOIN D0Payers d0p ON s1."#account_id" = d0p.account_id
    LEFT JOIN D1NewUsers d1n ON s1."#account_id" = d1n.account_id
    LEFT JOIN ta_dim.dim_13_0_20639 dp
      ON CAST(s1.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER)
    LEFT JOIN ta_dim.ta_exchange s5
      ON s1."$part_date" = s5.ex_date
     AND s1.pay_currency = s5.currency
    WHERE s1."$part_date" = '2026-07-30'
      AND s1."$part_event" = 'charge'
      AND (s1.sandbox IS NULL OR s1.sandbox = FALSE)
      AND (s1.is_freebuy IS NULL OR s1.is_freebuy = FALSE)
)
SELECT *
FROM TargetOrders
ORDER BY
    CASE user_segment
        WHEN '7/29 D0已充值新用户' THEN 1
        WHEN '7/29 D0未充值新用户' THEN 2
        WHEN '7/30 新用户' THEN 3
        ELSE 4
    END,
    "#account_id",
    "#event_time"
