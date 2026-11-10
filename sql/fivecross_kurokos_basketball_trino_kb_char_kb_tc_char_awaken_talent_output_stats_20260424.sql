/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【球員產出與養成監控報表】(根據圖片需求)
             1. 覺醒人數 (1-6)
             2. 天賦人數 (80%)
             3. 獲得人數 (產出)
             4. 資料時間
================================================================================
*/
WITH FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),
ItemOutput AS (
    SELECT 
        id AS item_id,
        COUNT(DISTINCT "#user_id") AS total_output
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE "$part_date" >= '2026-01-01' AND "$part_date" <= '2026-05-31'
      AND TRY_CAST(diff AS BIGINT) > 0 
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
      AND (
          (id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
          (id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
          (id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
          (id = 99212001 AND "#event_time" BETWEEN TIMESTAMP '2026-04-22 00:00:00' AND TIMESTAMP '2026-04-23 23:59:59')
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
            card_id,
            "#user_id",
            MAX(awaken_skill_level) AS max_level
        FROM ta.v_event_10
        WHERE "$part_event" IN ('cardstunt_levelup')
          AND "$part_date" >= '2026-01-01' AND "$part_date" <= '2026-05-31'
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
          AND (
              (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
              (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (card_id = 99212001 AND "#event_time" BETWEEN TIMESTAMP '2026-04-22 00:00:00' AND TIMESTAMP '2026-04-23 23:59:59')
          )
        GROUP BY 1, 2
    )
    GROUP BY 1
),
TalentStats AS (
    SELECT 
        card_id,
        COUNT(DISTINCT "#user_id") AS talent_gt_80
    FROM (
        SELECT 
            card_id,
            "#user_id",
            MAX(talent_rate) AS max_talent
        FROM ta.v_event_10
        WHERE "$part_event" IN ('card_skillrune')
          AND "$part_date" >= '2026-01-01' AND "$part_date" <= '2026-05-31'
          AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
          AND (
              (card_id = 99400503 AND "#event_time" BETWEEN TIMESTAMP '2026-01-01 00:00:00' AND TIMESTAMP '2026-01-02 23:59:59') OR
              (card_id = 99500903 AND "#event_time" BETWEEN TIMESTAMP '2026-03-12 00:00:00' AND TIMESTAMP '2026-03-13 23:59:59') OR
              (card_id = 99210101 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-06 23:59:59') OR
              (card_id = 99212001 AND "#event_time" BETWEEN TIMESTAMP '2026-04-22 00:00:00' AND TIMESTAMP '2026-04-23 23:59:59')
          )
        GROUP BY 1, 2
    )
    WHERE max_talent > 80
    GROUP BY 1
),
PlayerReport AS (
    SELECT 
        'LG青峰' AS player_name,
        99400503 AS ID,
        (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99400503) AS "1",
        (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99400503) AS "2",
        (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99400503) AS "3",
        (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99400503) AS "4",
        (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99400503) AS "5",
        (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99400503) AS "6",
        (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99400503) AS "80%",
        (SELECT total_output FROM ItemOutput WHERE item_id = 99400503) AS "獲得人數",
        '01/01 ~ 01/02' AS "資料時間"
    UNION ALL
    SELECT 
        'LG紫原', 99500903,
        (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99500903),
        (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99500903),
        (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99500903), (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99500903),
        (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99500903),
        (SELECT total_output FROM ItemOutput WHERE item_id = 99500903),
        '03/12 ~ 03/13'
    UNION ALL
    SELECT 
        '麥迪', 99210101,
        (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99210101),
        (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99210101),
        (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99210101), (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99210101),
        (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99210101),
        (SELECT total_output FROM ItemOutput WHERE item_id = 99210101),
        '02/05 ~ 02/06'
    UNION ALL
    SELECT 
        '雷艾倫', 99212001,
        (SELECT awaken_1 FROM AwakeningCounts WHERE card_id = 99212001), (SELECT awaken_2 FROM AwakeningCounts WHERE card_id = 99212001),
        (SELECT awaken_3 FROM AwakeningCounts WHERE card_id = 99212001), (SELECT awaken_4 FROM AwakeningCounts WHERE card_id = 99212001),
        (SELECT awaken_5 FROM AwakeningCounts WHERE card_id = 99212001), (SELECT awaken_6 FROM AwakeningCounts WHERE card_id = 99212001),
        (SELECT talent_gt_80 FROM TalentStats WHERE card_id = 99212001),
        (SELECT total_output FROM ItemOutput WHERE item_id = 99212001),
        '04/22 ~ 04/23'
)
SELECT * FROM PlayerReport;
