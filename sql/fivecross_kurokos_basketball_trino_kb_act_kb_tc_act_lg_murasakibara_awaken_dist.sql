/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【紫原週邊監控 - 覺醒分布】
             表 2 - 統計紫原(Murasakibara)等球員在活動期間內達到各個覺醒階段 (I-VI) 的不重複人數。
關鍵詞 (Keywords): 紫原, Murasakibara, 赤司, 青峰, 麥迪, 覺醒等級, 覺醒分布, Awakening Distribution
================================================================================
*/

WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" FROM user_result_cluster_10 WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
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
)
SELECT 'LG赤司(99600403)' AS "球員", '2025-11-06 00:00 ~ 2025-11-07 23:59' AS "活動期間", awaken_1 AS "I", awaken_2 AS "II", awaken_3 AS "III", awaken_4 AS "IV", awaken_5 AS "V", awaken_6 AS "VI" FROM AwakeningCounts WHERE card_id = 99600403
UNION ALL
SELECT 'LG青峰(99400503)', '2026-01-01 00:00 ~ 2026-01-02 23:59', awaken_1, awaken_2, awaken_3, awaken_4, awaken_5, awaken_6 FROM AwakeningCounts WHERE card_id = 99400503
UNION ALL
SELECT '麥迪(99210101)', '2026-02-05 00:00 ~ 2026-02-06 23:59', awaken_1, awaken_2, awaken_3, awaken_4, awaken_5, awaken_6 FROM AwakeningCounts WHERE card_id = 99210101
UNION ALL
SELECT 'LG紫原(99500903)', '2026-03-12 00:00 ~ 2026-03-13 23:59', awaken_1, awaken_2, awaken_3, awaken_4, awaken_5, awaken_6 FROM AwakeningCounts WHERE card_id = 99500903;
