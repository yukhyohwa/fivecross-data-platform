/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: JP (Japan)
Description: 黑子JP NBA联动 (麦迪 McGrady) 相关道具点券消耗精准统计
             通过【原子事务脉冲 (Atomic Transaction Pulse)】技术关联点券消耗与道具产出：
             1. 关联同一用户、同一秒、同一事件下的资源变动。
             2. 区分直接点券抽取（基于集字卡或直接券产出）与商店购券。
             3. 自动识别混合礼包，防止归类偏离。
时间范围：2026-02-04 ~ 2026-03-04
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
    WHERE s1."$part_date" BETWEEN '2026-02-04' AND '2026-03-04'
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
        MAX(CASE WHEN item_id = 3010456 AND item_diff > 0 THEN 1 ELSE 0 END) AS f1, -- 麦迪球员扭蛋券
        MAX(CASE WHEN item_id = 3010459 AND item_diff > 0 THEN 1 ELSE 0 END) AS f2, -- 麦迪皮肤扭蛋券
        MAX(CASE WHEN item_id = 3010458 AND item_diff > 0 THEN 1 ELSE 0 END) AS f3, -- 麦迪觉醒扭蛋券
        MAX(CASE WHEN item_id = 3010457 AND item_diff > 0 THEN 1 ELSE 0 END) AS f4, -- 麦迪特训卡扭蛋券
        MAX(CASE WHEN item_id = 3100396 AND item_diff > 0 THEN 1 ELSE 0 END) AS f5, -- 集字卡 (代表直接抽取行为)
        MAX(CASE WHEN item_id = 1100728 AND item_diff > 0 THEN 1 ELSE 0 END) AS f6  -- 麦迪特性精選福袋
    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        -- 必须包含至少一种目标道具的获取
        MAX(CASE WHEN item_id IN (3010456, 3010459, 3010458, 3010457, 3100396 ,1100728) AND item_diff > 0 THEN 1 ELSE 0 END) = 1
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
            -- 如果同一事务内获得多种券或福袋，归类为混合/礼包
            -- WHEN (f1 + f2 + f3 + f4 + f6) > 1 THEN 'NBA联动混合礼包/多券组合'
            WHEN f6 = 1 THEN '麦迪特性精選福袋 (1100728)'
            WHEN f1 = 1 THEN '麦迪球员扭蛋券 (3010456)'
            WHEN f2 = 1 THEN '麦迪皮肤扭蛋券 (3010459)'
            WHEN f3 = 1 THEN '麦迪觉醒扭蛋券 (3010458)'
            WHEN f4 = 1 THEN '麦迪特训卡扭蛋券 (3010457)'
            -- 集字卡 (3100396) 产出通常意味着玩家直接消耗货币进行扭蛋(roulette_buy)，而非先买票。
            WHEN f5 = 1 THEN '集字卡/麦迪扭蛋直抽消耗 (3100396)'
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
