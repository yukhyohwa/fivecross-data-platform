/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 2026-07-01 起 新增与回流(90天)用户 指定活动点券消耗汇总
             - 严格使用 uuid 作为用户唯一标识
================================================================================
*/

WITH 
-------------------------------------------------------
-- 1. 获取所有历史登录活跃，用于计算用户生命周期
-------------------------------------------------------
DailyLogins AS (
    SELECT DISTINCT
        uuid,
        CAST("$part_date" AS DATE) AS log_date
    FROM ta.v_event_12
    WHERE "$part_event" = 'login'
      AND uuid IS NOT NULL
      AND uuid <> ''
),

-------------------------------------------------------
-- 2. 使用窗口函数获取用户首次和上次登录时间
-------------------------------------------------------
UserStatus AS (
    SELECT
        uuid,
        log_date,
        LAG(log_date) OVER (PARTITION BY uuid ORDER BY log_date) AS prev_log_date,
        MIN(log_date) OVER (PARTITION BY uuid) AS first_log_date
    FROM DailyLogins
),

-------------------------------------------------------
-- 3. 确定用户在分析期间 (7月1日及以后) 的初始身份
-------------------------------------------------------
PeriodFirstLogin AS (
    SELECT 
        uuid, 
        MIN(log_date) AS period_first_log_date
    FROM DailyLogins
    WHERE log_date >= DATE '2026-07-01'
    GROUP BY 1
),

PeriodUsers AS (
    SELECT 
        u.uuid,
        u.log_date AS period_first_log_date,
        CASE 
            WHEN u.log_date = u.first_log_date THEN '1_新增用户'
            WHEN u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 90 THEN '2_回流用户(90天)'
            ELSE '3_老用户'
        END AS user_type
    FROM UserStatus u
    JOIN PeriodFirstLogin p 
      ON u.uuid = p.uuid AND u.log_date = p.period_first_log_date
),

-------------------------------------------------------
-- 4. 统计 7月1日 及以后的指定活动点券消耗
-- 资源变化通过 CROSS JOIN UNNEST(a_rst) 取 diff < 0 (点券消耗)
-------------------------------------------------------
PeriodRevenueRaw AS (
    SELECT
        s1.uuid,
        s1."$part_event" AS event_name,
        CAST(s1.activity_id AS BIGINT) AS activity_id,
        CAST(s1.draw_table_id AS BIGINT) AS gacha_id,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_12 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t
    WHERE -- s1."$part_event" <> 'item_use' AND 
      s1."$part_date" >= '2026-07-01'
      AND s1.uuid IS NOT NULL
      AND s1.uuid <> ''
      AND s1.a_rst IS NOT NULL
),

RevenueClassified AS (
    SELECT 
        uuid,
        -- 1. 参加过幸运转盘-新手活动的付费点券数 (10000000)
        SUM(CASE WHEN event_name = 'roulette_buy' AND gacha_id IN (1, 4, 5) 
                  AND item_id = 10000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS beginner_act_rev_1,
                 
        -- 1. 参加过幸运转盘-新手活动的点券数 (19000000)
        SUM(CASE WHEN event_name = 'roulette_buy' AND gacha_id IN (1, 4, 5) 
                  AND item_id = 19000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS beginner_act_rev_2,
        
        -- 2/3. 参加过幸运转盘-限时活动的点券数 (10000000)
        SUM(CASE WHEN event_name = 'roulette_buy' AND gacha_id NOT IN (1, 4, 5) 
                  AND item_id = 10000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS limited_act_rev_1,
                 
        -- 2/3. 参加过幸运转盘-限时活动的点券数 (19000000)
        SUM(CASE WHEN event_name = 'roulette_buy' AND gacha_id NOT IN (1, 4, 5) 
                  AND item_id = 19000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS limited_act_rev_2,
        
        -- 4. 参加过回归活动的点券数 (10000000)
        SUM(CASE WHEN event_name IN ('return_win', 'return_seven_training', 'return_shop_buy', 'return_card_reward') 
                  AND activity_id IN (50000147, 50000146, 50000150, 50000138, 50000144, 50000140, 50000149, 50000148) 
                  AND item_id = 10000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS return_act_rev_1,
                 
        -- 4. 参加过回归活动的点券数 (19000000)
        SUM(CASE WHEN event_name IN ('return_win', 'return_seven_training', 'return_shop_buy', 'return_card_reward') 
                  AND activity_id IN (50000147, 50000146, 50000150, 50000138, 50000144, 50000140, 50000149, 50000148) 
                  AND item_id = 19000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS return_act_rev_2,
                 
        -- 5. 期间总计消耗点券 (10000000)
        SUM(CASE WHEN item_id = 10000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS total_act_rev_1,
                 
        -- 5. 期间总计消耗点券 (19000000)
        SUM(CASE WHEN item_id = 19000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS total_act_rev_2
                 
    FROM PeriodRevenueRaw
    GROUP BY 1
),

-------------------------------------------------------
-- 5. 合并用户身份与付费数据
-------------------------------------------------------
UserDetail AS (
    SELECT
        p.uuid,
        p.user_type,
        COALESCE(r.beginner_act_rev_1, 0.0) AS beginner_act_rev_1,
        COALESCE(r.beginner_act_rev_2, 0.0) AS beginner_act_rev_2,
        COALESCE(r.limited_act_rev_1, 0.0) AS limited_act_rev_1,
        COALESCE(r.limited_act_rev_2, 0.0) AS limited_act_rev_2,
        COALESCE(r.return_act_rev_1, 0.0) AS return_act_rev_1,
        COALESCE(r.return_act_rev_2, 0.0) AS return_act_rev_2,
        COALESCE(r.total_act_rev_1, 0.0) AS total_act_rev_1,
        COALESCE(r.total_act_rev_2, 0.0) AS total_act_rev_2
    FROM PeriodUsers p
    LEFT JOIN RevenueClassified r ON p.uuid = r.uuid
)

-------------------------------------------------------
-- 6. 最终汇总输出 (只保留新增与回流)
-------------------------------------------------------
SELECT
    user_type AS "用户类型",
    COUNT(DISTINCT uuid) AS "期间活跃总人数",
    
    ROUND(SUM(total_act_rev_1), 2) AS "期间总计消耗点券(10000000)",
    ROUND(SUM(total_act_rev_2), 2) AS "期间总计消耗点券(19000000)",
    
    ROUND(SUM(beginner_act_rev_1), 2) AS "参加过幸运转盘-新手活动(10000000)",
    ROUND(SUM(beginner_act_rev_2), 2) AS "参加过幸运转盘-新手活动(19000000)",
    
    ROUND(SUM(limited_act_rev_1), 2) AS "参加过幸运转盘-限时活动(10000000)",
    ROUND(SUM(limited_act_rev_2), 2) AS "参加过幸运转盘-限时活动(19000000)",
    
    ROUND(SUM(return_act_rev_1), 2) AS "参加过回归活动的点券数(10000000)",
    ROUND(SUM(return_act_rev_2), 2) AS "参加过回归活动的点券数(19000000)"
    
FROM UserDetail
WHERE user_type IN ('1_新增用户', '2_回流用户(90天)')
GROUP BY 1
ORDER BY 1;
