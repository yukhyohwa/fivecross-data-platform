/* 新加坡开服后首 7 天创角 cohort（2026-05-08~2026-05-14）；每位用户观察创角后 D0-D7。 */
WITH C AS (SELECT DATE '{{START_DATE}}' s,DATE '{{END_DATE}}' e),
B AS (SELECT DISTINCT "#user_id" u FROM user_result_cluster_13 WHERE cluster_name IN ('internal_users','is_windows','is_water')),
Profile AS (
 SELECT "#user_id" u,
        MAX(CASE WHEN cluster_name='fixed_country' THEN tag_value END) fixed_country,
        MAX(CASE WHEN cluster_name='fixed_os' THEN tag_value END) fixed_os
 FROM user_result_cluster_13
 WHERE cluster_name IN ('fixed_country','fixed_os')
 GROUP BY 1
),
E AS (
 SELECT CAST(v."#account_id" AS VARCHAR) aid,CAST(v."#user_id" AS VARCHAR) uid,CAST(v."$part_date" AS DATE) d,v."#event_time" tm,v."$part_event" pe,v."#event_name" en,
        TRY_CAST(v.a_rst[1].id AS BIGINT) sid,TRY_CAST(v.a_rst[1].key AS INTEGER) st,TRY_CAST(v.pay_amount_usd AS DOUBLE) usd,v.sandbox,v.is_freebuy
 FROM ta.v_event_13 v CROSS JOIN C LEFT JOIN B ON v."#user_id"=B.u
 WHERE v."$part_date" BETWEEN CAST(C.s AS VARCHAR) AND CAST(DATE_ADD('day',7,C.e) AS VARCHAR) AND v."#account_id" IS NOT NULL AND B.u IS NULL),
U AS (SELECT aid,MAX(uid) uid,MIN(d) rd,MIN(tm) rtm FROM E CROSS JOIN C WHERE pe='new_role' AND d BETWEEN C.s AND C.e GROUP BY 1),
UE AS (SELECT E.*,U.rd FROM E JOIN U ON E.aid=U.aid WHERE E.d BETWEEN U.rd AND DATE_ADD('day',7,U.rd)),
Pay AS (SELECT aid,SUM(usd) usd,COUNT(*) orders FROM E CROSS JOIN C WHERE pe='charge' AND d BETWEEN C.s AND C.e AND (sandbox IS NULL OR sandbox=FALSE) AND (is_freebuy IS NULL OR is_freebuy=FALSE) AND usd>0 GROUP BY 1),
Gaps AS (SELECT aid,DATE_DIFF('second',CAST(tm AS TIMESTAMP),LEAD(CAST(tm AS TIMESTAMP)) OVER(PARTITION BY aid ORDER BY tm)) gap FROM UE WHERE en NOT LIKE '%app%'),
Dur AS (SELECT aid,ROUND(SUM(CASE WHEN gap BETWEEN 0 AND 119 THEN gap ELSE 0 END)/60.0,2) mins FROM Gaps GROUP BY 1),
GD AS (SELECT CAST(CAST("gamer_guide_id@gamer_guide_id" AS INTEGER) AS VARCHAR) gid,COALESCE(TRY_CAST("gamer_guide_id@gamer_skip" AS INTEGER),0) sk,MAX("gamer_guide_id@guide_name") name FROM ta_dim.dim_13_0_18504 GROUP BY 1,2),
Guide AS (
 SELECT U.aid,MAX_BY(CAST(TRY_CAST(v.gamer_guide_id AS INTEGER) AS VARCHAR),v."#event_time") gid,MAX_BY(COALESCE(TRY_CAST(v.gamer_skip AS INTEGER),0),v."#event_time") sk,
 MAX_BY(g.name,v."#event_time") name FROM ta.v_event_13 v JOIN U ON CAST(v."#user_id" AS VARCHAR)=U.uid LEFT JOIN B ON v."#user_id"=B.u
 LEFT JOIN GD g ON CAST(TRY_CAST(v.gamer_guide_id AS INTEGER) AS VARCHAR)=g.gid AND COALESCE(TRY_CAST(v.gamer_skip AS INTEGER),0)=g.sk
 WHERE v."$part_event"='gamer_guide' AND v.gamer_guide_id IS NOT NULL AND B.u IS NULL AND CAST(v."$part_date" AS DATE) BETWEEN U.rd AND DATE_ADD('day',7,U.rd) GROUP BY 1),
SM AS (SELECT TRY_CAST("stage_id@stage_id" AS BIGINT) sid,MAX("stage_id@stage_name_show") small,MAX("stage_id@stage_name_real") child FROM ta_dim.dim_13_0_18203 GROUP BY 1),
Main AS (SELECT aid,MAX(sid) sid FROM UE WHERE en='stage_fight' AND st=1001 GROUP BY 1),
StageAttempts AS (
 SELECT aid,sid,COUNT(*) success_challenge_count FROM UE
 WHERE en='stage_fight' AND st=1001 AND sid IS NOT NULL GROUP BY 1,2
),
TaggedStages AS (
 SELECT a.*,REGEXP_REPLACE(COALESCE(sm.child,CAST(a.sid AS VARCHAR)),'-[^-]+$','') chapter_key,
        sm.small,sm.child
 FROM StageAttempts a LEFT JOIN SM sm ON a.sid=sm.sid
),
TerminalStages AS (
 SELECT t.* FROM TaggedStages t JOIN (SELECT aid,MAX(sid) max_sid FROM TaggedStages GROUP BY 1) m
 ON t.aid=m.aid AND t.sid=m.max_sid
),
StuckChapter AS (
 SELECT t.aid,t.chapter_key,t.sid max_success_stage_id,t.small max_success_stage_name,t.child max_success_stage_real,
        SUM(a.success_challenge_count) chapter_success_challenge_count
 FROM TerminalStages t JOIN TaggedStages a ON t.aid=a.aid AND t.chapter_key=a.chapter_key
 GROUP BY 1,2,3,4,5 HAVING SUM(a.success_challenge_count)>2
),
Game AS (SELECT aid,COUNT_IF(en='board_tile_land') monopoly,COUNT_IF(en='match3_combo') match3,COUNT_IF(en='shriosaving_fight') rescue,COUNT_IF(en='pet_travel_start') pet,COUNT_IF(en='stage_fight' AND st=1002) thief,COUNT_IF(en='stage_fight' AND st=1003) gashapon,COUNT_IF(en='stage_fight' AND st=1018) bunny,COUNT_IF(en='stage_fight' AND st=1009) door FROM UE GROUP BY 1),
Red AS (SELECT U.aid,SUM(CASE WHEN TRY_CAST(x.after AS DOUBLE)>TRY_CAST(x.before AS DOUBLE) THEN ABS(TRY_CAST(x.diff AS DOUBLE)) ELSE 0 END) produced,SUM(CASE WHEN TRY_CAST(x.after AS DOUBLE)<TRY_CAST(x.before AS DOUBLE) THEN ABS(TRY_CAST(x.diff AS DOUBLE)) ELSE 0 END) consumed FROM ta.v_event_13 v JOIN U ON CAST(v."#account_id" AS VARCHAR)=U.aid LEFT JOIN B ON v."#user_id"=B.u CROSS JOIN UNNEST(v.a_rst) AS x WHERE v."$part_event"='item_change' AND TRY_CAST(x.id AS BIGINT)=10009 AND B.u IS NULL AND CAST(v."$part_date" AS DATE) BETWEEN U.rd AND DATE_ADD('day',7,U.rd) GROUP BY 1),
R AS (SELECT U.aid,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',1,U.rd) THEN 1 ELSE 0 END)d1,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',2,U.rd) THEN 1 ELSE 0 END)d2,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',3,U.rd) THEN 1 ELSE 0 END)d3,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',4,U.rd) THEN 1 ELSE 0 END)d4,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',5,U.rd) THEN 1 ELSE 0 END)d5,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',6,U.rd) THEN 1 ELSE 0 END)d6,MAX(CASE WHEN UE.pe='login' AND UE.d=DATE_ADD('day',7,U.rd) THEN 1 ELSE 0 END)d7 FROM U LEFT JOIN UE ON U.aid=UE.aid GROUP BY 1)
SELECT U.aid "用户ID",U.uid "ThinkingData用户ID",Profile.fixed_country "国家地区（fixed_country）",Profile.fixed_os "系统（fixed_os）",CAST(U.rtm AS VARCHAR) "创角时间",CASE WHEN COALESCE(Pay.usd,0)=0 THEN '0.免费用户' WHEN Pay.usd<=10 THEN 'a.(0,10]' WHEN Pay.usd<=50 THEN 'b.(10,50]' WHEN Pay.usd<=100 THEN 'c.(50,100]' WHEN Pay.usd<=300 THEN 'd.(100,300]' ELSE 'e.(300,+∞)' END "付费区间分组（累计USD）",ROUND(COALESCE(Pay.usd,0),2) "累计付费USD",COALESCE(Pay.orders,0) "有效订单数",COALESCE(Dur.mins,0) "在线时长分钟（D0-D7）",COALESCE(Guide.gid,'0') "新手引导最后guide_id",COALESCE(Guide.sk,0) "新手引导最后gamer_skip",CONCAT(COALESCE(Guide.gid,'0'),'_',CAST(COALESCE(Guide.sk,0) AS VARCHAR)) "新手引导最后步骤键",Guide.name "新手引导最后步骤",Main.sid "主线最高挑战子关ID",SM.small "主线最高小关",SM.child "主线最高子关",CASE WHEN StuckChapter.aid IS NULL THEN 0 ELSE 1 END "主线章节卡关标记",StuckChapter.chapter_key "主线卡关章节",StuckChapter.max_success_stage_id "卡关时最高成功子关ID",StuckChapter.max_success_stage_name "卡关时最高成功小关",StuckChapter.max_success_stage_real "卡关时最高成功子关",COALESCE(StuckChapter.chapter_success_challenge_count,0) "卡关章节成功挑战次数",COALESCE(Game.monopoly,0) "大富翁参与次数（D0-D7）",COALESCE(Game.match3,0) "三消参与次数（D0-D7）",COALESCE(Game.rescue,0) "拯救小白参与次数（D0-D7）",COALESCE(Game.pet,0) "宠物旅行参与次数（D0-D7）",COALESCE(Game.thief,0) "玩具小偷参与次数（D0-D7）",COALESCE(Game.gashapon,0) "怪物扭蛋人参与次数（D0-D7）",COALESCE(Game.bunny,0) "邪恶兔兔参与次数（D0-D7）",COALESCE(Game.door,0) "穿越魔法之门参与次数（D0-D7）",COALESCE(Red.produced,0) "红钻产出总量（D0-D7）",COALESCE(Red.consumed,0) "红钻消耗总量（D0-D7）",R.d1 "D1留存",R.d2 "D2留存",R.d3 "D3留存",R.d4 "D4留存",R.d5 "D5留存",R.d6 "D6留存",R.d7 "D7留存" FROM U LEFT JOIN Profile ON U.uid=CAST(Profile.u AS VARCHAR) LEFT JOIN Pay ON U.aid=Pay.aid LEFT JOIN Dur ON U.aid=Dur.aid LEFT JOIN Guide ON U.aid=Guide.aid LEFT JOIN Main ON U.aid=Main.aid LEFT JOIN SM ON Main.sid=SM.sid LEFT JOIN StuckChapter ON U.aid=StuckChapter.aid LEFT JOIN Game ON U.aid=Game.aid LEFT JOIN Red ON U.aid=Red.aid LEFT JOIN R ON U.aid=R.aid ORDER BY Pay.usd DESC,U.aid;
