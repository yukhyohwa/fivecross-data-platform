/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: JP (Japan)
Description: 黑子JP NBA联动 (罗德曼 Rodman) 相关道具点券消耗精准统计
             通过【原子事务脉冲 (Atomic Transaction Pulse)】技术关联点券消耗与道具产出：
             1. 关联同一用户、同一秒、同一事件下的资源变动。
             2. 区分直接点券抽取（基于集字卡或直接券产出）与商店购券。
             3. 自动识别混合礼包，防止归类偏离。
时间范围：2026-07-01 ~ 2026-07-29
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
    WHERE s1."$part_date" BETWEEN '2026-07-01' AND '2026-07-29'
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
        SUM(CASE WHEN item_id IN (10000000) AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS stamps_spent,
        SUM(CASE WHEN item_id IN (19000000) AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS free_stamps_spent,
        -- 钻石/宣誓币消耗 (ID: 10000003)
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent,
        
        -- 各目标道具产出标记 (Binary)
        MAX(CASE WHEN item_id = 3010565 AND item_diff > 0 THEN 1 ELSE 0 END) AS f1, -- 罗德曼球员扭蛋券
        MAX(CASE WHEN item_id = 3010568 AND item_diff > 0 THEN 1 ELSE 0 END) AS f2, -- 罗德曼皮肤扭蛋券
        MAX(CASE WHEN item_id = 3010567 AND item_diff > 0 THEN 1 ELSE 0 END) AS f3, -- 罗德曼觉醒扭蛋券
        MAX(CASE WHEN item_id = 3010566 AND item_diff > 0 THEN 1 ELSE 0 END) AS f4, -- 罗德曼特训卡扭蛋券
        MAX(CASE WHEN item_id = 3010577 AND item_diff > 0 THEN 1 ELSE 0 END) AS f5, -- 集字卡
        MAX(CASE WHEN item_id = 1100862 AND item_diff > 0 THEN 1 ELSE 0 END) AS f6, -- 罗德曼特性精選福袋
        MAX(CASE WHEN item_id = 1610054 AND item_diff > 0 THEN 1 ELSE 0 END) AS f7, -- 罗德曼篮球宝箱
        MAX(CASE WHEN item_id = 1100853 AND item_diff > 0 THEN 1 ELSE 0 END) AS f8, -- 双重扭蛋礼包II
        MAX(CASE WHEN item_id = 3010573 AND item_diff > 0 THEN 1 ELSE 0 END) AS f9, -- 幸运奇迹扭蛋券II
        MAX(CASE WHEN item_id = 1100857 AND item_diff > 0 THEN 1 ELSE 0 END) AS f10, -- 千万感谢祭特训卡自选箱
        MAX(CASE WHEN item_id = 1100855 AND item_diff > 0 THEN 1 ELSE 0 END) AS f11, -- 千万感谢祭觉醒卡自选箱
        MAX(CASE WHEN item_id = 1100856 AND item_diff > 0 THEN 1 ELSE 0 END) AS f12, -- 千万感谢祭时装自选箱
        MAX(CASE WHEN item_id = 1100854 AND item_diff > 0 THEN 1 ELSE 0 END) AS f13, -- 千万感谢祭球场自选箱
        MAX(CASE WHEN item_id = 1100591 AND item_diff > 0 THEN 1 ELSE 0 END) AS f14  -- 扭蛋券自选箱
    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        -- 必须包含至少一种目标道具的获取
        MAX(CASE WHEN item_id IN (3010565, 3010568, 3010567, 3010566, 3010577, 1100862, 1610054, 1100853, 3010573, 1100857, 1100855, 1100856, 1100854, 1100591) AND item_diff > 0 THEN 1 ELSE 0 END) = 1
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
        free_stamps_spent,
        diamonds_spent,
        CASE 
            WHEN f6 = 1 THEN '罗德曼特性精選福袋 (1100862)'
            WHEN f7 = 1 THEN '罗德曼篮球宝箱 (1610054)'
            WHEN f8 = 1 THEN '双重扭蛋礼包II (1100853)'
            WHEN f10 = 1 THEN '千万感谢祭特训卡自选箱 (1100857)'
            WHEN f11 = 1 THEN '千万感谢祭觉醒卡自选箱 (1100855)'
            WHEN f12 = 1 THEN '千万感谢祭时装自选箱 (1100856)'
            WHEN f13 = 1 THEN '千万感谢祭球场自选箱 (1100854)'
            WHEN f14 = 1 THEN '扭蛋券自选箱 (1100591)'
            WHEN f1 = 1 THEN '罗德曼球员扭蛋券 (3010565)'
            WHEN f2 = 1 THEN '罗德曼皮肤扭蛋券 (3010568)'
            WHEN f3 = 1 THEN '罗德曼觉醒扭蛋券 (3010567)'
            WHEN f4 = 1 THEN '罗德曼特训卡扭蛋券 (3010566)'
            WHEN f9 = 1 THEN '幸运奇迹扭蛋券II (3010573)'
            -- 集字卡 (3010577) 产出通常意味着玩家直接消耗货币进行扭蛋(roulette_buy)，而非先买票。
            WHEN f5 = 1 THEN '集字卡 (3010577)'
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
    COUNT(DISTINCT CASE WHEN stamps_spent > 0 THEN user_id END) AS "消耗付费点券参与人数",
    SUM(stamps_spent) AS "消耗付费点券总量",
    COUNT(DISTINCT CASE WHEN free_stamps_spent > 0 THEN user_id END) AS "消耗免费点券参与人数",
    SUM(free_stamps_spent) AS "消耗免费点券总量",
    COUNT(DISTINCT CASE WHEN diamonds_spent > 0 THEN user_id END) AS "消耗钻石参与人数",
    SUM(diamonds_spent) AS "消耗钻石"
FROM ClassifiedSpend
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 4 DESC;
