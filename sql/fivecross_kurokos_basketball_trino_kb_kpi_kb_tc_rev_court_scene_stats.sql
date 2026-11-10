/*
================================================================================
Game: Kuroko's Basketball (繁體黑子)
Region: TC (Traditional Chinese)
Description: 2. 球場販售狀況 (Court Sales Status)
================================================================================
*/

-- Event Name ┃ Column Name ┃ Count ┃
-- item_stock │ item_rest   │     4

WITH FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
)
SELECT 
    CASE t.id 
        WHEN 50201037 THEN '火箭球場(50201037)'
        WHEN 50201036 THEN '海底球場(50201036)'
    END AS court_name,
    CASE t.id 
        WHEN 50201037 THEN '2026-02-05 09:00 ~ 2026-02-28 23:59'
        WHEN 50201036 THEN '2026-02-12 00:00 ~ 2026-02-25 23:59'
    END AS period,
    CASE t.id 
        WHEN 50201037 THEN '累儲8000點券'
        WHEN 50201036 THEN '春節扭蛋'
    END AS method,
    COUNT(DISTINCT "#user_id") AS held_count
FROM ta.v_event_10
CROSS JOIN UNNEST(item_rest) AS t(id, num)
WHERE "$part_date" >= '2026-02-05' AND "$part_date" <= '2026-02-28'
  AND TRY_CAST(t.num AS BIGINT) > 0 
  AND (
      (t.id = 50201037 AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-28 23:59:59') OR
      (t.id = 50201036 AND "#event_time" BETWEEN TIMESTAMP '2026-02-12 00:00:00' AND TIMESTAMP '2026-02-25 23:59:59')
  )
  AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
GROUP BY 1, 2, 3

