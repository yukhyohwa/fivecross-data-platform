/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【特別任務自選箱產出監控】
             統計 1200731 (球場自選箱) 與 1200732 (時裝自選箱) 的產出情況。
             對比販售首日 (04/16) 與 週末整體 (04/16 - 04/19) 的數據。
關鍵詞 (Keywords): 特別任務, 1200731, 1200732, 產出對比, Launch vs Weekend
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: 定義目標道具配置
--------------------------------------------------------------------------------
ItemConfig AS (
    SELECT * FROM (VALUES 
        (1200731, '特別任務球場自選箱'),
        (1200732, '特別任務時裝自選箱')
    ) AS t (item_id, item_name)
),

--------------------------------------------------------------------------------
-- Section 2: 黑名單過濾
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id" 
    FROM user_result_cluster_10 
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 3: 解析道具產出流水 (全時段: 04/16 - 04/19)
--------------------------------------------------------------------------------
ItemGains AS (
    SELECT 
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff,
        v."#user_id" AS user_id,
        v."$part_event" AS event_name,
        v."$part_date" AS log_date,
        v."#event_time" AS event_time
    FROM ta.v_event_10 v
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE v."$part_date" BETWEEN '2026-04-16' AND '2026-04-19'
        AND v."#event_time" BETWEEN TIMESTAMP '2026-04-16 00:00:00' AND TIMESTAMP '2026-04-19 23:59:59'
        AND CAST(t.diff AS BIGINT) > 0
        AND v."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
)

--------------------------------------------------------------------------------
-- Section 4: 汇总输出 (UNION 对比两个时段)
--------------------------------------------------------------------------------
-- ── 1. 販售首日 (04/16) 数据 ──
SELECT 
    '1. 販售首日 (04/16)' AS "統計時段",
    cfg.item_name AS "道具名稱",
    cfg.item_id AS "道具ID",
    gains.event_name AS "產出途徑 ($part_event)",
    COUNT(DISTINCT gains.user_id) AS "觸發人數",
    SUM(gains.item_diff) AS "總產出數"
FROM ItemConfig cfg
INNER JOIN (SELECT * FROM ItemGains WHERE log_date = '2026-04-16') gains ON cfg.item_id = gains.item_id
GROUP BY 1, 2, 3, 4

UNION ALL

-- ── 2. 週末累計 (04/16 - 04/19) 数据 ──
SELECT 
    '2. 週末累計 (04/16-04/19)' AS "統計時段",
    cfg.item_name AS "道具名稱",
    cfg.item_id AS "道具ID",
    gains.event_name AS "產出途徑 ($part_event)",
    COUNT(DISTINCT gains.user_id) AS "觸發人數",
    SUM(gains.item_diff) AS "總產出數"
FROM ItemConfig cfg
INNER JOIN ItemGains gains ON cfg.item_id = gains.item_id
GROUP BY 1, 2, 3, 4

ORDER BY 3, 1;
