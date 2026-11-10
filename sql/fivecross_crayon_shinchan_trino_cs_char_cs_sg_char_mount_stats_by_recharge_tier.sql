WITH AccountToUser AS (
    -- 建立 account_id 到 user_id 的映射（快照里的 lid 对应 account_id）
    SELECT 
        "#account_id" AS account_id, 
        MAX("#user_id") AS user_id
    FROM ta.v_event_13
    WHERE "$part_event" IN ('login', 'new_role')
      AND "#user_id" IS NOT NULL
      AND "#account_id" IS NOT NULL
    GROUP BY 1
),
SingaporeUsers AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country' AND tag_value = '新加坡'
),
UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),
ValidAccounts AS (
    -- 过滤出新加坡且非黑名单的 account_id
    SELECT a.account_id
    FROM AccountToUser a
    INNER JOIN SingaporeUsers su ON a.user_id = su.user_id
    LEFT JOIN UserBlacklist ub ON a.user_id = ub.user_id
    WHERE ub.user_id IS NULL
),
user_recharge AS (
    -- 计算有效用户的累计充值金额
    SELECT 
        v."#account_id" AS account_id,
        SUM(TRY_CAST(v.pay_amount_usd AS DOUBLE)) AS total_revenue_usd
    FROM ta.v_event_13 v
    INNER JOIN ValidAccounts va ON v."#account_id" = va.account_id
    WHERE v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
    GROUP BY 1
),
ValidAccountsWithTier AS (
    -- 给每个有效账户打上充值档位标签
    SELECT 
        v.account_id,
        COALESCE(r.total_revenue_usd, 0) AS total_revenue_usd,
        CASE 
            WHEN COALESCE(r.total_revenue_usd, 0) = 0 THEN '0.免费用户'
            WHEN r.total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN r.total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN r.total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN r.total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM ValidAccounts v
    LEFT JOIN user_recharge r ON v.account_id = r.account_id
),
flattened_data AS (
    SELECT 
        v."$part_date",
        va.recharge_tier,
        v.lid AS role_id,
        v."#event_time",
        CAST(v.mount.level AS BIGINT) AS mount_lv, 
        CAST(v.mount.exp AS BIGINT) AS mount_exp
    FROM ta.v_event_13 v
    -- 通过内连 ValidAccountsWithTier，实现精准的新加坡白名单过滤及充值标签映射
    INNER JOIN ValidAccountsWithTier va ON v.lid = va.account_id
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'daily_role_snapshot'
),
latest_state AS (
    -- 取每个账号每天最后的坐骑状态
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY "$part_date", role_id ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
)

-- 计算每日各充值区间的平均等级和经验
SELECT 
    "$part_date" AS "日期",
    recharge_tier AS "付费档位",
    COUNT(DISTINCT role_id) AS "玩家人数",
    ROUND(AVG(CAST(mount_lv AS DOUBLE)), 2) AS "平均坐骑等级",
    ROUND(AVG(CAST(mount_exp AS DOUBLE)), 2) AS "平均坐骑经验",
    APPROX_PERCENTILE(mount_lv, 0.5) AS "坐骑等级中位数"
FROM latest_state
WHERE rn = 1
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
