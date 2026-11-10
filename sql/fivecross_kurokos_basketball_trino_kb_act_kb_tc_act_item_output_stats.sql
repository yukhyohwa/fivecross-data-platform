/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【禮包與道具產出渠道分析】
             統計特定目標道具（如禮包、扭蛋包、幸運箱）在指定期間內的產出，
             並按事件類型 ($part_event) 拆分，揭示玩家是通過什麼路徑獲得的。
關鍵詞 (Keywords): 禮包, 扭蛋包, 道具產出, 產出途徑, 渠道分析, Gift Pack, Item Output, Distribution
時間 (Period): 2026-03-05 12:00 ~ 2026-03-09 00:00 (範例區間)
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: 定義目標道具配置
--------------------------------------------------------------------------------
ItemConfig AS (
    SELECT * FROM (VALUES 
        (1200701, '徽章入門起手包'),
        (1200702, '徽章優惠禮包I'),
        (1200703, '徽章優惠禮包II'),
        (1200704, '徽章優惠禮包III'),
        (1200705, '特訓卡入門起手包'),
        (1200706, '特訓卡優惠禮包I'),
        (1200707, '特訓卡優惠禮包II'),
        (1200708, '特訓卡優惠禮包III'),
        (1200709, '覺醒優惠禮包'),
        (1200696, '花燈季扭蛋券禮包I'),
        (1200697, '花燈季扭蛋券禮包II'),
        (1200698, '花燈季幸運箱')
    ) AS t (item_id, item_name)
),

--------------------------------------------------------------------------------
-- Section 2: 解析道具產出流水並保留事件名稱
--------------------------------------------------------------------------------
ItemGains AS (
    SELECT 
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff,
        v."#user_id" AS user_id,
        v."$part_event" AS event_name,  -- 途徑名稱
        v."#event_time" AS event_time
    FROM ta.v_event_10 v
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE v."$part_date" BETWEEN '2026-03-05' AND '2026-03-09'
        AND v."#event_time" >= CAST('2026-03-05 12:00:00' AS TIMESTAMP)
        AND v."#event_time" <  CAST('2026-03-09 00:00:00' AS TIMESTAMP)
        AND CAST(t.diff AS BIGINT) > 0
)

--------------------------------------------------------------------------------
-- Section 3: 按道具及途徑匯總
--------------------------------------------------------------------------------
SELECT 
    cfg.item_name AS "道具名稱",
    cfg.item_id AS "道具ID",
    gains.event_name AS "產出途徑 ($part_event)",
    COUNT(DISTINCT gains.user_id) AS "觸發人數",
    SUM(gains.item_diff) AS "總產出數"
FROM ItemConfig cfg
INNER JOIN ItemGains gains ON cfg.item_id = gains.item_id
GROUP BY 1, 2, 3
ORDER BY 1, 5 DESC;
