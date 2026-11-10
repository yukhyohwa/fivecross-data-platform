/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【麥迪道具及福袋產出數量統計】
             統計特定目標道具（麥迪扭蛋券、集字卡、福袋等）在 2026-02-05 ~ 2026-03-05 期間內的產出，
             並按事件類型 ($part_event) 拆分，避免產出被重複包含或計算多次。
時間 (Period): 2026-02-05 00:00 ~ 2026-03-05 23:59
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Blacklist Logic
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 2: 定義目標道具配置 (麥迪道具及福袋)
--------------------------------------------------------------------------------
ItemConfig AS (
    SELECT * FROM (VALUES 
        (3100390, '麥迪球員扭蛋券'),
        (3100393, '麥迪球員時裝扭蛋券'),
        (3100391, '麥迪覺醒扭蛋券'),
        (3100392, '麥迪特訓卡扭蛋券'),
        (3100396, '集字卡'),
        (1200666, '麥迪特性精選福袋')
    ) AS t (item_id, item_name)
),

--------------------------------------------------------------------------------
-- Section 3: 解析道具產出流水並保留事件名稱 ($part_event)
--------------------------------------------------------------------------------
ItemGains AS (
    SELECT 
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff,
        v."#user_id" AS user_id,
        v."$part_event" AS event_name,  -- 途徑名稱，避免一次產出被記錄多次
        v."#event_time" AS event_time,
        ABS(
            REDUCE(
                FILTER(v.a_rst, x -> TRY_CAST(x.id AS INTEGER) IN (10000000, 19000000) AND TRY_CAST(x.diff AS BIGINT) < 0),
                0.0,
                (s, x) -> s + TRY_CAST(x.diff AS DOUBLE),
                s -> s
            )
        ) AS stamps_consumed
    FROM ta.v_event_10 v
    CROSS JOIN UNNEST(v.a_rst) AS t
    WHERE v."$part_date" BETWEEN '2026-02-05' AND '2026-03-05'
        AND v."#event_time" >= CAST('2026-02-05 00:00:00' AS TIMESTAMP)
        AND v."#event_time" <= CAST('2026-03-05 23:59:59' AS TIMESTAMP)
        AND v."$part_event" = 'shop_buy'
        -- AND v."#user_id" NOT IN (SELECT "#user_id" FROM UserBlacklist)
        AND TRY_CAST(t.diff AS BIGINT) > 0
)

--------------------------------------------------------------------------------
-- Section 4: 按道具及事件(event_name)匯總販售/產出數量
--------------------------------------------------------------------------------
SELECT 
    cfg.item_name AS "道具名稱",
    cfg.item_id AS "ID",
    gains.event_name AS "事件名稱 (Event Name)",
    COUNT(DISTINCT gains.user_id) AS "購買人數",
    SUM(gains.item_diff) AS "購買數量",
    SUM(gains.stamps_consumed) AS "點券消耗量"
FROM ItemConfig cfg
INNER JOIN ItemGains gains ON cfg.item_id = gains.item_id
GROUP BY 1, 2, 3
ORDER BY 2 ASC, 5 DESC;
