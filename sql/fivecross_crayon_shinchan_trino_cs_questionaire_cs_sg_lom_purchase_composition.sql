-- 1. 付费构成
WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users','is_windows')
),
new_roles AS (
    SELECT 
        DISTINCT v."#user_id",
        CASE WHEN lm."#account_id@lom" = 'A' THEN 'Y' WHEN lm."#account_id@lom" = 'B' THEN 'N' ELSE '未填写问卷' END AS is_lom
    FROM ta.v_event_13 v
    LEFT JOIN ta_dim.dim_13_0_18164 lm ON v."#account_id" = lm."#account_id@role_id"
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_date" BETWEEN '2026-05-08' AND '2026-05-10'
      AND v."$part_event" = 'new_role'
      AND ub."#user_id" IS NULL
),
charge_logs AS (
    SELECT 
        n.is_lom,
        v.product_id,
        TRY_CAST(v.pay_amount_usd AS DOUBLE) AS rev
    FROM ta.v_event_13 v
    INNER JOIN new_roles n ON v."#user_id" = n."#user_id"
    WHERE v."$part_event" = 'charge'
      AND v."$part_date" >= '2026-05-08'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
)
SELECT 
    c.is_lom AS "是否菇勇者",
    c.product_id AS "商品ID",
    dp."product_id@product_name_tc" AS "商品名称",
    dp."product_id@product_type" AS "商品类型",
    SUM(c.rev) AS "总充值金额(USD)",
    COUNT(1) AS "购买总次数"
FROM charge_logs c
LEFT JOIN ta_dim.dim_13_0_20639 dp ON CAST(c.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER) 
WHERE c.is_lom IN ('Y', 'N')
GROUP BY 1, 2, 3, 4
ORDER BY 1, 5 DESC;
