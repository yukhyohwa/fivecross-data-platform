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
ValidUsers AS (
    SELECT su."#user_id"
    FROM SingaporeUsers su
    LEFT JOIN UserBlacklist ub ON su."#user_id" = ub."#user_id"
    WHERE ub."#user_id" IS NULL
),
-- 计算“游乐园礼包”专属的累计充值
ParkRecharge AS (
    SELECT 
        v."#user_id",
        SUM(TRY_CAST(v.pay_amount_usd AS DOUBLE)) AS total_revenue_usd
    FROM ta.v_event_13 v
    INNER JOIN ValidUsers vu ON v."#user_id" = vu."#user_id"
    WHERE v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      -- 仅看游乐园礼包
      AND CAST(v.product_id AS BIGINT) IN (119201, 119202, 119203, 119204, 119205, 119206)
    GROUP BY 1
),
ValidUsersWithTier AS (
    -- 给有效账户打上专属充值档位标签
    SELECT 
        v."#user_id",
        CASE 
            WHEN COALESCE(r.total_revenue_usd, 0) = 0 THEN '0.免费用户'
            WHEN r.total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN r.total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN r.total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN r.total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM ValidUsers v
    LEFT JOIN ParkRecharge r ON v."#user_id" = r."#user_id"
),
ConsumeEvents AS (
    -- 提取发生了 430002 消耗的事件，并将整个道具变动数组 a_rst 带出
    SELECT 
        v."$part_date",
        vt.recharge_tier,
        v."#account_id",
        cast(to_unixtime(cast("#event_time" AS timestamp(3)))  AS bigint) event_time,
        v.a_rst[1].diff AS coumsue_nums
    FROM ta.v_event_13 v
    INNER JOIN ValidUsersWithTier vt ON v."#user_id" = vt."#user_id"
    WHERE v."$part_event" = 'item_change'
      AND v.${PartDate:date1}
      -- 找到本次事件中确实消耗了 430002 的记录
      AND ANY_MATCH(v.a_rst, x -> CAST(x.id AS BIGINT) = 430002 AND CAST(x.before AS BIGINT) > CAST(x.after AS BIGINT))
),
GainedItems AS (
    SELECT 
        v."$part_date",
        vt.recharge_tier,
        v."#account_id",
        cast(to_unixtime(cast("#event_time" AS timestamp(3)))  AS bigint) event_time,
        v.a_rst[1].id AS gained_item_id,
        v.a_rst[1].diff AS gained_amount
    FROM ta.v_event_13 v
    INNER JOIN ValidUsersWithTier vt ON v."#user_id" = vt."#user_id"
    WHERE v."$part_event" = 'item_change'
      AND v.${PartDate:date1}
      AND a_rst[1].id <> 43002
)

SELECT 
    ce."$part_date" AS "日期",
    ce.recharge_tier AS "游乐园专属付费档位",
    COALESCE(dim."item_id@item_name", CAST(CAST(ga.gained_item_id AS INTEGER) AS VARCHAR)) AS "兑换获得的道具ID",
    COUNT(DISTINCT ce."#account_id") AS "兑换人数",
    SUM(ce.coumsue_nums) AS "消耗道具总数"
FROM ConsumeEvents ce
JOIN GainedItems ga
    ON ce."$part_date" = ga."$part_date"
    AND ce."#account_id" = ga."#account_id"
    AND ce.event_time = ga.event_time
LEFT JOIN ta_dim.dim_13_0_18269 dim
    ON CAST(CAST(ga.gained_item_id AS INTEGER) AS VARCHAR)  = CAST(CAST(dim."item_id@item_id" AS INTEGER) AS VARCHAR)
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 5 DESC;
