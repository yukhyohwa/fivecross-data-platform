WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows')
)

SELECT 
    ${Selector:timetype} AS time_dimension,
    dp."product_id@product_type" AS product_category,
    COUNT(DISTINCT s1."#user_id") AS pu,
    COUNT(1) AS buy_count,
    SUM(COALESCE(s1.pay_amount_usd, 0)) AS revenue_usd,
    CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) AS date_range
FROM (
    SELECT 
        "$part_date",
        "#user_id",
        product_id,
        "pay_currency",
        CAST(v.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1) pay_amount_usd
    FROM ta.v_event_18 v
        LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
       AND v."pay_currency"= s5.currency
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'charge'
      -- Exclude sandbox orders
      AND (sandbox IS NULL OR sandbox = FALSE)
      -- Exclude 0-dollar buys
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
) s1
LEFT JOIN UserBlacklist s2 ON s1."#user_id"= s2."#user_id"
LEFT JOIN ta_dim.dim_18_0_52801 dp ON CAST(s1.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER) 
WHERE s2."#user_id" IS NULL
GROUP BY 1, 2
ORDER BY 1 DESC, 5 DESC
