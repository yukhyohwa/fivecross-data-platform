-- MaxCompute SQL Library for Guilty Crown (g13002012)
-- Extracted from Maxcomputer_GC_UE4_StatementsSummary.hql
-- Note: Replace hardcoded dates (e.g., 20181129, 20190129) with variables/placeholders as needed.

-- ==================================================================
-- 1. Newbie Guide Progress (Novice Throughput)
-- ==================================================================
-- Description: Counts users completing specific guide steps (1001-2004).
SELECT day,COUNT(DISTINCT a.user_id),
COUNT(DISTINCT CASE WHEN guide_id='1001' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='7003' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1002' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1003' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='7001' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1004' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1005' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='7002' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1008' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='2002' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1007' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='1006' THEN b.mbga_uid ELSE NULL END),
COUNT(DISTINCT CASE WHEN guide_id='2004' THEN b.mbga_uid ELSE NULL END)

FROM
(SELECT mbga_uid user_id,MIN(day) day
  FROM g13002012.daily_game_log
 WHERE day >= {start_day} 
 GROUP BY mbga_uid) a 
LEFT JOIN 
(SELECT mbga_uid,get_json_object(a_tar,'$.guide_id') guide_id
FROM g13002012.daily_game_log
WHERE day BETWEEN {start_day} AND {end_day} 
AND a_typ='Dmp101003') b
ON a.user_id=b.mbga_uid
GROUP BY day
ORDER BY day;

-- ==================================================================
-- 2. System Participation Rate (by Level Range)
-- ==================================================================
-- Description: System participation counts categorized by user level ranges (lv1-5, lv6-10, etc.).
SELECT a.lv,a_typ,all_uu,uu,times
  FROM(
SELECT 
  CASE WHEN CAST(param1 AS INT) BETWEEN 0 AND 5 THEN 'lv1-5' 
     WHEN CAST(param1 AS INT) BETWEEN 6 AND 10 THEN 'lv6-10' 
     WHEN CAST(param1 AS INT) BETWEEN 11 AND 20 THEN 'lv11-20' 
     WHEN CAST(param1 AS INT) BETWEEN 21 AND 30 THEN 'lv21-30' 
     WHEN CAST(param1 AS INT) BETWEEN 31 AND 40 THEN 'lv31-40' 
     WHEN CAST(param1 AS INT) >40 THEN '>lv40' END AS lv
,COUNT(DISTINCT user_id) all_uu
  FROM g13002012.daily_game_log
 WHERE day BETWEEN {start_day} AND {end_day}
 GROUP BY 
  CASE WHEN CAST(param1 AS INT) BETWEEN 0 AND 5 THEN 'lv1-5' 
     WHEN CAST(param1 AS INT) BETWEEN 6 AND 10 THEN 'lv6-10' 
     WHEN CAST(param1 AS INT) BETWEEN 11 AND 20 THEN 'lv11-20' 
     WHEN CAST(param1 AS INT) BETWEEN 21 AND 30 THEN 'lv21-30' 
     WHEN CAST(param1 AS INT) BETWEEN 31 AND 40 THEN 'lv31-40' 
     WHEN CAST(param1 AS INT) >40 THEN '>lv40' END 
 ) a 
  LEFT JOIN (
SELECT 
  CASE WHEN CAST(param1 AS INT) BETWEEN 0 AND 5 THEN 'lv1-5' 
     WHEN CAST(param1 AS INT) BETWEEN 6 AND 10 THEN 'lv6-10' 
     WHEN CAST(param1 AS INT) BETWEEN 11 AND 20 THEN 'lv11-20' 
     WHEN CAST(param1 AS INT) BETWEEN 21 AND 30 THEN 'lv21-30' 
     WHEN CAST(param1 AS INT) BETWEEN 31 AND 40 THEN 'lv31-40' 
     WHEN CAST(param1 AS INT) >40 THEN '>lv40' END AS lv
,a_typ,COUNT(DISTINCT user_id) uu,COUNT(user_id) times
  FROM g13002012.daily_game_log
 WHERE day BETWEEN {start_day} AND {end_day}
 GROUP BY a_typ,
  CASE WHEN CAST(param1 AS INT) BETWEEN 0 AND 5 THEN 'lv1-5' 
     WHEN CAST(param1 AS INT) BETWEEN 6 AND 10 THEN 'lv6-10' 
     WHEN CAST(param1 AS INT) BETWEEN 11 AND 20 THEN 'lv11-20' 
     WHEN CAST(param1 AS INT) BETWEEN 21 AND 30 THEN 'lv21-30' 
     WHEN CAST(param1 AS INT) BETWEEN 31 AND 40 THEN 'lv31-40' 
     WHEN CAST(param1 AS INT) >40 THEN '>lv40' END 
 ) b
    ON a.lv=b.lv;

-- ==================================================================
-- 3. Stage Progression (Clear Stars & Time)
-- ==================================================================
-- Description: Completion stats per stage (0-3 stars, avg time).
SELECT stage_id,COUNT(DISTINCT a.user_id),
COUNT(CASE WHEN star=0 THEN user_id ELSE NULL END),
COUNT(CASE WHEN star=1 THEN user_id ELSE NULL END),
COUNT(CASE WHEN star=2 THEN user_id ELSE NULL END),
COUNT(CASE WHEN star=3 THEN user_id ELSE NULL END),

SUM(time)/COUNT(user_id),
SUM(source)/COUNT(user_id)
FROM
(SELECT user_id,get_json_object(a_tar,'$.stage_id') stage_id,get_json_object(a_tar,'$.star') star,get_json_object(a_tar,'$.time') time,get_json_object(a_tar,'$.source') source
FROM g13002012.daily_game_log
WHERE day BETWEEN {start_day} AND {end_day} 
AND a_typ='activity_fight') a
GROUP BY stage_id;

-- ==================================================================
-- 4. Practice Match Participation (Funeral Parlor)
-- ==================================================================
-- Description: Participation in 'lt_fight' for players lv >= 12.
SELECT day,COUNT(DISTINCT user_id),COUNT(DISTINCT CASE WHEN a_typ='lt_fight' THEN user_id ELSE NULL END),
COUNT(CASE WHEN a_typ='lt_fight' THEN user_id ELSE NULL END)
FROM g13002012.daily_game_log
WHERE day>={start_day}
AND CAST(param1 AS INT)>=12
GROUP BY day;

-- ==================================================================
-- 5. Arena Participation & Frequency (PVP)
-- ==================================================================
-- Description: Arena ('arena_fight') participation for players lv >= 26.
-- Frequency distribution (1-5 times, 5-10 times, etc.)
SELECT day,
COUNT(DISTINCT CASE WHEN time BETWEEN 1 AND 5 THEN user_id ELSE NULL END) AS times_1_5,
COUNT(DISTINCT CASE WHEN time BETWEEN 5 AND 10 THEN user_id ELSE NULL END) AS times_5_10,
COUNT(DISTINCT CASE WHEN time BETWEEN 11 AND 15 THEN user_id ELSE NULL END) AS times_11_15,
COUNT(DISTINCT CASE WHEN time BETWEEN 16 AND 20 THEN user_id ELSE NULL END) AS times_16_20,
COUNT(DISTINCT CASE WHEN time BETWEEN 21 AND 25 THEN user_id ELSE NULL END) AS times_21_25,
COUNT(DISTINCT CASE WHEN time BETWEEN 26 AND 30 THEN user_id ELSE NULL END) AS times_26_30,
COUNT(DISTINCT CASE WHEN time BETWEEN 31 AND 999 THEN user_id ELSE NULL END) AS times_31_plus
FROM
(SELECT day,user_id,COUNT(log_t) times
FROM g13002012.daily_game_log
WHERE day>={start_day}
AND a_typ='arena_fight'
AND CAST(param1 AS INT)>=23
GROUP BY day,user_id) a 
GROUP BY day;

-- ==================================================================
-- 6. Resource (Gold) Production/Consumption
-- ==================================================================
-- Description: Daily gold production vs consumption statistics.
SELECT day,a_typ,CASE WHEN diff>0 THEN "产出" ELSE "消耗" END AS type,COUNT(DISTINCT user_id),SUM(ABS(CAST(diff AS INT)))
FROM g13002012.daily_game_log
LATERAL VIEW explode(a_rst)b AS rst
LATERAL VIEW json_tuple(rst,'obj','diff') j_tab AS obj,diff
WHERE day>={start_day}
AND obj='dmp:gold'
GROUP BY day,a_typ,CASE WHEN diff>0 THEN "产出" ELSE "消耗" END;

-- ==================================================================
-- 7. Stamina Consumption
-- ==================================================================
-- Description: Stamina (item@1031001) daily consumption/production by level.
SELECT CAST(param1 AS INT) lv,a_typ,CASE WHEN diff>0 THEN "产出" ELSE "消耗" END AS type,COUNT(DISTINCT user_id),SUM(ABS(CAST(diff AS INT)))
FROM g13002012.daily_game_log
LATERAL VIEW explode(a_rst)b AS rst
LATERAL VIEW json_tuple(rst,'obj','diff') j_tab AS obj,diff
WHERE day BETWEEN {start_day} AND {end_day}
AND substr(obj,1,12)='item@1031001'
GROUP BY CAST(param1 AS INT),a_typ,CASE WHEN diff>0 THEN "产出" ELSE "消耗" END;

-- ==================================================================
-- 8. Average Online Time (by Level)
-- ==================================================================
-- Description: Average daily online time (in minutes) per user level range.
SELECT x.day,lv
,SUM(times)/COUNT(DISTINCT x.mbga_uid)*5 AS avg_minutes
  FROM (---x
SELECT t.day,t.mbga_uid,
  CASE WHEN CAST(p.param1 AS INT) BETWEEN 0 AND 5 THEN 'lv1-5' 
     WHEN CAST(p.param1 AS INT) BETWEEN 6 AND 10 THEN 'lv6-10' 
     WHEN CAST(p.param1 AS INT) BETWEEN 11 AND 20 THEN 'lv11-20' 
     WHEN CAST(p.param1 AS INT) BETWEEN 21 AND 30 THEN 'lv21-30' 
     WHEN CAST(p.param1 AS INT) BETWEEN 31 AND 40 THEN 'lv31-40' 
     WHEN CAST(p.param1 AS INT) >40 THEN '>lv40' END AS lv
,COUNT(DISTINCT concat(times,tt)) AS times
,COUNT(DISTINCT time) AS time 
  FROM(---t
SELECT SUBSTR(hour,1,8) AS day
,mbga_uid,user_id,zone,param1,param2
,SUBSTR(FROM_UNIXTIME(CAST(log_t AS INT),'yyyy-MM-dd HH:mm'),1,15) AS times
,SUBSTR(FROM_UNIXTIME(CAST(log_t AS INT),'yyyy-MM-dd HH:mm'),16,1) AS mins
, CASE WHEN (CAST(SUBSTR(FROM_UNIXTIME(CAST(log_t AS INT),'yyyy-MM-dd HH:mm'),16,1) AS INT)-5) <0 
       THEN '0' ELSE '5' END AS tt
,FROM_UNIXTIME(CAST(log_t AS INT),'yyyy-MM-dd HH:mm') AS time
  FROM g13002012.daily_game_log 
 WHERE day >= {start_day}
  ) t
LEFT JOIN (
SELECT mbga_uid,user_id,MAX(level) param1
 FROM daily_user_snapshot 
 WHERE DAY BETWEEN {start_day} AND {end_day}
GROUP BY  mbga_uid,user_id 
) p ON p.mbga_uid=t.mbga_uid

 GROUP BY t.day,t.mbga_uid,CASE WHEN CAST(p.param1 AS INT) BETWEEN 0 AND 5 THEN 'lv1-5' 
     WHEN CAST(p.param1 AS INT) BETWEEN 6 AND 10 THEN 'lv6-10' 
     WHEN CAST(p.param1 AS INT) BETWEEN 11 AND 20 THEN 'lv11-20' 
     WHEN CAST(p.param1 AS INT) BETWEEN 21 AND 30 THEN 'lv21-30' 
     WHEN CAST(p.param1 AS INT) BETWEEN 31 AND 40 THEN 'lv31-40' 
     WHEN CAST(p.param1 AS INT) >40 THEN '>lv40' END
 ) x 
GROUP BY x.day,lv;

-- ==================================================================
-- 9. New User Retention (Rolling)
-- ==================================================================
-- Description: 1 to 7 day retention rates for new users.
SELECT t1.day
, nuu
, round(r1/nuu,4)  AS RR1
, round(r2/nuu,4)  AS RR2
, round(r3/nuu,4)  AS RR3
, round(r4/nuu,4)  AS RR4
, round(r5/nuu,4)  AS RR5
, round(r6/nuu,4)  AS RR6
, round(r7/nuu,4)  AS RR7

  FROM(---t1
SELECT m.day
,COUNT(DISTINCT m.user_id) AS nuu
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=1 THEN m.user_id ELSE NULL END) AS r1
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=2 THEN m.user_id ELSE NULL END) AS r2
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=3 THEN m.user_id ELSE NULL END) AS r3
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=4 THEN m.user_id ELSE NULL END) AS r4
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=5 THEN m.user_id ELSE NULL END) AS r5
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=6 THEN m.user_id ELSE NULL END) AS r6
,COUNT(DISTINCT CASE WHEN datediff(n.day2,m.day1)=7 THEN m.user_id ELSE NULL END) AS r7

  FROM (---m
SELECT m1.user_id,m1.day,concat(substr(m1.day,1,4),'-',substr(m1.day,5,2),'-',substr(m1.day,7,2)) AS day1
FROM (
SELECT mbga_uid user_id,MIN(day) day
  FROM g13002012.daily_game_log
 WHERE day >= {start_day} 
 GROUP BY mbga_uid
) m1
) m

  LEFT JOIN  (---n
  SELECT DISTINCT day,user_id,concat(substr(day,1,4),'-',substr(day,5,2),'-',substr(day,7,2)) AS day2
  FROM g13002012.daily_game_login 
 WHERE day >= {start_day} ) n

 ON m.user_id=n.user_id
 GROUP BY m.day

 )t1

 ORDER BY  t1.day DESC;

-- ==================================================================
-- 10. Character Usage Rate (Male/Female)
-- ==================================================================
-- Description: Usage counts of specific character IDs (1001-1008...).
SELECT COUNT(n.role1)+COUNT(n.role2)+COUNT(n.role3) tol,
SUM(n.role1)+SUM(n.role2)+SUM(n.role3) man
FROM (
SELECT 
CASE WHEN SPLIT(m.tar,",")[2] LIKE '1001'
       OR SPLIT(m.tar,",")[2] LIKE '1003'
       OR SPLIT(m.tar,",")[2] LIKE '1007'
       OR SPLIT(m.tar,",")[2] LIKE '1008'
       OR SPLIT(m.tar,",")[2] LIKE '1010'  THEN 1 ELSE 0 END  role1,

CASE WHEN SPLIT(m.tar,",")[3] ='1001'
       OR SPLIT(m.tar,",")[3] ='1003'
       OR SPLIT(m.tar,",")[3] ='1007'
       OR SPLIT(m.tar,",")[3] ='1008'
       OR SPLIT(m.tar,",")[3] ='1010' THEN 1 ELSE 0 END role2,

CASE WHEN SPLIT(m.tar,",")[4] ='1001'
       OR SPLIT(m.tar,",")[4] ='1003'
       OR SPLIT(m.tar,",")[4] ='1007'
       OR SPLIT(m.tar,",")[4] ='1008'
       OR SPLIT(m.tar,",")[4] ='1010' THEN 1 ELSE 0 END role3
FROM (
SELECT regexp_replace(a_tar,'\\{|\\}|\\"|\\[|\\]','') tar
 FROM g13002012.daily_game_log 
WHERE day  BETWEEN {start_day} AND {end_day}
 AND a_typ= 'activity_fight'
) m
) n;

-- ==================================================================
-- 11. Fastest Full Collection
-- ==================================================================
-- Description: Top users who collected all cards fastest.
SELECT n.user_id,COUNT(n.card_sid) num,MAX(n.mintime) time
FROM(
    SELECT m.user_id,m.card_sid,MIN(m.time) mintime
    FROM (
        SELECT FROM_UNIXTIME(CAST(log_t AS INT),'yyyy-MM-dd HH:mm') time, user_id, SPLIT(obj,"@")[1] card_sid
        FROM g13002012.daily_game_log 
        LATERAL VIEW explode(a_rst)b AS rst
        LATERAL VIEW json_tuple(rst,'obj','diff') j_tab AS obj,diff
        WHERE day>={start_day}
        AND a_typ='gacha'
        AND obj LIKE 'card%' 

        UNION ALL
        SELECT FROM_UNIXTIME(CAST(log_t AS INT), 'yyyy-MM-dd HH:mm') time,user_id,get_json_object(a_tar,"$.card_id") card_sid
        FROM daily_game_log
        WHERE day >={start_day}  
        AND a_typ='card_compose' 
    ) m
    GROUP BY m.user_id,m.card_sid
) n
GROUP BY n.user_id
ORDER BY num DESC,time;

-- ==================================================================
-- 12. Top Consumption Users (Gold/Crystal)
-- ==================================================================
-- Description: Users who consumed the most Freemoney (Crystal) and Gold.
-- Crystal
SELECT mbga_uid,SUM(ABS(CAST(diff AS INT))) money
FROM g13002012.daily_game_log
LATERAL VIEW explode(a_rst)b AS rst
LATERAL VIEW json_tuple(rst,'obj','diff') j_tab AS obj,diff
WHERE day>={start_day}
AND obj='dmp:freemoney'
AND diff<0
GROUP BY mbga_uid
ORDER BY money DESC;

-- Gold
SELECT mbga_uid,SUM(ABS(CAST(diff AS INT))) gold
FROM g13002012.daily_game_log
LATERAL VIEW explode(a_rst)b AS rst
LATERAL VIEW json_tuple(rst,'obj','diff') j_tab AS obj,diff
WHERE day>={start_day}
AND obj='dmp:gold'
AND diff<0
GROUP BY mbga_uid
ORDER BY gold DESC;

-- ==================================================================
-- 13. Team Composition Analysis (Best Lineup)
-- ==================================================================
-- Description: Analysis of winning team compositions in Arena.
SELECT m.log_t,m.mbga_uid,m.user_id,m.result,sort_array(collect_list(card_name))
FROM ( 
    SELECT a.log_t,a.mbga_uid,a.user_id,a.result,b.member
    FROM (SELECT log_t,mbga_uid,user_id 
        ,get_json_object(a_tar,'$.result') AS result
        ,regexp_replace(get_json_object(a_tar,'$.team'),'\\[|\\]|\\\"|\\{|\\}','') team
        FROM g23002012.daily_game_log
        WHERE day={target_day}
        AND a_typ = 'arena_fight') a
    LATERAL VIEW explode(split(team,',')) b AS member
) m
LEFT JOIN dm_13002012.dim_card n
ON m.member=n.card_sid 
GROUP BY m.log_t,m.mbga_uid,m.user_id,m.result;
