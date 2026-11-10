/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【2026春季點券禮包產出/販售數量統計】
             統計特定目標道具（春季點券禮包1~7）在 2026-03-26 ~ 2026-03-29 期間內的產出，
             並按事件類型 ($part_event) 拆分，避免產出被重複包含或計算多次。
時間 (Period): 2026-03-26 00:00 ~ 2026-03-29 23:59
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: 定義目標道具配置 (春季點券禮包 1~7)
--------------------------------------------------------------------------------
ItemConfig AS (
    SELECT * FROM (VALUES 
        (1200746, '春季點券禮包1'),
        (1200747, '春季點券禮包2'),
        (1200748, '春季點券禮包3'),
        (1200749, '春季點券禮包4'),
        (1200750, '春季點券禮包5'),
        (1200751, '春季點券禮包6'),
        (1200752, '春季點券禮包7')
    ) AS t (item_id, item_name)
),

--------------------------------------------------------------------------------
-- Section 2: 解析道具產出流水並保留事件名稱 ($part_event)
--------------------------------------------------------------------------------
ItemGains AS (
    SELECT 
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff,
        v."#user_id" AS user_id,
        v."$part_event" AS event_name,  -- 途徑名稱，避免一次產出被記錄多次
        v."#event_time" AS event_time
    FROM ta.v_event_10 v
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE v."$part_date" BETWEEN '2026-03-26' AND '2026-03-29'
        AND v."#event_time" >= CAST('2026-03-26 00:00:00' AS TIMESTAMP)
        AND v."#event_time" <= CAST('2026-03-29 23:59:59' AS TIMESTAMP)
        AND CAST(t.diff AS BIGINT) > 0
)

--------------------------------------------------------------------------------
-- Section 3: 按道具及事件(event_name)匯總販售/產出數量
--------------------------------------------------------------------------------
SELECT 
    cfg.item_name AS "道具名稱",
    cfg.item_id AS "ID",
    gains.event_name AS "事件名稱 (Event Name)",
    COUNT(DISTINCT gains.user_id) AS "購買/獲得人數",
    SUM(gains.item_diff) AS "販售數量"
FROM ItemConfig cfg
INNER JOIN ItemGains gains ON cfg.item_id = gains.item_id
GROUP BY 1, 2, 3
ORDER BY 2 ASC, 5 DESC;
