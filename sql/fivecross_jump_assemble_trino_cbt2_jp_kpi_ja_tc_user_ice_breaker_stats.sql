/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 破冰用户 (首付用户) 核心统计报表 (首付留存, 档位分布, 转化)
             1. 破冰定义：用户历史上第一笔充值发生的日期。
             2. 统计破冰当天的充值金额分布、后续留存 (D1, D3, D7)。
             3. 排除内部测试账号。
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. [扫描配置] 确定统计的目标时间范围
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 内部用户名单 (黑名单)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users')
),

-- 3. [用户属性] 获取商店、渠道、国家、系统等基本信息
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store 
    FROM user_result_cluster_16 
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store')
    GROUP BY "#varchar_id"
),

-- 4. [活跃序列] 提取活跃日期，用于后续计算破冰用户的留存
UserActivity AS (
    SELECT 
        v."#account_id", 
        CAST(v."$part_date" AS DATE) AS activity_date
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v."$part_date" >= '2024-01-01' -- 确保包含观察期
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND ub."#account_id" IS NULL
    GROUP BY 1, 2
),

-- 5. [首付判定] 寻找每个用户历史上的第一笔充值
FirstPurchaseEver AS (
    SELECT 
        "#account_id", 
        MIN(CAST("$part_date" AS DATE)) AS first_pay_date
    FROM ta.v_event_16
    WHERE "$part_event" = 'PURCHASE'
    AND payload.validationtype <>'SANDBOX_RECEIPT'
    GROUP BY 1
),

-- 6. [破冰详情] 提取指定周期内的破冰用户及其首付金额 (USD)
IceBreakerDetail AS (
    SELECT 
        v."#account_id",
        fp.first_pay_date,
        -- 计算破冰当天的净收入 (USD)
        SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1)) AS first_day_revenue_usd
    FROM ta.v_event_16 v
    INNER JOIN FirstPurchaseEver fp ON v."#account_id" = fp."#account_id" AND CAST(v."$part_date" AS DATE) = fp.first_pay_date
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    WHERE CAST(v."$part_date" AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
      AND v."$part_event" = 'PURCHASE'
      AND payload.validationtype <>'SANDBOX_RECEIPT'
      AND ub."#account_id" IS NULL
    GROUP BY 1, 2
),

-- 7. [破冰留存] 破冰用户在首付后的活跃情况 (D1, D3, D7)
IceBreakerRetention AS (
    SELECT 
        ib."#account_id",
        ib.first_pay_date,
        MAX(CASE WHEN ua.activity_date = DATE_ADD('day', 1, ib.first_pay_date) THEN 1 ELSE 0 END) AS is_ret_1,
        MAX(CASE WHEN ua.activity_date = DATE_ADD('day', 3, ib.first_pay_date) THEN 1 ELSE 0 END) AS is_ret_3,
        MAX(CASE WHEN ua.activity_date = DATE_ADD('day', 7, ib.first_pay_date) THEN 1 ELSE 0 END) AS is_ret_7
    FROM IceBreakerDetail ib
    LEFT JOIN UserActivity ua ON ib."#account_id" = ua."#account_id"
    GROUP BY 1, 2
),

-- 8. [档位划分] 对破冰金额进行分档 (USD)
IceBreakerTier AS (
    SELECT 
        *,
        CASE 
            WHEN first_day_revenue_usd <= 1 THEN 'a.(0,1]'
            WHEN first_day_revenue_usd <= 10 THEN 'b.(1,10]'
            WHEN first_day_revenue_usd <= 50 THEN 'c.(10,50]'
            WHEN first_day_revenue_usd <= 100 THEN 'd.(50,100]'
            WHEN first_day_revenue_usd <= 500 THEN 'e.(100,500]'
            ELSE 'f.(500,∞]'
        END AS recharge_tier
    FROM IceBreakerDetail
),

-- 9. [归因汇总] 多维度聚合
FinalAggregation AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', ib.first_pay_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', ib.first_pay_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', ib.first_pay_date) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN up.fixed_os ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN up.fixed_country ELSE '已合并' END AS country, 
        CASE WHEN ${Selector:affcode} THEN up.fixed_affcode ELSE '已合并' END AS affcode,
        CASE WHEN ${Selector:store} THEN up.fixed_store ELSE '已合并' END AS store,
        
        COUNT(DISTINCT ib."#account_id") AS ib_pu,
        SUM(ib.first_day_revenue_usd) AS ib_revenue_usd,
        SUM(ib.first_day_revenue_usd) / NULLIF(COUNT(DISTINCT ib."#account_id"), 0) AS ib_arppu,
        
        -- 档位分布
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'a.(0,1]' THEN ib."#account_id" END) AS "tier_0_1",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'b.(1,10]' THEN ib."#account_id" END) AS "tier_1_10",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'c.(10,50]' THEN ib."#account_id" END) AS "tier_10_50",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'd.(50,100]' THEN ib."#account_id" END) AS "tier_50_100",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'e.(100,500]' THEN ib."#account_id" END) AS "tier_100_500",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'f.(500,∞]' THEN ib."#account_id" END) AS "tier_500_plus",

        -- 留存指标
        CAST(SUM(ret.is_ret_1) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#account_id"), 0) AS rr_1,
        CAST(SUM(ret.is_ret_3) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#account_id"), 0) AS rr_3,
        CAST(SUM(ret.is_ret_7) AS DOUBLE) / NULLIF(COUNT(DISTINCT ib."#account_id"), 0) AS rr_7
        
    FROM IceBreakerTier ib
    LEFT JOIN UserProfileDetail up ON ib."#account_id" = up."#account_id"
    LEFT JOIN IceBreakerRetention ret ON ib."#account_id" = ret."#account_id" AND ib.first_pay_date = ret.first_pay_date
    GROUP BY 1, 2, 3, 4, 5
)

SELECT 
    time_dimension AS "时间维度",
    os_type AS "系统类型",
    country AS "国家",
    affcode AS "渠道码",
    store AS "商店",
    ib_pu AS "破冰人数",
    ROUND(ib_revenue_usd, 2) AS "破冰总金额(USD)",
    ROUND(ib_arppu, 2) AS "破冰ARPPU",
    "tier_0_1" AS "(0,1]人数",
    "tier_1_10" AS "(1,10]人数",
    "tier_10_50" AS "(10,50]人数",
    "tier_50_100" AS "(50,100]人数",
    "tier_100_500" AS "(100,500]人数",
    "tier_500_plus" AS "(500,∞]人数",
    CAST(ROUND(rr_1 * 100, 2) AS VARCHAR) || '%' AS "破冰次留",
    CAST(ROUND(rr_3 * 100, 2) AS VARCHAR) || '%' AS "破冰3留",
    CAST(ROUND(rr_7 * 100, 2) AS VARCHAR) || '%' AS "破冰7留",
    CAST(ROUND((1 - rr_7) * 100, 2) AS VARCHAR) || '%' AS "破冰7日流失率"
FROM FinalAggregation 
ORDER BY 1 DESC;
