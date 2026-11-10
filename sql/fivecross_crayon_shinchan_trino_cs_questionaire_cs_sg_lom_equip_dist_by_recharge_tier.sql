WITH AccountToUser AS (
    -- 建立 account_id 到 user_id 的映射
    SELECT 
        "#account_id" AS account_id, 
        MAX("#user_id") AS user_id
    FROM ta.v_event_13
    WHERE "$part_event" IN ('login', 'new_role')
      AND "#user_id" IS NOT NULL
      AND "#account_id" IS NOT NULL
      -- 为了确保能获取到所有人的映射，这里不限制日期，或者您可以自行加上 "$part_date" >= '2024-01-01' 等范围限制
    GROUP BY 1
),
UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),
SingaporeUsers AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country' AND tag_value = '新加坡'
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
EquipLogs AS (
    -- 提取每个角色在所选时间段内的最新装备状态
    SELECT 
        account_id,
        recharge_tier,
        equip_location AS equip_type,
        CAST(equip_lv AS BIGINT) AS equip_lv
    FROM (
        SELECT 
            v.lid AS account_id,
            va.recharge_tier,
            t.equip_lv AS equip_lv,
            t.location AS equip_location,
            -- 不按日切分，直接取整个时间段最后一条快照的该部位装备记录
            ROW_NUMBER() OVER(PARTITION BY v.lid, t.location ORDER BY v."#event_time" DESC) AS rank
        FROM ta.v_event_13 v
        INNER JOIN ValidAccountsWithTier va ON v.lid = va.account_id
        CROSS JOIN UNNEST(v.equip) AS t
        WHERE v.${PartDate:date1} 
          AND v."$part_event" = 'daily_role_snapshot'
    )
    WHERE rank = 1
)

SELECT 
    recharge_tier AS "付费档位",
    equip_type AS "道具部位(1-10)",
    COUNT(DISTINCT account_id) AS "该部位持有总人数",
    ROUND(AVG(CAST(equip_lv AS DOUBLE)),1) AS "平均等级",
    APPROX_PERCENTILE(equip_lv, 0.5) AS "等级中位数",
    MAX(equip_lv) AS "最高等级",
    -- MIN(equip_lv) AS "最低等级",
    SUM(CASE WHEN equip_lv BETWEEN 1 AND 15 THEN 1 ELSE 0 END) AS "1-15级人数",
    SUM(CASE WHEN equip_lv BETWEEN 16 AND 30 THEN 1 ELSE 0 END) AS "16-30级人数",
    SUM(CASE WHEN equip_lv BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS "31-60级人数",
    SUM(CASE WHEN equip_lv BETWEEN 61 AND 90 THEN 1 ELSE 0 END) AS "61-90级人数",
    SUM(CASE WHEN equip_lv >= 91 THEN 1 ELSE 0 END) AS "91级以上人数"
FROM EquipLogs
WHERE equip_type IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;
