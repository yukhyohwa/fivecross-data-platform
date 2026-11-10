/*
================================================================================
Game: Crayon Shin-chan (蜡笔小新) - SG/Global (Event 13)
Description: Ice-Breaker Tier & Retention Distribution.
             Categorizes users by their first-ever purchase amount (USD) into tiers.
             Tracks their subsequent retention (1, 3, 7 days) and churn rates.
             Includes custom attribution logic and excludes Windows users.
Environment: Trino
Table: ta.v_event_13
================================================================================
*/

WITH
-- 1. 黑名单用户
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

-- 1.5 [扫描配置] 确定统计的目标时间范围
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_13
    WHERE ${PartDate:date1} AND "$part_event" IN ('new_role', 'login')
),

-- 2. 用户归属信息 (整合 ta_app_start 逻辑)
UserAttribution AS (
    SELECT 
        "#user_id",
        "#os" AS os_type,
        country_name,
        ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time" DESC) as rank
    FROM (
        SELECT 
            "#user_id", 
            "#os",
            "#event_time",
            CASE 
                WHEN "#country_code" IN ('HK', 'MO', 'TW') THEN "#province"
                WHEN "#country_code" = 'CN' THEN '中国大陆'
                ELSE "#country" 
            END AS country_name
        FROM ta.v_event_13
        WHERE "$part_date" >= '2025-11-24'
          AND "$part_event" = 'ta_app_start'
    )
),

UserAttributionFinal AS (
    SELECT "#user_id", os_type, country_name
    FROM UserAttribution
    WHERE rank = 1
),

-- 3. [用户活跃] 提取所有活跃日期，用于后续计算破冰用户的留存
UserActivity AS (
    SELECT 
        "#user_id", 
        CAST("$part_date" AS DATE) AS activity_date
    FROM ta.v_event_13
    WHERE "$part_date" >= '2025-11-24'
      AND "$part_event" IN ('new_role', 'login')
    GROUP BY 1, 2
),

-- 4. [首付判定] 寻找每个用户历史上的第一笔充值 (排除沙盒)
FirstPurchaseEver AS (
    SELECT 
        "#user_id", 
        MIN(CAST("$part_date" AS DATE)) AS first_pay_date
    FROM ta.v_event_13
    WHERE "$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    GROUP BY 1
),

-- 5. [破冰详情] 提取指定周期内的破冰用户及其充值数据
IceBreakerDetail AS (
    SELECT 
        v."#user_id",
        fp.first_pay_date,
        -- 计算破冰当天的总收入 (USD)
        SUM(v.pay_amount_usd) AS first_day_revenue_usd
    FROM ta.v_event_13 v
    INNER JOIN FirstPurchaseEver fp ON v."#user_id" = fp."#user_id" AND CAST(v."$part_date" AS DATE) = fp.first_pay_date
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE CAST(v."$part_date" AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
      AND v."$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
      AND ub."#user_id" IS NULL
    GROUP BY 1, 2
),

-- 6. [破冰留存] 破冰用户在破冰后的活跃情况
IceBreakerRetention AS (
    SELECT 
        ib."#user_id",
        ib.first_pay_date,
        COUNT_IF(ua.activity_date = DATE_ADD('day', 1, ib.first_pay_date)) AS is_ret_1,
        COUNT_IF(ua.activity_date = DATE_ADD('day', 3, ib.first_pay_date)) AS is_ret_3,
        COUNT_IF(ua.activity_date = DATE_ADD('day', 7, ib.first_pay_date)) AS is_ret_7
    FROM IceBreakerDetail ib
    LEFT JOIN UserActivity ua ON ib."#user_id" = ua."#user_id"
    GROUP BY 1, 2
),

-- 7. [档位划分] 将破冰金额划分为 USD 常用档位
IceBreakerTier AS (
    SELECT 
        *,
        CASE 
            WHEN first_day_revenue_usd <= 0.99 THEN 'a.(0, 0.99]'
            WHEN first_day_revenue_usd <= 4.99 THEN 'b.(0.99, 4.99]'
            WHEN first_day_revenue_usd <= 9.99 THEN 'c.(4.99, 9.99]'
            WHEN first_day_revenue_usd <= 19.99 THEN 'd.(9.99, 19.99]'
            WHEN first_day_revenue_usd <= 49.99 THEN 'e.(19.99, 49.99]'
            WHEN first_day_revenue_usd <= 99.99 THEN 'f.(49.99, 99.99]'
            ELSE 'g.(99.99, ∞]'
        END AS recharge_tier
    FROM IceBreakerDetail
),

-- 8. [归因汇总] 结合 Selector 参数进行多维度聚合
FinalAggregation AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', ib.first_pay_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', ib.first_pay_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', ib.first_pay_date) AS VARCHAR)
            ELSE '已合并'
        END AS "时间维度",
        CASE WHEN ${Selector:ostype} THEN ua.os_type ELSE '已合并' END AS "系统类型",
        CASE WHEN ${Selector:country} THEN ua.country_name ELSE '已合并' END AS "国家", 
        
        COUNT(DISTINCT ib."#user_id") AS "破冰人数",
        SUM(ib.first_day_revenue_usd) AS "破冰总金额_USD",
        SUM(ib.first_day_revenue_usd) / NULLIF(COUNT(DISTINCT ib."#user_id"), 0) AS "破冰ARPU",
        
        -- 档位分布
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'a.(0, 0.99]' THEN ib."#user_id" END) AS "0.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'b.(0.99, 4.99]' THEN ib."#user_id" END) AS "4.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'c.(4.99, 9.99]' THEN ib."#user_id" END) AS "9.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'd.(9.99, 19.99]' THEN ib."#user_id" END) AS "19.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'e.(19.99, 49.99]' THEN ib."#user_id" END) AS "49.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'f.(49.99, 99.99]' THEN ib."#user_id" END) AS "99.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'g.(99.99, ∞]' THEN ib."#user_id" END) AS "100+档人数",

        -- 留存/流失
        CAST(SUM(ret.is_ret_1) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#user_id"), 0) AS "破冰次留",
        CAST(SUM(ret.is_ret_3) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#user_id"), 0) AS "破冰3留",
        CAST(SUM(ret.is_ret_7) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#user_id"), 0) AS "破冰7留",
        1 - (CAST(SUM(ret.is_ret_7) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#user_id"), 0)) AS "破冰7日流失率"
        
    FROM IceBreakerTier ib
    LEFT JOIN UserAttributionFinal ua ON ib."#user_id" = ua."#user_id"
    LEFT JOIN IceBreakerRetention ret ON ib."#user_id" = ret."#user_id" AND ib.first_pay_date = ret.first_pay_date
    GROUP BY 1, 2, 3
)

SELECT * FROM FinalAggregation ORDER BY 1 DESC;
