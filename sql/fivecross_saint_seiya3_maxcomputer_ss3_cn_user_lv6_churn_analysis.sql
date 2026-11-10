SET odps.sql.hive.compatible = True;
WITH churned_user_logs AS
(---用户推出游戏前最后一条记录
	SELECT  role_id
	       ,event_time
	       ,event_name
	       ,event_name_cn typ_1
	       ,LEAD(event_name_cn,1,NULL) OVER(PARTITION BY s.role_id ORDER BY s.role_id,s.event_time DESC) typ_2
	       ,LEAD(event_name_cn,2,NULL) OVER(PARTITION BY s.role_id ORDER BY s.role_id,s.event_time DESC) typ_3
	       ,LEAD(event_name_cn,3,NULL) OVER(PARTITION BY s.role_id ORDER BY s.role_id,s.event_time DESC) typ_4
	       ,LEAD(event_name_cn,4,NULL) OVER(PARTITION BY s.role_id ORDER BY s.role_id,s.event_time DESC) typ_5
	       ,LEAD(event_name_cn,5,NULL) OVER(PARTITION BY s.role_id ORDER BY s.role_id,s.event_time DESC) typ_6
	FROM
	(
		SELECT  u1.day
		       ,u1.store
		       ,GET_JSON_OBJECT(u1.role_info,'$.zone_id') zone_id
		       ,GET_JSON_OBJECT(u1.role_info,'$.role_id') role_id
		       ,GET_JSON_OBJECT(u1.role_info,'$.level') level
		       ,GET_JSON_OBJECT(u1.role_info,'$.vip') vip
		       ,u1.event_time
		       ,u1.event_name
		       ,u1.lcm_id
		       ,u2.event_name_cn
		FROM dm_platform.game_event_ods u1
		LEFT JOIN g15002011.dim_eventname u2
		ON u1.event_name = u2.event_name
		WHERE u1.day BETWEEN 20230418 AND ${datetime1} ---'server_stage_fight',
		AND u1.log_store IN ('tt', 'client')
		AND u1.app_id = 15002011
		AND lcm_id <> 'unknown'
		AND SPLIT(u1.event_name, '_')[2] <> 'snapshot'
		AND SPLIT(u1.event_name, '_')[1] <> 'mail'
		AND SPLIT(u1.event_name, '_')[2] <> 'logout'
		AND SPLIT(u1.event_name, '_')[2] <> 'server_task_get' 
		UNION ALL
		SELECT  DISTINCT 20230501 day
		       ,u1.store
		       ,GET_JSON_OBJECT(u1.role_info,'$.zone_id') zone_id
		       ,GET_JSON_OBJECT(u1.role_info,'$.role_id') role_id
		       ,'0' level
		       ,'0' vip
		       ,1682899200000 event_time
		       ,'Churned' event_name
		       ,'Undefined' lcm_id
		       ,'流失' event_name_cn
		FROM dm_platform.game_event_ods u1
		WHERE u1.day BETWEEN 20230418 AND ${datetime1} ---'server_stage_fight',
		AND u1.log_store IN ('tt', 'client')
		AND u1.app_id = 15002011 
	) s
)

SELECT  *
FROM churned_user_logs s1
LEFT JOIN
(
	SELECT  GET_JSON_OBJECT(u1.role_info,'$.role_id') role_id
	       ,MAX(CAST(GET_JSON_OBJECT(u1.role_info,'$.level') AS INT)) level
	       ,MIN(day) regday
	FROM dm_platform.game_event_ods u1
	WHERE u1.day BETWEEN 20230418 AND ${datetime1}
	AND GET_JSON_OBJECT(u1.role_info, '$.level') IS NOT NULL
	AND app_id = 15002011
	GROUP BY  GET_JSON_OBJECT(u1.role_info,'$.role_id')
) s2
ON s1.role_id = s2.role_id
WHERE s2.level = 6
AND s1.regday = 20230418
AND s1.typ_1 = '流失'