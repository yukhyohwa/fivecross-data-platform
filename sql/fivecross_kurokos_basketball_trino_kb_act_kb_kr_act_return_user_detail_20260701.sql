/*
================================================================================
Game: Kuroko's Basketball
Region: KR (event_12)
Description: 2026-07-01 起 回流用户明细数据
             - 包含：回流时间、uuid、流失天数、历史第几次回流
             - 包含：限时活动、回归活动的两类点券消耗 (10000000, 19000000)
             - 回流定义：流失 >= 14天即视为一次回流 (用于触发回归活动)
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
-- 2. 使用窗口函数获取用户首次和上次登录时间，计算流失天数
-------------------------------------------------------
UserStatus AS (
    SELECT
        uuid,
        log_date,
        LAG(log_date) OVER (PARTITION BY uuid ORDER BY log_date) AS prev_log_date
    FROM DailyLogins
),

-------------------------------------------------------
-- 3. 找出每个玩家历史上的“第一次满足 >= 14天的流失” (用于判定第一次回流)
-------------------------------------------------------
FirstReturnGap AS (
    SELECT
        uuid,
        MIN(log_date) AS first_14d_gap_date
    FROM UserStatus
    WHERE prev_log_date IS NOT NULL AND DATE_DIFF('day', prev_log_date, log_date) >= 14
    GROUP BY 1
),

-------------------------------------------------------
-- 4. 判定每次登录是否触发回流
-- 逻辑: 第一次回流 >= 14天；第二次及以后 >= 28天
-------------------------------------------------------
UserReturns AS (
    SELECT
        u.uuid,
        u.log_date,
        u.prev_log_date,
        DATE_DIFF('day', u.prev_log_date, u.log_date) AS churn_days,
        CASE 
            -- 如果流失 >= 28天，无条件算作一次回流 (第2次, 第3次...)
            WHEN u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 28 THEN 1 
            -- 如果流失 >= 14天且 < 28天，仅当它是该玩家历史上的【第一个】14天流失时，才算回流
            WHEN u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 14 AND u.log_date = f.first_14d_gap_date THEN 1
            ELSE 0 
        END AS is_return
    FROM UserStatus u
    LEFT JOIN FirstReturnGap f ON u.uuid = f.uuid
),

-------------------------------------------------------
-- 5. 计算历史累计回流次数
-------------------------------------------------------
UserCumulativeReturns AS (
    SELECT 
        uuid,
        log_date,
        prev_log_date,
        churn_days,
        is_return,
        SUM(is_return) OVER (PARTITION BY uuid ORDER BY log_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS return_count
    FROM UserReturns
),

-------------------------------------------------------
-- 6. 筛选 7月1日以后的回流用户 (取期间内首次回流)
-------------------------------------------------------
TargetReturnUsers AS (
    SELECT
        uuid,
        MIN(log_date) AS return_date,
        -- 取出首次回流那天的流失天数和回流次数
        MIN_BY(churn_days, log_date) AS churn_days,
        MIN_BY(return_count, log_date) AS return_count
    FROM UserCumulativeReturns
    WHERE log_date >= DATE '2026-07-01'
      AND is_return = 1
    GROUP BY 1
),

-------------------------------------------------------
-- 7. 统计 7月1日 及以后的指定活动点券消耗
-------------------------------------------------------
PeriodRevenueRaw AS (
    SELECT
        s1.uuid,
        s1."$part_event" AS event_name,
        CAST(s1.activity_id AS BIGINT) AS activity_id,
        CAST(s1.draw_table_id AS BIGINT) AS draw_table_id,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_12 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t
    WHERE s1."$part_event" IN (
            'roulette_buy', 
            'return_win', 
            'return_seven_training', 
            'return_shop_buy', 
            'return_card_reward'
          )
      AND s1."$part_date" >= '2026-07-01'
      AND s1.uuid IS NOT NULL
      AND s1.uuid <> ''
      AND s1.a_rst IS NOT NULL
),

RevenueClassified AS (
    SELECT 
        uuid,
        
        -- 限时活动的点券数 (10000000)
        SUM(CASE WHEN event_name = 'roulette_buy' AND draw_table_id NOT IN (1, 4, 5) 
                  AND item_id = 10000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS limited_act_rev_1,
                 
        -- 限时活动的点券数 (19000000)
        SUM(CASE WHEN event_name = 'roulette_buy' AND draw_table_id NOT IN (1, 4, 5) 
                  AND item_id = 19000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS limited_act_rev_2,
        
        -- 回归活动的点券数 (10000000)
        SUM(CASE WHEN event_name IN ('return_win', 'return_seven_training', 'return_shop_buy', 'return_card_reward') 
                  AND activity_id IN (50000147, 50000146, 50000150, 50000138, 50000144, 50000140, 50000149, 50000148) 
                  AND item_id = 10000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS return_act_rev_1,
                 
        -- 回归活动的点券数 (19000000)
        SUM(CASE WHEN event_name IN ('return_win', 'return_seven_training', 'return_shop_buy', 'return_card_reward') 
                  AND activity_id IN (50000147, 50000146, 50000150, 50000138, 50000144, 50000140, 50000149, 50000148) 
                  AND item_id = 19000000 AND item_diff < 0 
                 THEN ABS(item_diff) ELSE 0 END) AS return_act_rev_2
                 
    FROM PeriodRevenueRaw
    GROUP BY 1
)

-------------------------------------------------------
-- 8. 最终合并输出明细数据
-------------------------------------------------------
SELECT
    CAST(u.return_date AS VARCHAR) AS "回流时间",
    u.uuid AS "uuid",
    u.churn_days AS "距离上次流失的天数",
    u.return_count AS "第几次回流",
    
    COALESCE(r.limited_act_rev_1, 0) AS "参加过幸运转盘-限时活动(10000000)",
    COALESCE(r.limited_act_rev_2, 0) AS "参加过幸运转盘-限时活动(19000000)",
    
    COALESCE(r.return_act_rev_1, 0) AS "参加过回归活动的点券数(10000000)",
    COALESCE(r.return_act_rev_2, 0) AS "参加过回归活动的点券数(19000000)"
    
FROM TargetReturnUsers u
LEFT JOIN RevenueClassified r ON u.uuid = r.uuid
ORDER BY u.return_date, u.uuid;
