/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【紫原週邊監控 - 球員狀態】
             表 1 - 統計紫原(Murasakibara)等球員的產出、天賦養成人數、時裝持有及覺醒進度。
關鍵詞 (Keywords): 紫原, Murasakibara, 赤司, 青峰, 麥迪, 產出, 天賦, 時裝, 覺醒, Player Status
================================================================================
*/

WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" FROM user_result_cluster_10 WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),
ItemOutput AS (
    SELECT 
        id AS item_id,
        SUM(TRY_CAST(diff AS BIGINT)) AS total_output
    FROM ta.v_event_10 CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE "$part_date" >= '2025-11-06' AND TRY_CAST(diff AS BIGINT) > 0 
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
      AND (
          (id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
          (id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
          (id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
          (id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59')
      )
    GROUP BY 1
),
CostumeHeld AS (
    SELECT 
        skin_id AS item_id,
        COUNT(DISTINCT "#user_id") AS total_held
    FROM ta.v_event_10 
    WHERE "$part_event" IN ('card_skinequip') AND "$part_date" >= '2025-11-06'
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
      AND (
          (skin_id = 96600461 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
          (skin_id = 96400542 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
          (skin_id = 96210102 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
          (skin_id = 96500951 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59')
      )
    GROUP BY 1
),
AwakeningCounts AS (
    SELECT 
        card_id,
        COUNT(IF(max_level >= 1, 1, NULL)) AS awaken_1,
        COUNT(IF(max_level >= 2, 1, NULL)) AS awaken_2,
        COUNT(IF(max_level >= 3, 1, NULL)) AS awaken_3,
        COUNT(IF(max_level >= 4, 1, NULL)) AS awaken_4,
        COUNT(IF(max_level >= 5, 1, NULL)) AS awaken_5,
        COUNT(IF(max_level >= 6, 1, NULL)) AS awaken_6
    FROM (
        SELECT 
            card_id, "#user_id", MAX(awaken_skill_level) AS max_level
        FROM ta.v_event_10
        WHERE "$part_event" IN ('cardstunt_levelup') AND "$part_date" >= '2025-11-06'
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
          AND (
              (card_id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
              (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59')
          )
        GROUP BY 1, 2
    ) GROUP BY 1
),
TalentStats AS (
    SELECT 
        card_id,
        COUNT(DISTINCT "#user_id") AS talent_gt_80
    FROM (
        SELECT card_id, "#user_id", MAX(talent_rate) AS max_talent 
        FROM ta.v_event_10 WHERE "$part_event" IN ('card_skillrune') AND "$part_date" >= '2025-11-06' 
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist) 
          AND (
              (card_id = 99600403 AND "#event_time" BETWEEN TIMESTAMP '2025-11-06 00:00:00' AND TIMESTAMP '2025-11-07 23:59:59') OR
              (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 00:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59')
          )
        GROUP BY 1, 2
    ) WHERE max_talent > 80 GROUP BY 1
)
SELECT 
    'LG赤司(99600403)' AS "球員", '2025-11-06 00:00 ~ 2025-11-07 23:59' AS "產出期間", 
    (SELECT total_output FROM ItemOutput WHERE item_id = 99600403) AS "球員產出數量",
    '96600461' AS "時裝ID", (SELECT total_held FROM CostumeHeld WHERE item_id = 96600461) AS "時裝持有數",
    (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99600403) AS "覺醒I",
    (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99600403) AS "覺醒II",
    (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99600403) AS "覺醒III",
    (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99600403) AS "覺醒IV",
    (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99600403) AS "覺醒V",
    (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99600403) AS "覺醒VI",
    (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99600403) AS "天賦養成80%人數"
UNION ALL
SELECT 
    'LG青峰(99400503)', '2026-01-01 00:00 ~ 2026-01-02 23:59', 
    (SELECT total_output FROM ItemOutput WHERE item_id = 99400503), '96400542', (SELECT total_held FROM CostumeHeld WHERE item_id = 96400542),
    (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99400503), (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99400503), (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99400503), (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99400503), (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99400503), (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99400503),
    (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99400503)
UNION ALL
SELECT 
    '麥迪(99210101)', '2026-02-05 00:00 ~ 2026-02-06 23:59', 
    (SELECT total_output FROM ItemOutput WHERE item_id = 99210101), '96210102', (SELECT total_held FROM CostumeHeld WHERE item_id = 96210102),
    (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99210101),
    (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99210101)
UNION ALL
SELECT 
    'LG紫原(99500903)', '2026-03-12 00:00 ~ 2026-03-13 23:59', 
    (SELECT total_output FROM ItemOutput WHERE item_id = 99500903), '待定', NULL,
    (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99500903),
    (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99500903);
