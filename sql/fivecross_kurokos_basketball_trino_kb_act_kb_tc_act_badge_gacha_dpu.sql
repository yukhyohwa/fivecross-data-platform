/*
================================================================================
Game: Kuroko's Basketball (繁體黑子)
Region: TC (Traditional Chinese)
Description: 6. 玩法狀況 - 徽章扭蛋 每日參與人數 (Gameplay DAU)
================================================================================
*/

WITH FinalBlacklist AS (
    SELECT DISTINCT 
        "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
)
SELECT 
    "$part_date" AS gacha_date,
    COUNT(DISTINCT "#user_id") AS daily_participants
FROM ta.v_event_10
WHERE "$part_date" BETWEEN '2026-02-05' AND '2026-02-28'
  AND "#event_time" BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-28 23:59:59'
  AND "$part_event" = 'badge_collect_reward' 
  AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
GROUP BY 1
ORDER BY 1

