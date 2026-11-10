/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【球員養成監控 - 覺醒度分佈】
             統計指定球員（LG赤司/LG青峰/LG紫原/麥迪/LG黑子）在各自活動期間內的擁有玩家人數，
             以及達到覺醒 1 級 ~ 6 級的累計人數（無須占比）。
關鍵詞 (Keywords): 覺醒度, 擁有玩家人數, 資料時間, Akashi, Aomine, Murasakibara, T-Mac, Kuroko
================================================================================
*/

WITH FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id" 
    FROM user_result_cluster_10 
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

CardOwners AS (
    SELECT 
        card_id,
        COUNT(DISTINCT "#user_id") AS owner_count
    FROM (
        -- 1. 通過道具/卡牌獲取日誌判定擁有
        SELECT 
            id AS card_id,
            "#user_id"
        FROM ta.v_event_10
        CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
        WHERE "$part_date" >= '2025-11-06' AND "$part_date" <= '2026-05-31'
          AND TRY_CAST(diff AS BIGINT) > 0
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
          AND (
              (id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
              (id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
              (id = 99101103 AND "#event_time" BETWEEN TIMESTAMP '2026-05-27 00:00:00' AND TIMESTAMP '2026-05-28 23:59:59')
          )
        
        UNION
        
        -- 2. 通過覺醒升級日誌判定擁有
        SELECT 
            card_id,
            "#user_id"
        FROM ta.v_event_10
        WHERE "$part_event" = 'cardstunt_levelup'
          AND "$part_date" >= '2025-11-06' AND "$part_date" <= '2026-05-31'
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
          AND (
              (card_id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
              (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
              (card_id = 99101103 AND "#event_time" BETWEEN TIMESTAMP '2026-05-27 00:00:00' AND TIMESTAMP '2026-05-28 23:59:59')
          )
          
        UNION
        
        -- 3. 通過天賦升級日誌判定擁有
        SELECT 
            card_id,
            "#user_id"
        FROM ta.v_event_10
        WHERE "$part_event" = 'card_skillrune'
          AND "$part_date" >= '2025-11-06' AND "$part_date" <= '2026-05-31'
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
          AND (
              (card_id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
              (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
              (card_id = 99101103 AND "#event_time" BETWEEN TIMESTAMP '2026-05-27 00:00:00' AND TIMESTAMP '2026-05-28 23:59:59')
          )
    )
    GROUP BY 1
),

AwakeningLevels AS (
    SELECT 
        card_id,
        "#user_id",
        MAX(awaken_skill_level) AS max_level
    FROM ta.v_event_10
    WHERE "$part_event" = 'cardstunt_levelup'
      AND "$part_date" >= '2025-11-06' AND "$part_date" <= '2026-05-31'
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
      AND (
          (card_id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
          (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
          (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
          (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
          (card_id = 99101103 AND "#event_time" BETWEEN TIMESTAMP '2026-05-27 00:00:00' AND TIMESTAMP '2026-05-28 23:59:59')
      )
    GROUP BY 1, 2
),

AwakeningStats AS (
    SELECT 
        card_id,
        COUNT(IF(max_level >= 1, 1, NULL)) AS awaken_1,
        COUNT(IF(max_level >= 2, 1, NULL)) AS awaken_2,
        COUNT(IF(max_level >= 3, 1, NULL)) AS awaken_3,
        COUNT(IF(max_level >= 4, 1, NULL)) AS awaken_4,
        COUNT(IF(max_level >= 5, 1, NULL)) AS awaken_5,
        COUNT(IF(max_level >= 6, 1, NULL)) AS awaken_6
    FROM AwakeningLevels
    GROUP BY 1
),

PlayerList AS (
    SELECT 99600403 AS card_id, 'LG赤司' AS player_name, '11/06 ~ 11/07' AS data_time UNION ALL
    SELECT 99400503, 'LG青峰', '01/01 ~ 01/02' UNION ALL
    SELECT 99210101, '麥迪', '02/05 ~ 02/06' UNION ALL
    SELECT 99500903, 'LG紫原', '03/12 ~ 03/13' UNION ALL
    SELECT 99101103, 'LG黑子', '05/27 ~ 05/28'
)

SELECT 
    p.player_name AS "球員",
    p.card_id AS "卡牌ID",
    COALESCE(o.owner_count, 0) AS "擁有玩家人數",
    COALESCE(s.awaken_1, 0) AS "覺醒I級",
    COALESCE(s.awaken_2, 0) AS "覺醒II級",
    COALESCE(s.awaken_3, 0) AS "覺醒III級",
    COALESCE(s.awaken_4, 0) AS "覺醒IV級",
    COALESCE(s.awaken_5, 0) AS "覺醒V級",
    COALESCE(s.awaken_6, 0) AS "覺醒VI級",
    p.data_time AS "資料時間"
FROM PlayerList p
LEFT JOIN CardOwners o ON p.card_id = o.card_id
LEFT JOIN AwakeningStats s ON p.card_id = s.card_id
ORDER BY p.card_id DESC;
