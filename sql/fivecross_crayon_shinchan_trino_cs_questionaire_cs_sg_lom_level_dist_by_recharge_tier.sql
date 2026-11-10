WITH AccountToUser AS (
    -- 第一步：由于快照无 user_id，需要借助 login/new_role 建立 account_id(即 lid) 到 user_id 的映射关系
    SELECT 
        "#account_id" AS account_id, 
        MAX("#user_id") AS user_id
    FROM ta.v_event_13
    WHERE "$part_event" IN ('login', 'new_role')
      AND "#user_id" IS NOT NULL
      AND "#account_id" IS NOT NULL
      -- 为了确保能获取到所有人的映射，这里不限制日期
    GROUP BY 1
),
UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),
SingaporeUsers AS (
    -- 获取新加坡的 user_id
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country' AND tag_value = '新加坡'
),
ValidAccounts AS (
    -- 第二步：过滤出符合条件（新加坡且非黑名单）的 account_id
    SELECT a.account_id
    FROM AccountToUser a
    INNER JOIN SingaporeUsers su ON a.user_id = su.user_id
    LEFT JOIN UserBlacklist ub ON a.user_id = ub.user_id
    WHERE ub.user_id IS NULL
),
flattened_data AS (
    -- 第三步：读取快照，通过 lid (即 account_id) 只关联 ValidAccounts 的用户
    SELECT 
        v.lid AS account_id,
        v."#event_time",
        CAST(v.role_lev AS BIGINT) AS role_level
    FROM ta.v_event_13 v
    INNER JOIN ValidAccounts va ON v.lid = va.account_id
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'daily_role_snapshot'
),
latest_state AS (
    -- 第四步：取每个有效角色在所选时间段内的最后等级状态
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY account_id ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
),
user_recharge AS (
    -- 第五步：计算有效用户的累计充值
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
user_tiers AS (
    -- 第六步：结合最终快照等级和累计充值划分档位
    SELECT 
        l.account_id,
        l.role_level,
        COALESCE(r.total_revenue_usd, 0) AS total_revenue_usd,
        CASE 
            WHEN COALESCE(r.total_revenue_usd, 0) = 0 THEN '0.免费用户'
            WHEN r.total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN r.total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN r.total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN r.total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM latest_state l
    LEFT JOIN user_recharge r ON l.account_id = r.account_id
    WHERE l.rn = 1
)

-- 第七步：按照充值档位分组统计
SELECT 
    recharge_tier AS "付费档位",
    COUNT(DISTINCT account_id) AS "该档位总人数",
    ROUND(AVG(CAST(role_level AS DOUBLE)), 0) AS "平均等级",
    APPROX_PERCENTILE(role_level, 0.5) AS "等级中位数",
    MAX(role_level) AS "最高等级",
    MIN(role_level) AS "最低等级",
    SUM(CASE WHEN role_level BETWEEN 1 AND 10 THEN 1 ELSE 0 END) AS "1-10级人数",
    SUM(CASE WHEN role_level BETWEEN 11 AND 20 THEN 1 ELSE 0 END) AS "11-20级人数",
    SUM(CASE WHEN role_level BETWEEN 21 AND 30 THEN 1 ELSE 0 END) AS "21-30级人数",
    SUM(CASE WHEN role_level BETWEEN 31 AND 40 THEN 1 ELSE 0 END) AS "31-40级人数",
    SUM(CASE WHEN role_level BETWEEN 41 AND 50 THEN 1 ELSE 0 END) AS "41-50级人数",
    SUM(CASE WHEN role_level BETWEEN 51 AND 60 THEN 1 ELSE 0 END) AS "51-60级人数",
    SUM(CASE WHEN role_level BETWEEN 61 AND 70 THEN 1 ELSE 0 END) AS "61-70级人数",
    SUM(CASE WHEN role_level BETWEEN 71 AND 80 THEN 1 ELSE 0 END) AS "71-80级人数",
    SUM(CASE WHEN role_level BETWEEN 81 AND 90 THEN 1 ELSE 0 END) AS "81-90级人数",
    SUM(CASE WHEN role_level >= 91 THEN 1 ELSE 0 END) AS "91级以上人数"
FROM user_tiers
GROUP BY 1
ORDER BY 1;
