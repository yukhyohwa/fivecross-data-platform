WITH SingaporeUsers AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country' AND tag_value = '新加坡'
),

UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),

-- 1. 提取每日活跃人数 (AU)
DailyAU AS (
    SELECT 
        v."$part_date" AS time_dimension,
        COUNT(DISTINCT v."#account_id") AS active_users
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN SingaporeUsers su ON v."#user_id" = su."#user_id"
    WHERE v."$part_event" = 'login'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1
),

-- 2. 提取每日道具消耗情况
ConsumeLogs AS (
    SELECT 
        v."$part_date" AS time_dimension,
        -- 使用 before > after 判定为消耗，取差值的绝对值进行累加
        SUM(REDUCE(v.a_rst, CAST(0 AS BIGINT), 
            (s, x) -> s + CASE 
                WHEN CAST(x.id AS BIGINT) = 430001 AND CAST(x.before AS BIGINT) > CAST(x.after AS BIGINT) 
                THEN ABS(CAST(x.diff AS BIGINT)) 
                ELSE 0 
            END, 
            s -> s
        )) AS total_consume,
        COUNT(DISTINCT v."#account_id") AS consume_users
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN SingaporeUsers su ON v."#user_id" = su."#user_id"
    WHERE v."$part_event" = 'item_change'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
      -- 只要道具变动数组中包含 430001 即提取
      AND ANY_MATCH(v.a_rst, x -> CAST(x.id AS BIGINT) = 430001)
    GROUP BY 1
),

-- 3. 提取指定游乐园礼包每日收入
GiftRevenue AS (
    SELECT 
        v."$part_date" AS time_dimension,
        SUM(TRY_CAST(v.pay_amount_usd AS DOUBLE)) AS gift_revenue_usd
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN SingaporeUsers su ON v."#user_id" = su."#user_id"
    WHERE v."$part_event" = 'charge'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      -- 从图片中提取的游乐园礼包 ID
      AND CAST(v.product_id AS BIGINT) IN (119201, 119202, 119203, 119204, 119205, 119206)
    GROUP BY 1
)

-- 4. 合并产出参与率、人均消耗与礼包收入
SELECT 
    c.time_dimension AS "日期",
    c.consume_users AS "参与人数(消耗人数)",
    c.total_consume AS "活动道具消耗总数",
    a.active_users AS "全服活跃人数(AU)",
    ROUND(CAST(c.consume_users AS DOUBLE) / NULLIF(a.active_users, 0),4) AS "参与渗透率",
    ROUND(CAST(c.total_consume AS DOUBLE) / NULLIF(c.consume_users, 0),2) AS "人均消耗数",
    ROUND(COALESCE(g.gift_revenue_usd, 0), 2) AS "指定礼包累计收入(USD)"
FROM ConsumeLogs c
LEFT JOIN DailyAU a ON c.time_dimension = a.time_dimension
LEFT JOIN GiftRevenue g ON c.time_dimension = g.time_dimension
ORDER BY c.time_dimension DESC;
