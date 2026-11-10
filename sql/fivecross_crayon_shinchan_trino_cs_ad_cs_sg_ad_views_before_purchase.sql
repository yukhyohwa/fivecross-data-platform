/*
================================================================================
项目：蜡笔小新 - 用户购买特定商品前观看广告次数的分布（平均值与中位数）
描述：
  1. 目标：购买过商品 102901 的用户，在他们【首次购买该商品】前，成功观看了多少次广告。
  2. 统计口径：完全基于 #distinct_id 进行关联，避免部分广告日志缺少 user_id 的问题。
  3. 过滤条件：排除充值测试订单(sandbox=FALSE, is_freebuy=FALSE)；广告仅统计 status=1。
================================================================================
*/

-- 1. 获取每个用户第一次购买 102901 的准确时间，并顺便统计他们购买的次数和金额
WITH ProductStats AS (
    SELECT 
        "#distinct_id",
        MIN("#event_time") AS first_purchase_time,
        COUNT(1) AS purchase_count,
        SUM(COALESCE(pay_amount_usd, 0)) AS total_revenue_usd
    FROM ta.v_event_13
    WHERE ${PartDate:date1}
      AND "$part_event" = 'charge'
      AND CAST(product_id AS VARCHAR) = '102901'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    GROUP BY "#distinct_id"
),

-- 1.5 提前过滤出时间范围内的广告日志，利用日期分区优化查询性能
AdLogs AS (
    SELECT 
        "#distinct_id",
        "#event_time",
        status
    FROM ta.v_event_13
    WHERE ${PartDate:date1}
      AND "$part_event" = 'game_ad_impression'
),

-- 2. 统计这些用户在首次购买前看广告的次数（左连接保证没看过的记为 0）
AdViewsBeforePurchase AS (
    SELECT 
        fp."#distinct_id",
        fp.purchase_count,
        fp.total_revenue_usd,
        COUNT(a."#distinct_id") AS ad_view_count
    FROM ProductStats fp
    LEFT JOIN AdLogs a 
        ON fp."#distinct_id" = a."#distinct_id"
        AND CAST(a.status AS INTEGER) = 1  -- 只统计成功观看的
        AND a."#event_time" < fp.first_purchase_time
    GROUP BY fp."#distinct_id", fp.purchase_count, fp.total_revenue_usd
),

-- 3. 按购买前看广告次数进行分组统计
AdViewsGrouped AS (
    SELECT 
        *,
        CASE 
            WHEN ad_view_count = 0 THEN '0次'
            WHEN ad_view_count = 1 THEN '1次'
            WHEN ad_view_count >= 2 AND ad_view_count <= 5 THEN '2-5次'
            WHEN ad_view_count >= 6 AND ad_view_count <= 10 THEN '6-10次'
            ELSE '10次以上'
        END AS ad_view_group,
        CASE 
            WHEN ad_view_count = 0 THEN 0
            WHEN ad_view_count = 1 THEN 1
            WHEN ad_view_count >= 2 AND ad_view_count <= 5 THEN 2
            WHEN ad_view_count >= 6 AND ad_view_count <= 10 THEN 3
            ELSE 4
        END AS group_sort
    FROM AdViewsBeforePurchase
)

SELECT 
    '102901' AS "商品ID",
    ad_view_group AS "购买前看广告次数分布",
    COUNT("#distinct_id") AS "购买人数",
    SUM(purchase_count) AS "购买总次数",
    ROUND(SUM(total_revenue_usd), 2) AS "该组贡献收入(USD)"
FROM AdViewsGrouped
GROUP BY ad_view_group, group_sort
ORDER BY group_sort;
