/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: JP (Japan)
Description: 黑子JP NBA联动 (雷阿伦 Ray Allen) 相关道具点券消耗精准统计
             通过【原子事务脉冲 (Atomic Transaction Pulse)】技术关联点券消耗与道具产出：
             1. 关联同一用户、同一秒、同一事件下的资源变动。
             2. 区分直接点券抽取（基于集字卡或直接券产出）与商店购券。
             3. 自动识别混合礼包，防止归类偏离。
时间范围：2026-04-22 ~ 2026-05-20
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 0: 黑名单过滤
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 1: 提取原始变动 (识别点券、钻石及目标道具)
--------------------------------------------------------------------------------
AllChanges AS (
    SELECT 
        s1."$part_date" AS part_date,
        s1."#user_id" AS user_id,
        s1."#event_time" AS event_time,
        s1."#event_name" AS event_name,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_9 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t("diff", "key", "after", "before", "id")
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" BETWEEN '2026-04-22' AND '2026-05-20'
        AND s1.a_rst IS NOT NULL
        AND b."#user_id" IS NULL
),

--------------------------------------------------------------------------------
-- Section 2: 原子脉冲合并 (按 用户+秒+事件名 聚合)
-- 只有在同一刻产出了目标道具，且发生了点券/钻石扣除的记录才会被计入
--------------------------------------------------------------------------------
TransactionPulse AS (
    SELECT
        part_date,
        user_id,
        event_time,
        MAX(event_name) AS event_name,
        -- 点券消耗 (ID: 10000000, 19000000)
        SUM(CASE WHEN item_id IN (10000000, 19000000) AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS stamps_spent,
        -- 钻石/宣誓币消耗 (ID: 10000003)
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent,
        
        -- 各目标道具产出标记 (Binary)
        MAX(CASE WHEN item_id = 3010510 AND item_diff > 0 THEN 1 ELSE 0 END) AS f1, -- 雷阿伦球员扭蛋券
        MAX(CASE WHEN item_id = 3010513 AND item_diff > 0 THEN 1 ELSE 0 END) AS f2, -- 雷阿伦皮肤扭蛋券
        MAX(CASE WHEN item_id = 3010512 AND item_diff > 0 THEN 1 ELSE 0 END) AS f3, -- 雷阿伦觉醒扭蛋券
        MAX(CASE WHEN item_id = 3010511 AND item_diff > 0 THEN 1 ELSE 0 END) AS f4, -- 雷阿伦特训卡扭蛋券
        MAX(CASE WHEN item_id = 3010524 AND item_diff > 0 THEN 1 ELSE 0 END) AS f5, -- 集字卡 (代表直接抽取行为)
        MAX(CASE WHEN item_id = 1100812 AND item_diff > 0 THEN 1 ELSE 0 END) AS f6, -- 雷阿伦特性精選福袋
        MAX(CASE WHEN item_id = 1100816 AND item_diff > 0 THEN 1 ELSE 0 END) AS f7, -- 双重扭蛋礼包
        MAX(CASE WHEN item_id = 3010519 AND item_diff > 0 THEN 1 ELSE 0 END) AS f8  -- 幸运奇迹扭蛋券
    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        -- 必须包含至少一种目标道具的获取
        MAX(CASE WHEN item_id IN (3010510, 3010513, 3010512, 3010511, 3010524, 1100812, 1100816, 3010519) AND item_diff > 0 THEN 1 ELSE 0 END) = 1
        -- 且必须有实际的货币消耗 (排除免费领取的奖励)
        AND SUM(CASE WHEN item_id IN (10000000, 19000000, 10000003) AND item_diff < 0 THEN 1 ELSE 0 END) > 0
    )
),

--------------------------------------------------------------------------------
-- Section 3: 消耗归类逻辑
--------------------------------------------------------------------------------
ClassifiedSpend AS (
    SELECT
        part_date,
        user_id,
        event_name,
        stamps_spent,
        diamonds_spent,
        CASE 
            WHEN f7 = 1 THEN '双重扭蛋礼包 (1100816)'
            WHEN f6 = 1 THEN '雷阿伦特性精選福袋 (1100812)'
            WHEN f8 = 1 THEN '幸运奇迹扭蛋券 (3010519)'
            WHEN f1 = 1 THEN '雷阿伦球员扭蛋券 (3010510)'
            WHEN f2 = 1 THEN '雷阿伦皮肤扭蛋券 (3010513)'
            WHEN f3 = 1 THEN '雷阿伦觉醒扭蛋券 (3010512)'
            WHEN f4 = 1 THEN '雷阿伦特训卡扭蛋券 (3010511)'
            -- 集字卡 (3010524) 产出通常意味着玩家直接消耗货币进行扭蛋(roulette_buy)，而非先买票。
            WHEN f5 = 1 THEN '集字卡/雷阿伦扭蛋直抽消耗 (3010524)'
            ELSE '其他联动相关消耗'
        END AS target_category
    FROM TransactionPulse
)

--------------------------------------------------------------------------------
-- Section 4: 最终聚合汇总
--------------------------------------------------------------------------------
SELECT
    part_date AS "日期",
    target_category AS "消费目标 (道具/行为)",
    event_name AS "底层事件",
    COUNT(DISTINCT user_id) AS "参与人数",
    COUNT(DISTINCT CASE WHEN stamps_spent > 0 THEN user_id END) AS "消耗点券参与人数",
    SUM(stamps_spent) AS "消耗点券",
    COUNT(DISTINCT CASE WHEN diamonds_spent > 0 THEN user_id END) AS "消耗钻石参与人数",
    SUM(diamonds_spent) AS "消耗钻石"
FROM ClassifiedSpend
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 4 DESC;
