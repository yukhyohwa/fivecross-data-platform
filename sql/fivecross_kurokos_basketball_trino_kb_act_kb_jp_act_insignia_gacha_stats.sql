/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 黑子JP 每日徽章扭蛋消耗统计 (支持点券+宣誓币)
             1. 购买：点券/宣誓币减少且同一原子操作(秒)内获得扭蛋券 (30002704)
             2. 直抽：点券/宣誓币减少且发生在核心扭蛋事件中
             优化：支持 10000003 钻石(宣誓币) 统计，严格区分不同货币类型的参与用户与消耗。
时间：2026/2/4 ~ 今
Author: Antigravity
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 0: 黑名单过滤 (Blacklist)
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 1: 提取原始变动 (Extracting Changes)
--------------------------------------------------------------------------------
AllChanges AS (
    SELECT 
        s1."$part_date" AS part_date,
        s1."#user_id" AS user_id,
        s1."#event_time" AS event_time,
        s1."#event_name" AS event_name,
        -- JP a_rst order: diff, key, after, before, id
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_9 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t("diff", "key", "after", "before", "id")
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" >= '2026-02-04'
        AND s1.a_rst IS NOT NULL
        AND b."#user_id" IS NULL
),

--------------------------------------------------------------------------------
-- Section 2: 原子脉冲合并 (Transaction Pulse Consolidation)
-- 将同一秒内的变动合成一个整体，以此解决多事件重复上报同一笔消耗的问题
--------------------------------------------------------------------------------
TransactionPulse AS (
    SELECT
        part_date,
        user_id,
        event_time, 
        -- 该原子时间点内消耗的总点券 (仅 10000000, 19000000)
        SUM(CASE WHEN item_id IN (10000000, 19000000) AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS points_spent,
        -- 该原子时间点内消耗的钻石 (10000003)
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent,
        -- 该原子时间点内获得的扭蛋券总量
        SUM(CASE WHEN item_id = 30002704 AND item_diff > 0 THEN item_diff ELSE 0 END) AS tickets_gained,
        -- 该原子时间点内是否涉及任何徽章扭蛋的核心事件 'badge_collect_reward'；'roulette_buy' 各种gacha，包含徽章
        MAX(CASE WHEN event_name IN ('badge_collect_reward') THEN 1 ELSE 0 END) AS is_gacha_event
    FROM AllChanges
    GROUP BY 1, 2, 3
),

--------------------------------------------------------------------------------
-- Section 3: 行为精准判定 (Action Classification)
--------------------------------------------------------------------------------
ClassifiedPulse AS (
    SELECT
        part_date,
        user_id,
        -- 判定该原子变动是否属于扭蛋行为（购券或核心gacha事件）
        CASE WHEN tickets_gained > 0 OR is_gacha_event = 1 THEN points_spent ELSE 0 END AS p_spent,
        CASE WHEN tickets_gained > 0 OR is_gacha_event = 1 THEN diamonds_spent ELSE 0 END AS d_spent
    FROM TransactionPulse
    WHERE (tickets_gained > 0 OR is_gacha_event = 1)
      AND (points_spent > 0 OR diamonds_spent > 0)
)

--------------------------------------------------------------------------------
-- Section 4: 最终聚合汇总 (Final Daily Aggregation)
--------------------------------------------------------------------------------
SELECT
    part_date AS "日期",
    -- 总参与人数：使用点券或宣誓币的去重用户数
    COUNT(DISTINCT user_id) AS "参与人数（总）",
    COUNT(DISTINCT CASE WHEN p_spent > 0 THEN user_id END) AS "参与人数（用点券）",
    SUM(p_spent) AS "消耗点券",
    COUNT(DISTINCT CASE WHEN d_spent > 0 THEN user_id END) AS "参与人数（用钻石）",
    SUM(d_spent) AS "消耗钻石"
FROM ClassifiedPulse
GROUP BY 1
ORDER BY 1;
