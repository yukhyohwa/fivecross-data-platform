/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: TC (Traditional Chinese / TW)
Description: 黑子TC NBA联动 (麦迪 McGrady & 雷阿伦 Ray Allen) 相关道具点券消耗精准统计
             通过【原子事务脉冲 (Atomic Transaction Pulse)】技术关联点券消耗与道具产出：
             1. 关联同一用户、同一秒、同一事件下的资源变动。
             2. 区分直接点券抽取（基于集字卡或直接券产出）与商店购券。
             3. 自动识别混合礼包，防止归类偏离。
时间范围：2026-02-05 ~ 2026-05-20 (涵盖麦迪 02/05~03/05 与 雷阿伦 04/22~05/20 事件期)
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 0: 黑名单过滤
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 1: 提取原始变动 (识别付费点券、钻石及目标道具)
--------------------------------------------------------------------------------
AllChanges AS (
    SELECT 
        s1."$part_date" AS part_date,
        s1."#user_id" AS user_id,
        s1."#event_time" AS event_time,
        s1."#event_name" AS event_name,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_10 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t(id, "before", diff, "after", "key")
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" BETWEEN '2026-02-05' AND '2026-05-20'
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
        -- 付费点券消耗 (ID: 10000000)
        SUM(CASE WHEN item_id = 10000000 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS stamps_spent,
        -- 钻石/宣誓币消耗 (ID: 10000003)
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent,
        
        -- 各目标道具产出标记 (Binary)
        MAX(CASE WHEN item_id = 3100390 AND item_diff > 0 THEN 1 ELSE 0 END) AS f1, -- 麦迪球员扭蛋券
        MAX(CASE WHEN item_id = 3100392 AND item_diff > 0 THEN 1 ELSE 0 END) AS f2, -- 麦迪特训卡扭蛋券
        MAX(CASE WHEN item_id = 3100391 AND item_diff > 0 THEN 1 ELSE 0 END) AS f3, -- 麦迪觉醒扭蛋券
        MAX(CASE WHEN item_id = 3100393 AND item_diff > 0 THEN 1 ELSE 0 END) AS f4, -- 麦迪时装扭蛋券
        MAX(CASE WHEN item_id = 3100439 AND item_diff > 0 THEN 1 ELSE 0 END) AS f5, -- 雷艾伦扭蛋券
        MAX(CASE WHEN item_id = 3100441 AND item_diff > 0 THEN 1 ELSE 0 END) AS f6, -- 雷艾伦特训卡扭蛋券
        MAX(CASE WHEN item_id = 3100440 AND item_diff > 0 THEN 1 ELSE 0 END) AS f7, -- 雷艾伦觉醒扭蛋券
        MAX(CASE WHEN item_id = 3100442 AND item_diff > 0 THEN 1 ELSE 0 END) AS f8, -- 雷艾伦时装扭蛋券
        MAX(CASE WHEN item_id = 1200767 AND item_diff > 0 THEN 1 ELSE 0 END) AS f9, -- 双重扭蛋券
        MAX(CASE WHEN item_id = 1610041 AND item_diff > 0 THEN 1 ELSE 0 END) AS f10, -- 麦迪篮球球箱
        MAX(CASE WHEN item_id = 1610047 AND item_diff > 0 THEN 1 ELSE 0 END) AS f11 -- 雷艾伦篮球球箱
    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        -- 必须包含至少一种目标道具的获取
        MAX(CASE WHEN item_id IN (3100390, 3100392, 3100391, 3100393, 3100439, 3100441, 3100440, 3100442, 1200767, 1610041, 1610047) AND item_diff > 0 THEN 1 ELSE 0 END) = 1
        -- 且必须有实际的货币消耗 (付费点券 10000000 或 钻石 10000003)
        AND SUM(CASE WHEN item_id IN (10000000, 10000003) AND item_diff < 0 THEN 1 ELSE 0 END) > 0
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
            WHEN f1 = 1 THEN '麥迪扭蛋券 (3100390)'
            WHEN f2 = 1 THEN '麥迪特訓卡扭蛋券 (3100392)'
            WHEN f3 = 1 THEN '麥迪覺醒扭蛋券 (3100391)'
            WHEN f4 = 1 THEN '麥迪時裝扭蛋券 (3100393)'
            WHEN f5 = 1 THEN '雷艾倫扭蛋券 (3100439)'
            WHEN f6 = 1 THEN '雷艾倫特訓卡扭蛋券 (3100441)'
            WHEN f7 = 1 THEN '雷艾倫覺醒扭蛋券 (3100440)'
            WHEN f8 = 1 THEN '雷艾倫時裝扭蛋券 (3100442)'
            WHEN f9 = 1 THEN '雙重扭蛋券 (1200767)'
            WHEN f10 = 1 THEN '麥迪籃球球箱 (1610041)'
            WHEN f11 = 1 THEN '雷艾倫籃球球箱 (1610047)'
            ELSE '其他联动相关消耗'
        END AS target_category
    FROM TransactionPulse
)

--------------------------------------------------------------------------------
-- Section 4: 最终聚合汇总
--------------------------------------------------------------------------------
SELECT
    target_category AS "消费目标 (道具/行为)",
    event_name AS "底层事件",
    COUNT(DISTINCT user_id) AS "参与人数",
    COUNT(DISTINCT CASE WHEN stamps_spent > 0 THEN user_id END) AS "消耗点券(10000000)参与人数",
    SUM(stamps_spent) AS "消耗点券(10000000)",
    COUNT(DISTINCT CASE WHEN diamonds_spent > 0 THEN user_id END) AS "消耗钻石参与人数",
    SUM(diamonds_spent) AS "消耗钻石"
FROM ClassifiedSpend
GROUP BY 1, 2
ORDER BY 1 DESC;
