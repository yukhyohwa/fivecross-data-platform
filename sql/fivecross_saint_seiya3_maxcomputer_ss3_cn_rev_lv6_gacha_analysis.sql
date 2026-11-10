SET odps.sql.hive.compatible = True;
---INSERT OVERWRITE TABLE g15002011.daily_cloud3_gacha PARTITION(day)
SELECT  role_id
       ,level
       ,collect_set(card_name)
FROM
(
	SELECT  s1.day
	       ,s1.zone_id
	       ,s1.gacha_id
	       ,s1.role_id
	       ,s4.level
	       ,s1.vip
	       ,s1.event_name
	       ,s1.event_time
	       ,s1.lcm_id
	       ,s1.a_rst
	       ,SPLIT(s3.obj,'#')[1] obj
	       ,s5.card_name
	       ,CAST(s3.diff AS INT) diff
	FROM
	(
		SELECT  log_store
		       ,u1.day
		       ,GET_JSON_OBJECT(u1.a_tar,'$.gacha_id') gacha_id
		       ,GET_JSON_OBJECT(u1.role_info,'$.zone_id') zone_id
		       ,GET_JSON_OBJECT(u1.role_info,'$.role_id') role_id
		       ,GET_JSON_OBJECT(u1.role_info,'$.level') level
		       ,GET_JSON_OBJECT(u1.role_info,'$.vip') vip
		       ,u1.a_rst
		       ,u1.a_tar
		       ,u1.event_time
		       ,u1.event_name
		       ,u1.lcm_id
		FROM dm_platform.game_event_ods u1
		LEFT JOIN
		(
			SELECT  *
			FROM g15002011.dim_user_blacklist
			WHERE lcm_id <> 'unknown' 
		) u2
		ON u1.lcm_id = u2.lcm_id
		WHERE u1.day BETWEEN 20230418 AND ${datetime1}
		AND u2.lcm_id IS NULL
		AND u1.app_id = 15002011
		AND u1.log_store IN ('tt', 'client')
		AND event_name = 'server_game_gacha'
		AND GET_JSON_OBJECT(u1.role_info, '$.level') = '6' 
	) s1 LATERAL VIEW EXPLODE(SPLIT(REGEXP_REPLACE(REGEXP_REPLACE(a_rst, '\\[|\\]', ''), '\\}\\,\\{', '\\}\;\\{'), '\\;')) s2 AS rst LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff', 'before', 'after') s3 AS obj, diff, before, after
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
	) s4
	ON s1.role_id = s4.role_id
	INNER JOIN g15002011.dim_card s5
	ON SPLIT(s3.obj, '#')[1] = s5.card_id
	WHERE s3.diff IS NOT NULL
	AND s1.role_id IS NOT NULL
	AND s4.regday = 20230418
	---AND s4.level = 6
	AND diff > 0 
) p1
WHERE obj IN (1007, 1008, 1009, 1010, 1027, 1052, 1053, 1054, 1071, 1075, 1089)
GROUP BY  level
         ,role_id