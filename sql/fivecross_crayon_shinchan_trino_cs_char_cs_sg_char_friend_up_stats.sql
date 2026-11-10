/*
================================================================================
Game    : Crayon Shin-chan (蜡笔小新)
Region  : SG (新加坡)
Query   : 玩家技能/伙伴 (friend) 拥有及等级分布统计 (仅限新加坡用户，按付费档位拆分)
Table   : ta.v_event_13, ta_dim.dim_13_0_37979
================================================================================
*/

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
    -- 仅筛选新加坡用户
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country' AND tag_value = '新加坡'
),

UserBlacklist AS (
    -- 黑名单用户（排除Windows等测试沙盒设备）
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

ValidAccounts AS (
    -- 过滤出新加坡且非黑名单的有效账户
    SELECT a.account_id
    FROM AccountToUser a
    INNER JOIN SingaporeUsers su ON a.user_id = su.user_id
    LEFT JOIN UserBlacklist ub ON a.user_id = ub.user_id
    WHERE ub.user_id IS NULL
),

user_recharge AS (
    -- 计算有效用户的累计充值金额（排除沙盒充值与免费充值）
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
    -- 对有效账户划分充值档位
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
    -- 提取每日快照中玩家的技能/伙伴数据
    SELECT 
        v."$part_date",
        va.recharge_tier,
        v.lid AS role_id,
        v."#event_time",
        t.pet_id AS friend_id,              
        CAST(t.level AS BIGINT) AS friend_lv
    FROM ta.v_event_13 v
    INNER JOIN ValidAccountsWithTier va ON v.lid = va.account_id
    CROSS JOIN UNNEST(v.friend) AS t -- (u_power, u_pet_id, u_level, u_equip, u_role_id, u_pos, u_attr_vals)
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'daily_role_snapshot'
),

latest_state AS (
    -- 获取玩家每天每个技能/伙伴的最末状态
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY "$part_date", role_id, friend_id ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
)

-- 结合维表计算各付费档位下的技能拥有人数和平均等级
SELECT 
    ls."$part_date" AS "日期",
    ls.recharge_tier AS "付费档位",
    ls.friend_id AS "技能ID",
    df."friend.role_id@friend_name"  AS "技能名称",
    df."friend.role_id@quality"  AS "技能品质ID",
    df."friend.role_id@quality_name"  AS "技能品质名称",
    COUNT(DISTINCT ls.role_id) AS "拥有人数",
    ROUND(AVG(CAST(ls.friend_lv AS DOUBLE)), 2) AS "平均等级"
FROM latest_state ls
LEFT JOIN ta_dim.dim_13_0_37979 df ON CAST(ls.friend_id AS INTEGER) = CAST(df."friend.role_id@friend_id" AS INTEGER) 
WHERE ls.rn = 1
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1 DESC, 2, 5, 7 DESC;
