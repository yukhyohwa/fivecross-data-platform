/*
================================================================================
项目：蜡笔小新繁体 (TC) - 公会义卖参与及消耗统计
口径：排除 internal_users、is_windows、is_water 三类测试/异常用户
      按日统计公会义卖的点击参与次数、购买参与人/次数及钻石消耗（总量与人均/单笔话费）
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_windows', 'is_water', 'internal_users')
)

SELECT 
    "$part_date",
    COUNT(CASE WHEN "$part_event" IN ('charity_sale_click') THEN "#account_id" END) AS click_users,
    COUNT(CASE WHEN "$part_event" IN ('charity_sale_purchase') THEN "#account_id" END) AS buy_users,
    SUM(CASE WHEN "$part_event" IN ('charity_sale_purchase') THEN CAST(current_price AS INTEGER) END) AS total_diamonds,
    ROUND(AVG(CASE WHEN "$part_event" IN ('charity_sale_purchase') THEN CAST(current_price AS INTEGER) END), 0) AS avg_diamonds
FROM ta.v_event_18 v
LEFT JOIN UserBlacklist s6 
    ON v."#user_id" = s6."#user_id"
WHERE ${PartDate:date1} 
    AND "$part_event" IN ('charity_sale_click', 'charity_sale_purchase')
    AND s6."#user_id" IS NULL
GROUP BY 1
ORDER BY 1;
