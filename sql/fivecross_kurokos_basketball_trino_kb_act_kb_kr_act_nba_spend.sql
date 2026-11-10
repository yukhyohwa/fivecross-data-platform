/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: KR (Korea / 韩国)
Description: 黑子KR NBA联动 (麦迪 McGrady & 雷阿伦 Ray Allen & 罗德曼 Rodman) 相关道具点券消耗精准统计
             通过【原子事务脉冲 (Atomic Transaction Pulse)】技术关联点券消耗与道具产出：
             1. 关联同一用户、同一秒、同一事件下的资源变动。
             2. 区分直接点券抽取（基于集字卡或直接券产出）与商店购券。
             3. 自动识别混合礼包，防止归类偏离。
时间范围：2026-02-04 ~ 2026-07-29 (涵盖麦迪 02/04~03/04, 雷阿伦 04/22~05/20, 罗德曼 07/01~07/29)
说明：韩服顺序不一样，所以不能用 CROSS JOIN UNNEST(s1.a_rst) AS t(id, "before", diff, "after", "key")
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 0: 黑名单过滤
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
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
        CAST(t."id" AS BIGINT) AS item_id,
        CAST(t."diff" AS BIGINT) AS item_diff,
        CAST(t."before" AS BIGINT) AS item_before,
        CAST(t."after" AS BIGINT) AS item_after
    FROM ta.v_event_12 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" BETWEEN '2026-02-04' AND '2026-07-29'
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
           -- 点券消耗 (ID: 10000000, 19000000)
        SUM(CASE WHEN item_id IN (10000000) AND item_before > item_after THEN ABS(item_diff) ELSE 0 END) AS stamps_spent,
        SUM(CASE WHEN item_id IN (19000000) AND item_before > item_after THEN ABS(item_diff) ELSE 0 END) AS free_stamps_spent,
        -- 钻石/宣誓币消耗 (ID: 10000003)
        SUM(CASE WHEN item_id = 10000003 AND item_before > item_after THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent,
        
        -- 各目标道具产出标记 (Binary)
        -- 1. 麦迪 (McGrady) 2026/02/04 ~ 03/04
        MAX(CASE WHEN item_id = 3010456 AND item_diff > 0 THEN 1 ELSE 0 END) AS f1, -- 麦迪球员扭蛋券
        MAX(CASE WHEN item_id = 3010457 AND item_diff > 0 THEN 1 ELSE 0 END) AS f2, -- 麦迪特训卡扭蛋券
        MAX(CASE WHEN item_id = 3010458 AND item_diff > 0 THEN 1 ELSE 0 END) AS f3, -- 麦迪觉醒扭蛋券
        MAX(CASE WHEN item_id = 3010459 AND item_diff > 0 THEN 1 ELSE 0 END) AS f4, -- 麦迪皮肤扭蛋券
        
        -- 2. 雷阿伦 (Ray Allen) 2026/04/22 ~ 05/20
        MAX(CASE WHEN item_id = 3010510 AND item_diff > 0 THEN 1 ELSE 0 END) AS f5, -- 雷阿伦球员扭蛋券
        MAX(CASE WHEN item_id = 3010511 AND item_diff > 0 THEN 1 ELSE 0 END) AS f6, -- 雷阿伦特训卡扭蛋券
        MAX(CASE WHEN item_id = 3010512 AND item_diff > 0 THEN 1 ELSE 0 END) AS f7, -- 雷阿伦觉醒扭蛋券
        MAX(CASE WHEN item_id = 3010513 AND item_diff > 0 THEN 1 ELSE 0 END) AS f8, -- 雷阿伦皮肤扭蛋券
        MAX(CASE WHEN item_id = 1100816 AND item_diff > 0 THEN 1 ELSE 0 END) AS f9, -- 双重扭蛋礼包 (雷阿伦期/罗德曼期共用)

        -- 3. 罗德曼 (Rodman) 2026/07/01 ~ 07/29
        MAX(CASE WHEN item_id = 3010565 AND item_diff > 0 THEN 1 ELSE 0 END) AS f10, -- 罗德曼球员扭蛋券
        MAX(CASE WHEN item_id = 3010566 AND item_diff > 0 THEN 1 ELSE 0 END) AS f11, -- 罗德曼特训卡扭蛋券
        MAX(CASE WHEN item_id = 3010567 AND item_diff > 0 THEN 1 ELSE 0 END) AS f12, -- 罗德曼觉醒扭蛋券
        MAX(CASE WHEN item_id = 3010568 AND item_diff > 0 THEN 1 ELSE 0 END) AS f13, -- 罗德曼皮肤扭蛋券
        
        -- 4. 篮球球箱
        MAX(CASE WHEN item_id = 1610041 AND item_diff > 0 THEN 1 ELSE 0 END) AS f14, -- 麦迪篮球球箱
        MAX(CASE WHEN item_id = 1610047 AND item_diff > 0 THEN 1 ELSE 0 END) AS f15  -- 雷阿伦篮球球箱

    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        -- 必须包含至少一种目标道具的获取
        MAX(CASE WHEN item_id IN (3010456, 3010457, 3010458, 3010459, 3010510, 3010511, 3010512, 3010513, 1100816, 3010565, 3010566, 3010567, 3010568, 1610041, 1610047) AND item_diff > 0 THEN 1 ELSE 0 END) = 1
        -- 且必须有实际的付费/免费点券或钻石消耗
        AND SUM(CASE WHEN item_id IN (10000000, 19000000, 10000003) AND item_before > item_after THEN 1 ELSE 0 END) > 0
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
            -- 麦迪
            WHEN f1 = 1 THEN '麦迪球员扭蛋券 (3010456)'
            WHEN f2 = 1 THEN '麦迪特训卡扭蛋券 (3010457)'
            WHEN f3 = 1 THEN '麦迪觉醒扭蛋券 (3010458)'
            WHEN f4 = 1 THEN '麦迪皮肤扭蛋券 (3010459)'
            -- 雷阿伦
            WHEN f5 = 1 THEN '雷阿伦球员扭蛋券 (3010510)'
            WHEN f6 = 1 THEN '雷阿伦特训卡扭蛋券 (3010511)'
            WHEN f7 = 1 THEN '雷阿伦觉醒扭蛋券 (3010512)'
            WHEN f8 = 1 THEN '雷阿伦皮肤扭蛋券 (3010513)'
            WHEN f9 = 1 AND part_date BETWEEN '2026-04-22' AND '2026-05-20' THEN '双重扭蛋礼包_雷阿伦期 (1100816)'
            -- 罗德曼
            WHEN f10 = 1 THEN '罗德曼球员扭蛋券 (3010565)'
            WHEN f11 = 1 THEN '罗德曼特训卡扭蛋券 (3010566)'
            WHEN f12 = 1 THEN '罗德曼觉醒扭蛋券 (3010567)'
            WHEN f13 = 1 THEN '罗德曼皮肤扭蛋券 (3010568)'
            WHEN f9 = 1 AND part_date BETWEEN '2026-07-01' AND '2026-07-29' THEN '双重扭蛋礼包_罗德曼期 (1100816)'
            WHEN f14 = 1 THEN '麦迪篮球球箱 (1610041)'
            WHEN f15 = 1 THEN '雷阿伦篮球球箱 (1610047)'
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
    COUNT(DISTINCT CASE WHEN free_stamps_spent > 0 THEN user_id END) AS "消耗点券(19000000)参与人数",
    SUM(free_stamps_spent) AS "消耗点券(19000000)",
    COUNT(DISTINCT CASE WHEN diamonds_spent > 0 THEN user_id END) AS "消耗钻石参与人数",
    SUM(diamonds_spent) AS "消耗钻石"
FROM ClassifiedSpend
GROUP BY 1, 2
ORDER BY 1 DESC;
