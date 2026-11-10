/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【紫原週邊監控 - 道具/禮包產出】
             表 3 - 統計紫原(Murasakibara)相關扭蛋包、禮包的售出與產出數量，並按途徑 ($part_event) 拆分。
關鍵詞 (Keywords): 紫原, Murasakibara, 道具產出, 禮包售出, 產出途徑, Item Output, Gift Pack
以mail为主
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: 定義目標道具配置
--------------------------------------------------------------------------------
ItemConfig AS (
    SELECT * FROM (VALUES 
        (1200689, 'LG紫原奪寶扭蛋包'),
        (1200690, 'LG紫原特訓卡扭蛋包'),
        (1200691, 'LG紫原覺醒卡扭蛋包'),
        (1200692, 'LG紫原時裝扭蛋包'),
        (1200693, 'LG紫原籃球寶箱包')
    ) AS t (item_id, item_name)
),

--------------------------------------------------------------------------------
-- Section 2: 黑名單過濾
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id" FROM user_result_cluster_10 WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 3: 解析道具產出流水
--------------------------------------------------------------------------------
ItemGains AS (
    SELECT 
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff,
        v."#user_id" AS user_id,
        v."$part_event" AS event_name,
        v."#event_time" AS event_time
    FROM ta.v_event_10 v
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE v."$part_date" >= '2026-03-12'
        AND v."#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59'
        AND CAST(t.diff AS BIGINT) > 0
        AND v."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
)

--------------------------------------------------------------------------------
-- Section 4: 按道具及途徑匯總
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
ORDER BY 2, 5 DESC;
