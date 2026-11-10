/*
================================================================================
项目：蜡笔小新 - 首充转化商品分布 (Ice-Breaker Product Analysis)
描述：统计用户历史上“第一笔”订单购买的礼包分布，用于分析哪些礼包是高效的“破冰”诱饵。
维度：时间周期、商品名称、商品分类、首充人数、首充收入
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 提取用户历史上的第一笔订单记录
AllUserFirstCharge AS (
    SELECT 
        "#user_id",
        product_id,
        pay_amount_usd,
        "$part_date",
        "#event_time" AS event_time,
        "role_lev" role_lev,
        ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time" ASC) as charge_rank
    FROM ta.v_event_13
    WHERE "$part_event" = 'charge'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
),

-- 2. 锁定目标周期内的破冰动作
TargetFirstCharge AS (
    SELECT 
        fc.*
    FROM AllUserFirstCharge fc
    LEFT JOIN UserBlacklist ub ON fc."#user_id" = ub."#user_id"
    WHERE fc.charge_rank = 1 -- 只要历史上第一笔
      AND ub."#user_id" IS NULL
      AND ${PartDate:date1} -- 过滤破冰日期在目标范围内的用户
)

-- 3. 关联商品维表并聚合汇总
SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(t."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(t."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(t."$part_date" AS DATE)) AS VARCHAR)
        ELSE '已合并'
    END AS "时间维度",
    dp."product_id@product_name_tc" AS "商品名称",
    dp."product_id@product_type" AS "商品类型",
    t.product_id AS "商品ID",
    COUNT(DISTINCT t."#user_id") AS "首充人数",
    SUM(t.pay_amount_usd) AS "首充总收入(USD)",
    SUM(t.pay_amount_usd) / NULLIF(COUNT(DISTINCT t."#user_id"), 0) AS "首充客单价",
    AVG(t.role_lev) AS "平均等级",
    APPROX_PERCENTILE(t.role_lev, 0.5) AS "等级中位数"
FROM TargetFirstCharge t
LEFT JOIN ta_dim.dim_13_0_20639 dp ON CAST(t.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER)
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 5 DESC;
