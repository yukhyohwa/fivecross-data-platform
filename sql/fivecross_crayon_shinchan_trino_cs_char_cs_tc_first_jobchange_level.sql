/* 小新台湾首次转职等级分布：转职事件无等级时，取同一玩家前后7日最近的 role_lev；同距优先转职前。 */
WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
), JobchangeEvents AS (
    SELECT v."#user_id" user_id, v."#account_id" account_id, v.lid role_id,
           v."#event_time" jobchange_time, CAST(v."$part_date" AS DATE) jobchange_date
    FROM ta.v_event_18 v LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."#event_name" = 'card_Jobchange' AND v."$part_date" BETWEEN '{{START_DATE}}' AND '{{END_DATE}}'
      AND ub.user_id IS NULL AND v."#user_id" IS NOT NULL
), LevelEvents AS (
    SELECT v."#user_id" user_id, v."#event_time" level_time, CAST(v."$part_date" AS DATE) level_date,
           TRY_CAST(v.role_lev AS BIGINT) role_level
    FROM ta.v_event_18 v INNER JOIN (SELECT DISTINCT user_id FROM JobchangeEvents) j ON v."#user_id" = j.user_id
    WHERE v."$part_date" BETWEEN '{{START_DATE}}' AND '{{END_DATE}}' AND TRY_CAST(v.role_lev AS BIGINT) IS NOT NULL
), NearestLevel AS (
    SELECT j.*, l.role_level jobchange_level,
           ROW_NUMBER() OVER (PARTITION BY j.user_id, j.jobchange_time, j.role_id ORDER BY ABS(DATE_DIFF('second', CAST(l.level_time AS TIMESTAMP), CAST(j.jobchange_time AS TIMESTAMP))), CASE WHEN l.level_time <= j.jobchange_time THEN 0 ELSE 1 END, l.level_time DESC) nearest_level_rn
    FROM JobchangeEvents j LEFT JOIN LevelEvents l ON j.user_id = l.user_id AND l.level_date BETWEEN DATE_ADD('day', -7, j.jobchange_date) AND DATE_ADD('day', 7, j.jobchange_date)
), FirstJobchange AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY jobchange_time, jobchange_date, role_id) first_jobchange_rn
    FROM NearestLevel WHERE nearest_level_rn = 1
)
SELECT jobchange_level AS "首次转职等级", COUNT(*) AS "转职玩家数",
       ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS "占比(%)",
       MIN(jobchange_date) AS "最早首次转职日期", MAX(jobchange_date) AS "最晚首次转职日期"
FROM FirstJobchange WHERE first_jobchange_rn = 1 AND jobchange_level IS NOT NULL
GROUP BY 1 ORDER BY 1;
