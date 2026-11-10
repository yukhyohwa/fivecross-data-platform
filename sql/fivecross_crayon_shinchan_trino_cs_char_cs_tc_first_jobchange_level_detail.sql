/* 小新台湾首次转职明细；等级回填口径与 cs_tc_first_jobchange_level.sql 完全相同。 */
WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id FROM user_result_cluster_18 WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
), JobchangeEvents AS (
    SELECT v."#user_id" user_id, v."#account_id" account_id, v.lid role_id, v."#event_time" jobchange_time, CAST(v."$part_date" AS DATE) jobchange_date
    FROM ta.v_event_18 v LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."#event_name" = 'card_Jobchange' AND v."$part_date" BETWEEN '{{START_DATE}}' AND '{{END_DATE}}' AND ub.user_id IS NULL AND v."#user_id" IS NOT NULL
), LevelEvents AS (
    SELECT v."#user_id" user_id, v."#event_time" level_time, CAST(v."$part_date" AS DATE) level_date, TRY_CAST(v.role_lev AS BIGINT) role_level
    FROM ta.v_event_18 v INNER JOIN (SELECT DISTINCT user_id FROM JobchangeEvents) j ON v."#user_id" = j.user_id
    WHERE v."$part_date" BETWEEN '{{START_DATE}}' AND '{{END_DATE}}' AND TRY_CAST(v.role_lev AS BIGINT) IS NOT NULL
), NearestLevel AS (
    SELECT j.*, l.role_level jobchange_level, ROW_NUMBER() OVER (PARTITION BY j.user_id, j.jobchange_time, j.role_id ORDER BY ABS(DATE_DIFF('second', CAST(l.level_time AS TIMESTAMP), CAST(j.jobchange_time AS TIMESTAMP))), CASE WHEN l.level_time <= j.jobchange_time THEN 0 ELSE 1 END, l.level_time DESC) nearest_level_rn
    FROM JobchangeEvents j LEFT JOIN LevelEvents l ON j.user_id=l.user_id AND l.level_date BETWEEN DATE_ADD('day',-7,j.jobchange_date) AND DATE_ADD('day',7,j.jobchange_date)
), FirstJobchange AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY jobchange_time,jobchange_date,role_id) first_jobchange_rn FROM NearestLevel WHERE nearest_level_rn=1
)
SELECT user_id AS "玩家ID", account_id AS "账号ID", role_id AS "角色ID", jobchange_date AS "首次转职日期", jobchange_time AS "首次转职时间", jobchange_level AS "首次转职等级"
FROM FirstJobchange WHERE first_jobchange_rn=1 AND jobchange_level IS NOT NULL ORDER BY "首次转职时间", "玩家ID";
