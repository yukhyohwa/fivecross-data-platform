/*
新加坡开服首周主线章节卡关（2026-05-08~2026-05-14 创角，观察各用户 D0-D7）。
由于 stage_fight 仅能可靠视为成功记录：取用户最高成功子关所在章节，
该章节所有已成功子关的挑战次数合计 > 2 时，标记为该章节“卡关代理”。
*/
WITH C AS (SELECT DATE '{{START_DATE}}' s, DATE '{{END_DATE}}' e),
B AS (SELECT DISTINCT "#user_id" u FROM user_result_cluster_13 WHERE cluster_name IN ('internal_users','is_windows','is_water')),
P AS (SELECT "#user_id" u,MAX(CASE WHEN cluster_name='fixed_country' THEN tag_value END) country,MAX(CASE WHEN cluster_name='fixed_os' THEN tag_value END) os FROM user_result_cluster_13 WHERE cluster_name IN ('fixed_country','fixed_os') GROUP BY 1),
U AS (
 SELECT CAST(v."#account_id" AS VARCHAR) aid,CAST(v."#user_id" AS VARCHAR) uid,MIN(CAST(v."$part_date" AS DATE)) role_date
 FROM ta.v_event_13 v CROSS JOIN C LEFT JOIN B ON v."#user_id"=B.u
 WHERE v."$part_event"='new_role' AND v."$part_date" BETWEEN CAST(C.s AS VARCHAR) AND CAST(C.e AS VARCHAR) AND v."#account_id" IS NOT NULL AND B.u IS NULL
 GROUP BY 1,2
),
StageMap AS (
 SELECT TRY_CAST("stage_id@stage_id" AS BIGINT) stage_id,MAX("stage_id@stage_name_show") stage_name,MAX("stage_id@stage_name_real") stage_name_real
 FROM ta_dim.dim_13_0_18203 GROUP BY 1
),
Attempts AS (
 SELECT u.aid,TRY_CAST(v.a_rst[1].id AS BIGINT) stage_id,COUNT(*) success_challenge_count
 FROM ta.v_event_13 v JOIN U u ON CAST(v."#account_id" AS VARCHAR)=u.aid LEFT JOIN B ON v."#user_id"=B.u
 WHERE v."#event_name"='stage_fight' AND TRY_CAST(v.a_rst[1].key AS INTEGER)=1001 AND b.u IS NULL
   AND CAST(v."$part_date" AS DATE) BETWEEN u.role_date AND DATE_ADD('day',7,u.role_date)
 GROUP BY 1,2
),
Tagged AS (
 SELECT a.*,REGEXP_REPLACE(COALESCE(m.stage_name_real,CAST(a.stage_id AS VARCHAR)),'-[^-]+$','') chapter_key,
        COALESCE(m.stage_name,CAST(a.stage_id AS VARCHAR)) stage_name, m.stage_name_real
 FROM Attempts a LEFT JOIN StageMap m ON a.stage_id=m.stage_id
),
MaxSuccess AS (SELECT aid,MAX(stage_id) max_success_stage_id FROM Tagged GROUP BY 1),
Terminal AS (
 SELECT t.aid,t.stage_id max_success_stage_id,t.stage_name max_success_stage_name,t.stage_name_real,t.chapter_key
 FROM Tagged t JOIN MaxSuccess m ON t.aid=m.aid AND t.stage_id=m.max_success_stage_id
),
UserStuck AS (
 SELECT t.aid,t.chapter_key,t.max_success_stage_id,t.max_success_stage_name,t.stage_name_real,SUM(a.success_challenge_count) chapter_success_challenge_count
 FROM Terminal t JOIN Tagged a ON t.aid=a.aid AND t.chapter_key=a.chapter_key
 GROUP BY 1,2,3,4,5
 HAVING SUM(a.success_challenge_count)>2
)
SELECT COALESCE(p.country,'未标记') AS "国家地区（fixed_country）",COALESCE(p.os,'未标记') AS "系统（fixed_os）",
       s.chapter_key AS "卡关章节",s.max_success_stage_id AS "最高成功子关ID",s.max_success_stage_name AS "最高成功小关",s.stage_name_real AS "最高成功子关",
       COUNT(DISTINCT s.aid) AS "卡关用户数",SUM(s.chapter_success_challenge_count) AS "章节成功挑战次数",ROUND(AVG(s.chapter_success_challenge_count),2) AS "卡关用户平均章节成功挑战次数"
FROM UserStuck s JOIN U u ON s.aid=u.aid LEFT JOIN P p ON u.uid=CAST(p.u AS VARCHAR)
GROUP BY 1,2,3,4,5,6
ORDER BY "卡关用户数" DESC,"章节成功挑战次数" DESC;
