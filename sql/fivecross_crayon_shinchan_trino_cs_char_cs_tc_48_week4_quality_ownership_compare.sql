/* D3 业务日最新快照：伙伴/技能按品质的持有人数、持有渗透与等级。 */
WITH TB AS (SELECT DISTINCT "#user_id" u FROM user_result_cluster_18 WHERE cluster_name IN ('internal_users','is_windows','is_water')),
SB AS (SELECT DISTINCT "#user_id" u FROM user_result_cluster_13 WHERE cluster_name IN ('internal_users','is_windows','is_water')),
SC AS (SELECT DISTINCT "#user_id" u FROM user_result_cluster_13 WHERE cluster_name='fixed_country' AND tag_value='新加坡'),
SA AS (SELECT DISTINCT "#user_id" u FROM user_result_cluster_13 WHERE cluster_name='fixed_os' AND tag_value='Android'),
M AS (SELECT '新加坡全体(iOS+Android)' grp,c.u FROM SC c UNION ALL SELECT '新加坡Android',c.u FROM SC c JOIN SA a ON c.u=a.u),
Cohort18 AS (
 SELECT e."#account_id" aid FROM ta.v_event_18 e LEFT JOIN TB b ON e."#user_id"=b.u
 WHERE e."$part_event"='new_role' AND e."$part_date" BETWEEN '{{START_DATE}}' AND '{{END_DATE}}' AND b.u IS NULL AND CAST(e."#account_id" AS VARCHAR) NOT IN ('4100002','91110','91111') GROUP BY 1
),
Cohort13 AS (
 SELECT m.grp,e."#account_id" aid FROM ta.v_event_13 e JOIN M m ON e."#user_id"=m.u LEFT JOIN SB b ON e."#user_id"=b.u
 WHERE e."$part_event"='new_role' AND e."$part_date" BETWEEN '2026-05-08' AND '2026-05-12' AND b.u IS NULL GROUP BY 1,2
),
SnapshotUsers AS (
 SELECT '繁体CBT' grp,v.lid rid FROM ta.v_event_18 v JOIN Cohort18 c ON v.lid=c.aid WHERE v."$part_event"='daily_role_snapshot' AND CAST(v."$part_date" AS DATE)=DATE_ADD('day',1,DATE '{{END_DATE}}') GROUP BY 1,2
 UNION ALL SELECT c.grp,v.lid FROM ta.v_event_13 v JOIN Cohort13 c ON v.lid=c.aid WHERE v."$part_event"='daily_role_snapshot' AND v."$part_date"='2026-05-13' GROUP BY 1,2),
Comp AS (
 SELECT '繁体CBT' grp,v.lid rid,v."#event_time" et,TRY_CAST(t.pet_id AS BIGINT) item_id,TRY_CAST(t.level AS BIGINT) lv FROM ta.v_event_18 v CROSS JOIN UNNEST(v.friend) AS t JOIN SnapshotUsers u ON u.grp='繁体CBT' AND u.rid=v.lid WHERE v."$part_event"='daily_role_snapshot' AND CAST(v."$part_date" AS DATE)=DATE_ADD('day',1,DATE '{{END_DATE}}')
 UNION ALL SELECT u.grp,v.lid,v."#event_time",TRY_CAST(t.pet_id AS BIGINT),TRY_CAST(t.level AS BIGINT) FROM ta.v_event_13 v CROSS JOIN UNNEST(v.friend) AS t JOIN SnapshotUsers u ON u.grp<>'繁体CBT' AND u.rid=v.lid WHERE v."$part_event"='daily_role_snapshot' AND v."$part_date"='2026-05-13'),
Skill AS (
 SELECT '繁体CBT' grp,v.lid rid,v."#event_time" et,TRY_CAST(t.skill_id AS BIGINT) item_id,TRY_CAST(t.skill_lv AS BIGINT) lv FROM ta.v_event_18 v CROSS JOIN UNNEST(v.skill) AS t(role_id,skill_id,skill_lv) JOIN SnapshotUsers u ON u.grp='繁体CBT' AND u.rid=v.lid WHERE v."$part_event"='daily_role_snapshot' AND CAST(v."$part_date" AS DATE)=DATE_ADD('day',1,DATE '{{END_DATE}}')
 UNION ALL SELECT u.grp,v.lid,v."#event_time",TRY_CAST(t.skill_id AS BIGINT),TRY_CAST(t.skill_lv AS BIGINT) FROM ta.v_event_13 v CROSS JOIN UNNEST(v.skill) AS t(role_id,skill_id,skill_lv) JOIN SnapshotUsers u ON u.grp<>'繁体CBT' AND u.rid=v.lid WHERE v."$part_event"='daily_role_snapshot' AND v."$part_date"='2026-05-13'),
Items AS (SELECT '伙伴' system,* FROM Comp UNION ALL SELECT '技能',* FROM Skill),
Latest AS (SELECT *,ROW_NUMBER() OVER(PARTITION BY system,grp,rid,item_id ORDER BY et DESC) rn FROM Items),
Quality AS (
 SELECT l.*,COALESCE(CASE WHEN l.grp='繁体CBT' THEN d18."friend.role_id@quality_name" ELSE d13."friend.role_id@quality_name" END,'未知品质') quality
 FROM Latest l LEFT JOIN ta_dim.dim_18_0_53443 d18 ON l.grp='繁体CBT' AND CAST(l.item_id AS INTEGER)=CAST(d18."friend.role_id@friend_id" AS INTEGER)
 LEFT JOIN ta_dim.dim_13_0_37979 d13 ON l.grp<>'繁体CBT' AND CAST(l.item_id AS INTEGER)=CAST(d13."friend.role_id@friend_id" AS INTEGER)
 WHERE l.rn=1 AND l.lv IS NOT NULL)
SELECT q.grp "对比组",q.system "养成类型",q.quality "品质",(SELECT COUNT(*) FROM SnapshotUsers s WHERE s.grp=q.grp) "快照用户数",COUNT(DISTINCT q.rid) "持有人数",ROUND(100.0*COUNT(DISTINCT q.rid)/NULLIF((SELECT COUNT(*) FROM SnapshotUsers s WHERE s.grp=q.grp),0),2) "持有率(%)",ROUND(1.0*COUNT(*)/NULLIF(COUNT(DISTINCT q.rid),0),2) "人均持有数",ROUND(AVG(CAST(q.lv AS DOUBLE)),2) "平均等级",APPROX_PERCENTILE(q.lv,0.5) "等级中位数" FROM Quality q GROUP BY 1,2,3 ORDER BY 1,2,3;
