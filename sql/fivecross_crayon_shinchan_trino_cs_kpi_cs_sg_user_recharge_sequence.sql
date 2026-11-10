WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users','is_windows')
),

CohortUsers AS (
    SELECT DISTINCT "#user_id"
    FROM ta.v_event_13
    WHERE "$part_event" = 'new_role' 
      AND "$part_date" BETWEEN '2026-05-08' AND '2026-05-10'
),

ChargeData AS (
    SELECT 
        v."#user_id",
        dp."product_id@product_type" AS product_category,
        dp."product_id@product_name_tc" AS product_name,
        -- 按充值时间升序排列，给每个用户的充值记录打上序号 1,2,3...
        ROW_NUMBER() OVER(PARTITION BY v."#user_id" ORDER BY v."#event_time" ASC) AS rn
    FROM ta.v_event_13 v
    INNER JOIN CohortUsers cu ON v."#user_id" = cu."#user_id"
    LEFT JOIN ta_dim.dim_13_0_20639 dp 
        ON CAST(v.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER) 
    LEFT JOIN UserBlacklist ub 
        ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" = 'charge'
      -- 过滤 5月8日 - 5月13日
      AND v."$part_date" BETWEEN '2026-05-08' AND '2026-05-13'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND ub."#user_id" IS NULL
)

SELECT 
    CAST("#user_id" AS VARCHAR)||'a',
    -- 取出第 1 次充值的 category 和 name
    MAX(CASE WHEN rn = 1 THEN product_category END) AS "第1次充值_category",
    MAX(CASE WHEN rn = 1 THEN product_name END) AS "第1次充值_name",
    
    -- 取出第 2 次充值的 category 和 name
    MAX(CASE WHEN rn = 2 THEN product_category END) AS "第2次充值_category",
    MAX(CASE WHEN rn = 2 THEN product_name END) AS "第2次充值_name",
    
    -- 取出第 3 次充值的 category 和 name
    MAX(CASE WHEN rn = 3 THEN product_category END) AS "第3次充值_category",
    MAX(CASE WHEN rn = 3 THEN product_name END) AS "第3次充值_name",
    
    -- 取出第 4 次充值的 category 和 name
    MAX(CASE WHEN rn = 4 THEN product_category END) AS "第4次充值_category",
    MAX(CASE WHEN rn = 4 THEN product_name END) AS "第4次充值_name",
    
    -- 取出第 5 次充值的 category 和 name
    MAX(CASE WHEN rn = 5 THEN product_category END) AS "第5次充值_category",
    MAX(CASE WHEN rn = 5 THEN product_name END) AS "第5次充值_name",
    
    -- 顺便统计该用户在这个周期内的总充值次数
    MAX(rn) AS "总充值次数"
FROM ChargeData
GROUP BY "#user_id"
-- 只要存在至少1次充值的用户 (由于在ChargeData里的肯定有1，所以这里默认都是有的，写上只是为了语义明确)
HAVING MAX(CASE WHEN rn = 1 THEN 1 ELSE 0 END) = 1
ORDER BY "总充值次数" DESC;
