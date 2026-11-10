-- 2. 首充道具分布
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
first_charge AS (
    SELECT 
        n.is_lom,
        v.product_id,
        ROW_NUMBER() OVER(PARTITION BY v."#user_id" ORDER BY v."#event_time" ASC) AS rn
    FROM ta.v_event_13 v
    INNER JOIN new_roles n ON v."#user_id" = n."#user_id"
    WHERE v."$part_event" = 'charge'
      AND v."$part_date" >= '2026-05-08'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
)
SELECT 
    f.is_lom AS "是否菇勇者",
    f.product_id AS "商品ID",
    dp."product_id@product_name_tc" AS "商品名称",
    dp."product_id@product_type" AS "商品类型",
    COUNT(1) AS "首充该道具的人数"
FROM first_charge f
LEFT JOIN ta_dim.dim_13_0_20639 dp ON CAST(f.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER) 
WHERE f.rn = 1 AND f.is_lom IN ('Y', 'N')
GROUP BY 1, 2, 3, 4
ORDER BY 1, 5 DESC;
