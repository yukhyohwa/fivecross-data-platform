-- ODPS SQL 
--********************************************************************--
-- Author: 张君宝
-- Create Time: 2025-05-20 16:44:16
-- Description: Aligned with Generator Logic for S29 Card Balance
--********************************************************************--
--- SET ODPS SYSTEM
SET odps.sql.hive.compatible = TRUE;
SET hive.exec.dynamic.partition.mode = nonstrict;

TRUNCATE TABLE g23002013_dev.tmp_skill_2;
TRUNCATE TABLE g23002013_dev.tmp_skill_base;
TRUNCATE TABLE g23002013_dev.tmp_match;
TRUNCATE TABLE g23002013_dev.tmp_peak_detail;
TRUNCATE TABLE g23002013_dev.tmp_match_banpick;

--------------------------------------------------------------------------------
-- 1. 排位_源 (Rank Source)
--------------------------------------------------------------------------------
INSERT INTO g23002013_dev.tmp_match_banpick 
SELECT 
    CASE 
        WHEN ${app_id} = '23002013' THEN '繁体' 
        WHEN ${app_id} = '33002013' THEN '韩国' 
        WHEN ${app_id} = '63002013' THEN '全球' 
    END AS app_typ,
    a.rank_name,
    type,
    total_match,
    a.card_name,
    match_times,
    ban,
    win,
    score,
    twoN,
    twoG,
    layupN,
    layupG,
    dunkN,
    dunkG,
    threeN,
    threeG,
    blockG,
    stealG,
    rebG,
    asitN,
    mark,
    intercept,
    groundN,
    ballT,
    twoN_open,
    twoG_open,
    threeN_open,
    threeG_open,
    downN,
    downND,
    blockND,
    twoN_bejam,
    twoG_bejam,
    threeN_bejam,
    threeG_bejam,
    interND,
    stealND,
    a.day
FROM (
    SELECT 
        a.day,
        rank_name,
        card_name,
        type,
        COUNT(DISTINCT b.mbga_uid, b.session) AS match_times,
        COUNT(CASE WHEN result = 'true' THEN log_t ELSE NULL END) AS win,
        SUM(score) AS score,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoN') AS INT)) AS twoN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoG') AS INT)) AS twoG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.layupN') AS INT)) AS layupN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.layupG') AS INT)) AS layupG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.dunkN') AS INT)) AS dunkN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.dunkG') AS INT)) AS dunkG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeN') AS INT)) AS threeN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeG') AS INT)) AS threeG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.blockG') AS INT)) AS blockG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.stealG') AS INT)) AS stealG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.rebG') AS INT)) AS rebG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.asitN') AS INT)) AS asitN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.intercept') AS INT)) AS intercept,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.ballT') AS INT)) AS ballT,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.groundN') AS INT)) AS groundN,
        SUM(CAST(GET_JSON_OBJECT(player, '$.mark') AS DOUBLE)) / 10000 AS mark,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoN_open') AS INT)) AS twoN_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoG_open') AS INT)) AS twoG_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeN_open') AS INT)) AS threeN_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeG_open') AS INT)) AS threeG_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.downN') AS INT)) AS downN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.downND') AS INT)) AS downND,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.blockND') AS INT)) AS blockND,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousMidN') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousMid2N') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.beJamMidN') AS INT)) AS twoN_bejam,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousMidG') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousMid2G') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.beJamMidG') AS INT)) AS twoG_bejam,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousThreeN') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousThree2N') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.beJamThreeN') AS INT)) AS threeN_bejam,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousThreeG') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.seriousThree2G') AS INT)) + SUM(CAST(GET_JSON_OBJECT(adata, '$.beJamThreeG') AS INT)) AS threeG_bejam,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.interND') AS INT)) AS interND,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.stealND') AS INT)) AS stealND
    FROM (
        SELECT 
            session,
            MAX(CAST(SPLIT(star, '#')[0] AS INT)) AS star,
            '1' AS a1,
            day,
            COUNT(DISTINCT result) AS results
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND ai = 'false'
          AND type = 'RankH3V3'
        GROUP BY session, day 
        HAVING results = 2
    ) a
    LEFT JOIN (
        SELECT 
            player, mbga_uid, user_id, session, score, result, adata,
            CAST(SPLIT(star, '#')[0] AS INT) AS star, '1' AS a1, type, log_t, day
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND ai = 'false'
          AND type = 'RankH3V3'
    ) b ON a.session = b.session AND a.day = b.day
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1 
    LEFT JOIN g${app_id}.dim_card_h5 c ON GET_JSON_OBJECT(player, '$.player') = c.card_id
    WHERE a.star >= d.min_star AND a.star <= d.max_star
    GROUP BY a.day, rank_name, card_name, type
) a
LEFT JOIN (
    SELECT a.day, rank_name, card_name, COUNT(DISTINCT b.session) AS ban
    FROM (
        SELECT session, MAX(CAST(SPLIT(star, '#')[0] AS INT)) AS star, '1' AS a1, day
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND ai = 'false'
          AND type = 'RankH3V3'
        GROUP BY session, day
    ) a
    LEFT JOIN (
        SELECT day, REGEXP_REPLACE(GET_JSON_OBJECT(player, '$.ban'), '\\[|\\]|"', '') AS player, session
        FROM g${app_id}.daily_match_snapshot
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND type = 'RankH3V3'
    ) b ON a.session = b.session AND a.day = b.day
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1 
    LEFT JOIN g${app_id}.dim_card_h5 c ON player = c.card_id
    WHERE a.star >= d.min_star AND a.star <= d.max_star
    GROUP BY a.day, rank_name, card_name
) b ON a.day = b.day AND a.rank_name = b.rank_name AND a.card_name = b.card_name
LEFT JOIN (
    SELECT day, rank_name, COUNT(DISTINCT session) AS total_match
    FROM (
        SELECT session, MAX(CAST(SPLIT(star, '#')[0] AS INT)) AS star, '1' AS a1, day
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND ai = 'false'
          AND type = 'RankH3V3'
        GROUP BY session, day
    ) a
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1
    WHERE a.star >= d.min_star AND a.star <= d.max_star
    GROUP BY day, rank_name
) c ON a.day = c.day AND a.rank_name = c.rank_name;


--------------------------------------------------------------------------------
-- 1.5. 天赋50%_源 (Talent 50% Source)
--------------------------------------------------------------------------------
INSERT INTO g23002013_dev.tmp_match 
SELECT 
    CASE 
        WHEN ${app_id} = '23002013' THEN '繁体' 
        WHEN ${app_id} = '33002013' THEN '韩国' 
        WHEN ${app_id} = '63002013' THEN '全球' 
    END AS app_typ,
    CASE WHEN pvp = 1 THEN '单机' WHEN pvp = 2 THEN 'PVP' END AS pvp_type,
    a.rank_name,
    d.name AS type,
    total_match,
    card_name AS player,
    match_times,
    get_player,
    win,
    score,
    twoN,
    twoG,
    layupN,
    layupG,
    dunkN,
    dunkG,
    threeN,
    threeG,
    blockG,
    stealG,
    rebG,
    asitN,
    mark,
    intercept,
    groundN,
    ballT,
    twoN_open,
    twoG_open,
    threeN_open,
    threeG_open,
    downN,
    downND,
    blockND,
    a.day
FROM (
    SELECT 
        a.day, pvp, rank_name, GET_JSON_OBJECT(player, '$.player') AS player, type, 
        COUNT(DISTINCT a.mbga_uid, a.session) AS match_times,
        COUNT(DISTINCT CASE WHEN GET_JSON_OBJECT(player, '$.state') = '1' THEN CONCAT(a.mbga_uid, a.user_id) ELSE NULL END) AS get_player,
        COUNT(CASE WHEN result = 'true' THEN log_t ELSE NULL END) AS win, 
        SUM(score) AS score,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoN') AS INT)) AS twoN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoG') AS INT)) AS twoG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.layupN') AS INT)) AS layupN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.layupG') AS INT)) AS layupG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.dunkN') AS INT)) AS dunkN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.dunkG') AS INT)) AS dunkG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeN') AS INT)) AS threeN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeG') AS INT)) AS threeG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.blockG') AS INT)) AS blockG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.stealG') AS INT)) AS stealG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.rebG') AS INT)) AS rebG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.asitN') AS INT)) AS asitN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.intercept') AS INT)) AS intercept,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.ballT') AS INT)) AS ballT,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.groundN') AS INT)) AS groundN,
        SUM(CAST(GET_JSON_OBJECT(player, '$.mark') AS DOUBLE)) / 10000 AS mark,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoN_open') AS INT)) AS twoN_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoG_open') AS INT)) AS twoG_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeN_open') AS INT)) AS three_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeG_open') AS INT)) AS threeG_open,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.downN') AS INT)) AS downN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.downND') AS INT)) AS downND,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.blockND') AS INT)) AS blockND
    FROM (
        SELECT 
            player, mbga_uid, user_id, session, score, result, adata, 
            CAST(SPLIT(star, '#')[0] AS INT) AS star, '1' AS a1, type, log_t, day
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6)
          AND ai = 'false'
          AND type = 'RankH3V3'
    ) a 
    JOIN (
        SELECT 
            day, mbga_uid, user_id, card_id, 
            COUNT(DISTINCT CASE WHEN LENGTH(skill1) BETWEEN 4 AND 6 THEN skill1 ELSE NULL END) AS skill
        FROM g${app_id}.daily_user_card_snapshot
        LATERAL VIEW EXPLODE(SPLIT(skill, ',|\\\[|\\\]')) a_tar AS skill1
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) AND status = 1
        GROUP BY mbga_uid, user_id, card_id, day
        HAVING skill >= 58
    ) c ON a.mbga_uid = c.mbga_uid AND a.user_id = c.user_id AND a.day = c.day 
        AND GET_JSON_OBJECT(player, '$.player') = c.card_id
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1
    LEFT JOIN (
        SELECT session, COUNT(DISTINCT result) AS pvp
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND ai = 'false'
        GROUP BY session
    ) b ON a.session = b.session
    WHERE a.star >= d.min_star AND a.star <= d.max_star
    GROUP BY a.day, pvp, GET_JSON_OBJECT(player, '$.player'), type, rank_name
) a
LEFT JOIN (
    SELECT day, rank_name, COUNT(DISTINCT session) AS total_match
    FROM (
        SELECT session, MAX(CAST(SPLIT(star, '#')[0] AS INT)) AS star, '1' AS a1, day
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6)
          AND ai = 'false'
          AND type = 'RankH3V3'
        GROUP BY session, day
    ) a
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1
    WHERE a.star >= d.min_star AND a.star <= d.max_star
    GROUP BY day, rank_name
) c ON a.day = c.day AND a.rank_name = c.rank_name
LEFT JOIN g${app_id}.dim_match d ON a.type = d.id
LEFT JOIN g${app_id}.dim_card_h5 e ON a.player = e.card_id
WHERE pvp = 2;


--------------------------------------------------------------------------------
-- 2. 巅峰赛_源 (Peak Source)
--------------------------------------------------------------------------------
INSERT INTO g23002013_dev.tmp_peak_detail 
SELECT 
    CASE 
        WHEN ${app_id} = '23002013' THEN '繁体' 
        WHEN ${app_id} = '33002013' THEN '韩国' 
        WHEN ${app_id} = '63002013' THEN '全球' 
    END AS app_typ,
    a.day, d.name AS type, total_match, card_name, match_times, ban, mvp, win, score, 
    twoN, twoG, layupN, layupG, dunkN, dunkG, threeN, threeG, blockG, stealG, rebG, asitN, intercept, ballT, groundN, mark
FROM (
    SELECT 
        a.day, GET_JSON_OBJECT(player, '$.player') AS player, type, 
        COUNT(DISTINCT a.session) AS match_times,
        COUNT(DISTINCT CASE WHEN mvp = 1 THEN a.session ELSE NULL END) AS mvp,
        COUNT(DISTINCT CASE WHEN result = 'true' THEN a.session ELSE NULL END) AS win, 
        SUM(score) AS score,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoN') AS INT)) AS twoN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.twoG') AS INT)) AS twoG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.layupN') AS INT)) AS layupN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.layupG') AS INT)) AS layupG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.dunkN') AS INT)) AS dunkN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.dunkG') AS INT)) AS dunkG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeN') AS INT)) AS threeN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.threeG') AS INT)) AS threeG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.blockG') AS INT)) AS blockG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.stealG') AS INT)) AS stealG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.rebG') AS INT)) AS rebG,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.asitN') AS INT)) AS asitN,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.intercept') AS INT)) AS intercept,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.ballT') AS INT)) AS ballT,
        SUM(CAST(GET_JSON_OBJECT(adata, '$.groundN') AS INT)) AS groundN,
        SUM(CAST(GET_JSON_OBJECT(player, '$.mark') AS DOUBLE)) / 10000 AS mark
    FROM (
        SELECT DISTINCT 
            player, mbga_uid, user_id, mvp, session, score, result, adata, 
            CAST(SPLIT(star, '#')[1] AS INT) AS star, '1' AS a1, type, log_t, day
        FROM g${app_id}.daily_match_snapshot 
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
          AND ai = 'false' AND type = 'SUMMITH3V3'
    ) a 
    GROUP BY a.day, GET_JSON_OBJECT(player, '$.player'), type
) a
LEFT JOIN (
    SELECT type, COUNT(DISTINCT session) AS total_match, day
    FROM g${app_id}.daily_match_snapshot 
    WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) AND ai = 'false' AND type = 'SUMMITH3V3'
    GROUP BY type, day
) c ON a.type = c.type AND a.day = c.day
LEFT JOIN (
    SELECT 
        COUNT(DISTINCT GET_JSON_OBJECT(a_tar, '$.match_id')) AS ban, 
        REGEXP_REPLACE(GET_JSON_OBJECT(a_tar, '$.ban'), '\\[|\\]|"', '') AS player, 
        day
    FROM g${app_id}.daily_game_log 
    WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6) 
      AND a_typ = 'peak_fight'
    GROUP BY GET_JSON_OBJECT(a_tar, '$.ban'), day
) b ON a.player = b.player AND a.day = b.day
LEFT JOIN g${app_id}.dim_match d ON a.type = d.id
LEFT JOIN g${app_id}.dim_card_h5 e ON a.player = e.card_id;


--------------------------------------------------------------------------------
-- 6. 进攻技能_源 (Offensive Skills Source)
--------------------------------------------------------------------------------
-- Part 6a: Detailed Skills
INSERT INTO g23002013_dev.tmp_skill_2 
SELECT 
    CASE 
        WHEN ${app_id} = '23002013' THEN '繁体' 
        WHEN ${app_id} = '33002013' THEN '韩国' 
        WHEN ${app_id} = '63002013' THEN '全球' 
    END AS app_typ,
    a.day, rank_name, card_name, skillid, SUM(skilln) AS skilln, SUM(skillg) AS skillg,
    SUM(vacantn) AS vacantn, SUM(vacantg) AS vacantg, SUM(bejamn) AS bejamn, SUM(bejamg) AS bejamg, 
    SUM(seriousn) AS seriousn, SUM(seriousg) AS seriousg,
    SUM(serious2n) AS serious2n, SUM(serious2g) AS serious2g, SUM(blocknd) AS blocknd, SUM(blockgd) AS blockgd
FROM (
    SELECT 
        GET_JSON_OBJECT(player, '$.player') AS player, mbga_uid, user_id, session, score, result,
        CAST(SPLIT(star, '#')[0] AS INT) AS star, '1' AS a1, type, log_t, day,
        REGEXP_REPLACE(SPLIT(data1, ',')[0], '"', '') AS skillid,
        REGEXP_REPLACE(SPLIT(data1, ',')[1], 'skillN|\\"|\\:', '') AS skillN,
        REGEXP_REPLACE(SPLIT(data1, ',')[2], 'skillG|\\"|\\:|\\}|\\]', '') AS skillG,
        REGEXP_REPLACE(SPLIT(data1, ',')[3], 'vacantN|\\"|\\:|\\}|\\]', '') AS vacantN,
        REGEXP_REPLACE(SPLIT(data1, ',')[4], 'vacantG|\\"|\\:|\\}|\\]', '') AS vacantG,
        REGEXP_REPLACE(SPLIT(data1, ',')[5], 'beJamN|\\"|\\:|\\}|\\]', '') AS beJamN,
        REGEXP_REPLACE(SPLIT(data1, ',')[6], 'beJamG|\\"|\\:|\\}|\\]', '') AS beJamG,
        REGEXP_REPLACE(SPLIT(data1, ',')[7], 'seriousN|\\"|\\:|\\}|\\]', '') AS seriousN,
        REGEXP_REPLACE(SPLIT(data1, ',')[8], 'seriousG|\\"|\\:|\\}|\\]', '') AS seriousG,
        REGEXP_REPLACE(SPLIT(data1, ',')[9], 'serious2N|\\"|\\:|\\}|\\]', '') AS serious2N,
        REGEXP_REPLACE(SPLIT(data1, ',')[10], 'serious2G|\\"|\\:|\\}|\\]', '') AS serious2G,
        REGEXP_REPLACE(SPLIT(data1, ',')[11], 'blockND|\\"|\\:|\\}|\\]', '') AS blockND,
        REGEXP_REPLACE(SPLIT(data1, ',')[12], 'blockGD|\\"|\\:|\\}|\\]', '') AS blockGD
    FROM g${app_id}.daily_match_snapshot
    LATERAL VIEW EXPLODE(SPLIT(newskill, '"skillid":')) a_tar AS data1
    WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6)
      AND ai = 'false'
      AND type = 'RankH3V3'
) a 
LEFT JOIN (SELECT *, '1' AS a1 FROM g23002013.dim_rank) d ON a.a1 = d.a1
LEFT JOIN g23002013.dim_card_h5 e ON a.player = e.card_id
WHERE a.star >= d.min_star AND a.star <= d.max_star
  AND skillN <> 0 AND skillN >= blockND 
  AND LENGTH(skillid) >= 8 
GROUP BY a.day, rank_name, card_name, skillid;

-- Part 6b: Base Skills
INSERT INTO g23002013_dev.tmp_skill_base 
SELECT 
    CASE 
        WHEN ${app_id} = '23002013' THEN '繁体' 
        WHEN ${app_id} = '33002013' THEN '韩国' 
        WHEN ${app_id} = '63002013' THEN '全球' 
    END AS app_typ,
    a.day, a.rank_name, a.card_name, all_matchs, skillid, matchs, skilln, skillg
FROM (
    SELECT a.day, rank_name, card_name, COUNT(DISTINCT log_t, user_id) AS all_matchs
    FROM (
        SELECT 
            GET_JSON_OBJECT(player, '$.player') AS player, mbga_uid, user_id, session, score, result,
            CAST(SPLIT(star, '#')[0] AS INT) AS star, '1' AS a1, type, log_t, day
        FROM g${app_id}.daily_match_snapshot
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6)
          AND ai = 'false'
          AND type = 'RankH3V3'
    ) a 
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1
    LEFT JOIN g${app_id}.dim_card_h5 e ON a.player = e.card_id
    WHERE a.star >= d.min_star AND a.star <= d.max_star
    GROUP BY a.day, rank_name, card_name
) a
LEFT JOIN (
    SELECT 
        a.day, rank_name, card_name, skillid, COUNT(DISTINCT log_t, user_id) AS matchs, 
        SUM(skilln) AS skilln, SUM(skillg) AS skillg
    FROM (
        SELECT 
            GET_JSON_OBJECT(player, '$.player') AS player, mbga_uid, user_id, session, score, result,
            CAST(SPLIT(star, '#')[0] AS INT) AS star, '1' AS a1, type, log_t, day,
            REGEXP_REPLACE(SPLIT(data1, ',')[0], '"', '') AS skillid,
            REGEXP_REPLACE(SPLIT(data1, ',')[1], 'skillN|\\"|\\:', '') AS skillN,
            REGEXP_REPLACE(SPLIT(data1, ',')[2], 'skillG|\\"|\\:|\\}|\\]', '') AS skillG
        FROM g${app_id}.daily_match_snapshot
        LATERAL VIEW EXPLODE(SPLIT(skill, '"skillid":')) a_tar AS data1
        WHERE SUBSTR(day, 1, 6) = SUBSTR(${dateitme1}, 1, 6)
          AND ai = 'false'
          AND type = 'RankH3V3'
    ) a 
    LEFT JOIN (SELECT *, '1' AS a1 FROM g${app_id}.dim_rank) d ON a.a1 = d.a1
    LEFT JOIN g${app_id}.dim_card_h5 e ON a.player = e.card_id
    WHERE a.star >= d.min_star AND a.star <= d.max_star
      AND LENGTH(skillid) >= 8
    GROUP BY a.day, rank_name, card_name, skillid
) b ON a.day = b.day AND a.rank_name = b.rank_name AND a.card_name = b.card_name;


--------------------------------------------------------------------------------
-- 最终报表输出 (Final Report Exports)
--------------------------------------------------------------------------------

-- 1. 排位_源
SELECT 
    app_typ, rank_name AS 段位, type AS 比赛类型, total_match AS 赛事总次数, card_name AS 球员, 
    match_times AS 上阵次数, ban, win AS 获胜, score AS 总得分,
    twoN AS 总两分投篮, twoG AS 总两分进球, layupN AS 总上篮, layupG AS 总上篮进球, 
    dunkN AS 总灌篮, dunkG AS 总灌篮进球, threeN AS 总三分投篮, threeG AS 总三分进球,
    blockG AS 总盖帽, stealG AS 总抢断, rebG AS 总篮板, asitN AS 总助攻, mark AS 评分, 
    intercept AS 截球, groundN AS 地板球, ballT AS 持球, twoN_open AS 空位中投,
    twoG_open AS 空位中投命中, threeN_open AS 空位三分, threeG_open AS 空位三分命中, 
    downN AS 晃倒, downND AS 被晃倒, blockND AS 被盖帽, twoN_bejam AS 干扰中投出手,
    twoG_bejam AS 干扰中投进球, threeN_bejam AS 干扰三分出手, threeG_bejam AS 干扰三分进球, 
    interND AS 被截球, stealND AS 被抢断, day
FROM g23002013_dev.tmp_match_banpick;

-- 1.5. 天赋50%_源
SELECT 
    app_typ, pvp_type AS PVP类型, rank_name AS 段位, type AS 比赛类型, total_match AS 赛事总次数, 
    player AS 球员, match_times AS 上阵次数, get_player AS 获得上阵次数, win AS 获胜, score AS 总得分, 
    twoN AS 总两分投篮, twoG AS 总两分进球, layupN AS 总上篮,
    layupG AS 总上篮进球, dunkN AS 总灌篮, dunkG AS 总灌篮进球, threeN AS 总三分投篮, 
    threeG AS 总三分进球, blockG AS 总盖帽, stealG AS 总抢断,
    rebG AS 总篮板, asitN AS 总助攻, mark AS 评分, intercept AS 截球, groundN AS 地板球, 
    ballT AS 持球, twoN_open AS 空位中投, twoG_open AS 空位中投命中,
    threeN_open AS 空位三分, threeG_open AS 空位三分命中, downN AS 晃倒, downND AS 被晃倒, 
    blockND AS 被盖帽, day
FROM g23002013_dev.tmp_match;

-- 2. 巅峰赛_源
SELECT 
    app_typ, day, type AS 类型, total_match AS 总场次, card_name AS 球员, match_times AS 上阵次数, 
    ban AS 被ban次数, mvp, win AS 获胜次数, score AS 得分, twoN AS 两分出手, twoG AS 两分进球, 
    layupN AS 上篮出手, layupG AS 上篮进球, dunkN AS 灌篮出手, dunkG AS 灌篮进球, 
    threeN AS 三分出手, threeG AS 三分进球, blockG AS 总盖帽, stealG AS 总抢断, 
    rebG AS 总篮板, asitN AS 总助攻, intercept AS 截球, ballT AS 持球时间, groundN AS 地板球, mark AS 评分
FROM g23002013_dev.tmp_peak_detail;

-- 6. 进攻技能_源
SELECT 
    app_typ, day, rank_name AS 段位, card_name AS 球员, skillid AS 技能id, skilln AS 技能使用, 
    skillg AS 技能成功, vacantn AS 空位出手, vacantg AS 空位进球, bejamn AS 干扰出手, bejamg AS 干扰进球, 
    seriousn AS 严重干扰出手, seriousg AS 严重干扰进球, serious2n AS 严重干扰2出手, serious2g AS 严重干扰2进球, 
    blocknd AS 成功盖帽次数, blockgd AS 盖帽次数 
FROM g23002013_dev.tmp_skill_2;

SELECT 
    app_typ, day, rank_name AS 段位, card_name AS 球员, all_matchs AS 总场次,
    skillid AS 技能id, matchs AS 使用场次, skilln AS 技能使用, skillg AS 技能成功 
FROM g23002013_dev.tmp_skill_base;


--------------------------------------------------------------------------------
-- 4. 熟练度_源 (Proficiency Source)
--------------------------------------------------------------------------------
SELECT 
    '繁体' AS app_typ,
    a.day, a.card_id, d.name AS card_name, c.name AS rank_name,
    CASE 
        WHEN proficient BETWEEN 0 AND 99 THEN 'a入门'
        WHEN proficient BETWEEN 100 AND 499 THEN 'b见习'
        WHEN proficient BETWEEN 500 AND 1999 THEN 'c熟练'
        WHEN proficient BETWEEN 2000 AND 4999 THEN 'd资深'
        WHEN proficient BETWEEN 5000 AND 9999 THEN 'e大师'
        WHEN proficient >= 10000 THEN 'f传说' 
    END AS proficiency,
    COUNT(DISTINCT a.user_id) AS uu, 
    SUM(times) AS times, 
    SUM(win) AS win
FROM (
    SELECT 
        day, type, user_id, mbga_uid, GET_JSON_OBJECT(player, '$.player') AS card_id, 
        COUNT(1) AS times, 
        COUNT(CASE WHEN result = 'true' THEN log_t ELSE NULL END) AS win, 
        MAX(CAST(SPLIT(star, '#')[0] AS INT)) AS star
    FROM g23002013.daily_match_snapshot
    WHERE SUBSTR(day, 1, 6) = 202504
      AND ai = 'false'
      AND type = 'RankH3V3'
    GROUP BY day, type, user_id, mbga_uid, GET_JSON_OBJECT(player, '$.player')
) a
JOIN (
    SELECT 
        day, mbga_uid, user_id, card_id, 
        CAST(GET_JSON_OBJECT(extra_info, '$.proficient') AS INT) AS proficient,
        (LENGTH(skill) - LENGTH(REGEXP_REPLACE(skill, ',', ''))) - (LENGTH(skill) - LENGTH(REGEXP_REPLACE(skill, '\\[\\]', ''))) / 2 + 1 AS skill
    FROM g23002013.daily_user_card_snapshot
    WHERE SUBSTR(day, 1, 6) = 202504 AND status = '1'
) b ON a.day = b.day AND a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid AND a.card_id = b.card_id
LEFT JOIN g23002013.dim_rankname c ON a.star = c.id
LEFT JOIN g23002013.dim_card d ON a.card_id = d.id
WHERE skill >= 58
GROUP BY 
    a.day, a.card_id, d.name, c.name,
    CASE 
        WHEN proficient BETWEEN 0 AND 99 THEN 'a入门'
        WHEN proficient BETWEEN 100 AND 499 THEN 'b见习'
        WHEN proficient BETWEEN 500 AND 1999 THEN 'c熟练'
        WHEN proficient BETWEEN 2000 AND 4999 THEN 'd资深'
        WHEN proficient BETWEEN 5000 AND 9999 THEN 'e大师'
        WHEN proficient >= 10000 THEN 'f传说' 
    END;
