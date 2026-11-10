/*
================================================================================
项目：蜡笔小新 - 5月8日活跃并于5月9日留存的用户，按首日是否看广告进行分组对比
描述：
  1. 目标队列：5月8日活跃，且在5月9日再次活跃的用户（排除内部及Windows测试账号）。
  2. 分组依据：这批用户在首日（5月8日）是否成功观看了广告（game_ad_impression, status=1）。
  3. 统计指标：
     - 次留（100%，因为已经限制次日必须活跃）
     - 3留（5月10日是否活跃）
     - 首日、次日、第3日在线时长（使用心跳法：事件间隔<120s累加）
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 获取 5月8日 活跃且排除黑名单的用户
D1_Users AS (
    SELECT DISTINCT v."#user_id"
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_date" = '2026-05-08'
      AND ub."#user_id" IS NULL
),

-- 2. 获取 5月9日 活跃的用户
D2_Users AS (
    SELECT DISTINCT v."#user_id"
    FROM ta.v_event_13 v
    WHERE v."$part_date" = '2026-05-09'
),

-- 3. 取交集得到目标队列（首日活跃且次日也活跃）
CohortBase AS (
    SELECT d1."#user_id"
    FROM D1_Users d1
    JOIN D2_Users d2 ON d1."#user_id" = d2."#user_id"
),

-- 3.5 获取 distinct_id 到 user_id 的映射，修复广告表 user_id 不准的问题
Uid_Rid_Mapping AS (
    SELECT DISTINCT "#distinct_id", "#user_id"
    FROM ta.v_event_13
    WHERE "$part_date" >= '2026-01-01'
      AND "$part_event" = 'new_role'
),

-- 4. 判断这批用户在首日（5月8日）是否成功观看了广告（通过 distinct_id 关联）
AdUsers AS (
    SELECT DISTINCT ur."#user_id"
    FROM ta.v_event_13 v
    JOIN Uid_Rid_Mapping ur ON v."#distinct_id" = ur."#distinct_id"
    JOIN CohortBase cb ON ur."#user_id" = cb."#user_id"
    WHERE v."$part_date" = '2026-05-08'
      AND v."$part_event" = 'game_ad_impression'
      AND CAST(v.status AS INTEGER) = 1  -- 成功观看
),

-- 4.5 判断这批用户在首日（5月8日）是否购买了去广告礼包 (102901)
NoAdPackUsers AS (
    SELECT DISTINCT ur."#user_id"
    FROM ta.v_event_13 v
    JOIN Uid_Rid_Mapping ur ON v."#distinct_id" = ur."#distinct_id"
    JOIN CohortBase cb ON ur."#user_id" = cb."#user_id"
    WHERE v."$part_date" = '2026-05-08'
      AND v."$part_event" = 'charge'
      AND v.product_id = 102901
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
),

-- 5. 将用户分组：优先划分出“首日购买去广告礼包”的群体
CohortGrouped AS (
    SELECT 
        cb."#user_id",
        CASE 
            WHEN nap."#user_id" IS NOT NULL THEN '首日购买了去广告礼包'
            WHEN au."#user_id" IS NOT NULL THEN '首日观看了广告' 
            ELSE '首日未看广告' 
        END AS ad_group
    FROM CohortBase cb
    LEFT JOIN NoAdPackUsers nap ON cb."#user_id" = nap."#user_id"
    LEFT JOIN AdUsers au ON cb."#user_id" = au."#user_id"
),

-- 6. 获取 5月10日 (第3日) 活跃的用户，用于算 3留
D3_Users AS (
    SELECT DISTINCT v."#user_id"
    FROM ta.v_event_13 v
    WHERE v."$part_date" = '2026-05-10'
),

-- 7. 使用心跳法计算这批用户在 5月8日、9日、10日 的在线时长
-- (相邻事件差 < 120s 视为连续在线，过滤 app 层级事件)
Gaps AS (
    SELECT
        v."#user_id",
        v."$part_date",
        LEAD(
            to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
        ) OVER (
            PARTITION BY v."#user_id", v."$part_date"
            ORDER BY v."#event_time"
        )
        - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
        AS gap
    FROM ta.v_event_13 v
    JOIN CohortGrouped cg ON v."#user_id" = cg."#user_id"
    WHERE v."$part_date" IN ('2026-05-08', '2026-05-09', '2026-05-10')
      AND v."#event_name" NOT LIKE '%app%' 
),

DurationDaily AS (
    SELECT
        "#user_id",
        "$part_date",
        SUM(CASE WHEN gap IS NOT NULL AND gap < 120 THEN gap ELSE 0 END) / 60.0 AS duration_min
    FROM Gaps
    GROUP BY "#user_id", "$part_date"
),

-- 7.5 获取这批用户前3天（5.8-5.10）的充值金额 (使用 distinct_id 关联 charge)
Revenue3D AS (
    SELECT 
        ur."#user_id",
        SUM(COALESCE(v.pay_amount_usd, 0)) AS rev_usd
    FROM ta.v_event_13 v
    JOIN Uid_Rid_Mapping ur ON v."#distinct_id" = ur."#distinct_id"
    JOIN CohortGrouped cg ON ur."#user_id" = cg."#user_id"
    WHERE v."$part_date" IN ('2026-05-08', '2026-05-09', '2026-05-10')
      AND v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
    GROUP BY ur."#user_id"
),

-- 7.8 获取这批用户前3天分别购买去广告礼包 (102901) 的情况
AdPackPurchases3D AS (
    SELECT 
        ur."#user_id",
        MAX(CASE WHEN v."$part_date" = '2026-05-08' THEN 1 ELSE 0 END) AS bought_d1,
        MAX(CASE WHEN v."$part_date" = '2026-05-09' THEN 1 ELSE 0 END) AS bought_d2,
        MAX(CASE WHEN v."$part_date" = '2026-05-10' THEN 1 ELSE 0 END) AS bought_d3
    FROM ta.v_event_13 v
    JOIN Uid_Rid_Mapping ur ON v."#distinct_id" = ur."#distinct_id"
    JOIN CohortGrouped cg ON ur."#user_id" = cg."#user_id"
    WHERE v."$part_date" IN ('2026-05-08', '2026-05-09', '2026-05-10')
      AND v."$part_event" = 'charge'
      AND v.product_id = 102901
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
    GROUP BY ur."#user_id"
)

-- 8. 最终聚合输出
SELECT 
    cg.ad_group AS "用户群体(首日是否看广告)",
    COUNT(DISTINCT cg."#user_id") AS "首日且次日活跃人数(基数)",
    
    -- 去广告礼包购买人数
    SUM(COALESCE(p.bought_d1, 0)) AS "首日买去广告礼包人数",
    SUM(COALESCE(p.bought_d2, 0)) AS "次日买去广告礼包人数",
    SUM(COALESCE(p.bought_d3, 0)) AS "第3日买去广告礼包人数",
    
    -- 次留（100%）
    '100.00%' AS "次日留存率(固定)",
    
    -- 3留
    COUNT(DISTINCT d3."#user_id") AS "3留人数(5月10日活跃)",
    ROUND(CAST(COUNT(DISTINCT d3."#user_id") AS DOUBLE) / COUNT(DISTINCT cg."#user_id"), 4) AS "3留率",
    
    -- 3日ARPU
    ROUND(SUM(r.rev_usd) / COUNT(DISTINCT cg."#user_id"), 4) AS "3日ARPU(USD)",
    
    -- 在线时长 (基数为当前群体总人数，未上线的按0分钟算，得出的人均更科学)
    ROUND(SUM(CASE WHEN dd."$part_date" = '2026-05-08' THEN dd.duration_min ELSE 0 END) / COUNT(DISTINCT cg."#user_id"), 2) AS "首日人均在线_心跳法(分)",
    ROUND(SUM(CASE WHEN dd."$part_date" = '2026-05-09' THEN dd.duration_min ELSE 0 END) / COUNT(DISTINCT cg."#user_id"), 2) AS "次日人均在线_心跳法(分)",
    ROUND(SUM(CASE WHEN dd."$part_date" = '2026-05-10' THEN dd.duration_min ELSE 0 END) / COUNT(DISTINCT cg."#user_id"), 2) AS "第3日人均在线_心跳法(分)"
    
FROM CohortGrouped cg
LEFT JOIN D3_Users d3 ON cg."#user_id" = d3."#user_id"
LEFT JOIN DurationDaily dd ON cg."#user_id" = dd."#user_id"
LEFT JOIN Revenue3D r ON cg."#user_id" = r."#user_id"
LEFT JOIN AdPackPurchases3D p ON cg."#user_id" = p."#user_id"
GROUP BY cg.ad_group;
