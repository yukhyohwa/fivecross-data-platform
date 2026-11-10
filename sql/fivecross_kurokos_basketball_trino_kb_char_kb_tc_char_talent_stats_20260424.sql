/*
================================================================================
遊戲 (Game): 黑子的籃球 (Kuroko's Basketball) - 繁體中文版 (TC)
描述 (Description): 【球員養成監控 - 天賦進度分佈】
             統計指定球員（LG赤司/LG青峰/LG紫原/麥迪/LG黑子）在各自活動期間內的擁有玩家人數，
             以及天賦在 0%、1-20%、21-40%、41-60%、61-80%、81-99%、100%（拉滿）的人數與占比。
關鍵詞 (Keywords): 天賦進度, 擁有玩家人數, 占比, 資料時間, Akashi, Aomine, Murasakibara, T-Mac, Kuroko
================================================================================
*/

WITH FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id" 
    FROM user_result_cluster_10 
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

TalentLevels AS (
    SELECT 
        card_id,
        "#user_id" AS user_id,
        MAX(talent_rate) AS max_talent
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
    GROUP BY 1, 2
),

UserTalent AS (
    SELECT 
        o.card_id,
        o.user_id,
        COALESCE(t.max_talent, 0) AS talent_rate
    FROM (
        SELECT DISTINCT card_id, "#user_id" AS user_id
        FROM (
            -- 1. 通過道具/卡牌獲取日誌判定擁有
            SELECT id AS card_id, "#user_id" FROM ta.v_event_10
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
            SELECT card_id, "#user_id" FROM ta.v_event_10
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
            SELECT card_id, "#user_id" FROM ta.v_event_10
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
    ) o
    LEFT JOIN TalentLevels t ON o.card_id = t.card_id AND o.user_id = t.user_id
),

TalentStats AS (
    SELECT 
        card_id,
        COUNT(DISTINCT user_id) AS total_owners,
        COUNT(IF(talent_rate = 0, 1, NULL)) AS talent_0,
        COUNT(IF(talent_rate > 0 AND talent_rate <= 20, 1, NULL)) AS talent_1_20,
        COUNT(IF(talent_rate > 20 AND talent_rate <= 40, 1, NULL)) AS talent_21_40,
        COUNT(IF(talent_rate > 40 AND talent_rate <= 60, 1, NULL)) AS talent_41_60,
        COUNT(IF(talent_rate > 60 AND talent_rate <= 80, 1, NULL)) AS talent_61_80,
        COUNT(IF(talent_rate > 80 AND talent_rate < 100, 1, NULL)) AS talent_81_99,
        COUNT(IF(talent_rate = 100, 1, NULL)) AS talent_100
    FROM UserTalent
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
    COALESCE(s.total_owners, 0) AS "擁有玩家人數",
    
    COALESCE(s.talent_0, 0) AS "天賦0%人數",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_0, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦0%占比(%)",
         
    COALESCE(s.talent_1_20, 0) AS "天賦1-20%人數",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_1_20, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦1-20%占比(%)",
         
    COALESCE(s.talent_21_40, 0) AS "天賦21-40%人數",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_21_40, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦21-40%占比(%)",
         
    COALESCE(s.talent_41_60, 0) AS "天賦41-60%人數",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_41_60, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦41-60%占比(%)",
         
    COALESCE(s.talent_61_80, 0) AS "天賦61-80%人數",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_61_80, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦61-80%占比(%)",
         
    COALESCE(s.talent_81_99, 0) AS "天賦81-99%人數",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_81_99, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦81-99%占比(%)",
         
    COALESCE(s.talent_100, 0) AS "天賦100%人數(滿天賦)",
    CASE WHEN COALESCE(s.total_owners, 0) > 0 
         THEN ROUND(CAST(COALESCE(s.talent_100, 0) AS DOUBLE) / s.total_owners * 100, 2) 
         ELSE 0.00 END AS "天賦100%占比(%)",
         
    p.data_time AS "資料時間"
FROM PlayerList p
LEFT JOIN TalentStats s ON p.card_id = s.card_id
ORDER BY p.card_id DESC;
