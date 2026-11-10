/*
================================================================================
Game: Saint Seiya 2
Region: CN
Description: Weekly activity statistics tracking for various in-game events.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  1. Theme Summon (主题召唤)
  2. Force Purchase (跨服原力 -- 购买)
  3. Force Exchange (跨服原力 -- 兑换)
  4. Jackpot Purchase (转盘 -- 购买)
  5. Jackpot Exchange (转盘 -- 兑换)
  6. Soul Box Consumption (魂匣 -- 消耗)
  7. Wish Pool (许愿池)
  8. Cumulative Recharge Selection Items (累计充值自选道具)
  9. Cumulative Diamond Consumption (累计钻石消耗)
  10. Daily Recharge Gear Count (每日充值档位人数)
  11. Average Diamond Stock (人均存钻)
  12. Recharge Type Distribution (礼包/月卡/钻石分布)
  13. Weekly New/Old User Stats (wsales/wnu/wpu)
  14. Diamond Consumption Detail (耗钻)
  15. Arena Team Composition (阵容)
  16. Treasure Hunt (寻宝)
  17. Treasure Hunt Rewards (寻宝获得)
  18. Guardian Activity (守护活动)
  19. Guardian Exchange (守护兑换)

Parameters: 
  - ${datetime0}: Reference day (activity start or snapshot day)
  - ${datetime1}: Start date of the stats period
  - ${datetime2}: End date of the stats period
  - ${datetime3}: Secondary end date for exchange/long-term activities
================================================================================
*/

-- Configuration
SET odps.sql.hive.compatible=True; 

-- Data Points Documentation:
-- 1. 道具名：欧米伽主题召唤券 id：40431 (参与欧米伽主题召唤)
-- 2. 道具名：冥域主题召唤券 id：40432 (参与冥域主题召唤)
-- 3. 道具名：圣域主题召唤券 id：40433 (参与圣域主题召唤)
-- 4. 道具名：北欧主题召唤券 id：40434 (参与北欧主题召唤)

-- Note: money is total diamonds

--------------------------------------------------------------------------------
-- Section: Theme Summon (主题召唤)
--------------------------------------------------------------------------------
SELECT
    p1.zonetype,
    p1.viptype,
    COUNT(DISTINCT p1.user_id) AS au,
    COUNT(DISTINCT p2.user_id) AS pu,
    SUM(p2.toolnum) AS toolnum,
    SUM(p2.toldiamond) - SUM(COALESCE(p2.paiddiamond, 0)) AS freediamond,
    SUM(COALESCE(p2.paiddiamond, 0)) AS paiddiamond,
    '' AS backdiamond
FROM (
    SELECT
        s1.user_id,
        s3.zone,
        s2.beforelevel,
        s2.beforevip,
        CASE
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
            ELSE '疑似内网用户'
        END AS zonetype,
        CASE
            WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
            WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
            WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
            WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
            WHEN s2.beforevip = 18 THEN '鲸鱼'
            ELSE '非R或跨服新角色'
        END AS viptype
    FROM (
        -- AU
        SELECT
            user_id,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 活动前的等级与VIP
        SELECT
            user_id,
            CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
            MAX(level) AS beforelevel,
            MAX(vip) AS beforevip
        FROM g10000001.daily_user_snapshot
        WHERE day = ${datetime0}
            AND zone <> ''
        GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s4 ON s3.zone = s4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) s5 ON s1.user_id = s5.user_id
    WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
        AND s5.user_id IS NULL
) p1
LEFT JOIN (
    SELECT
        s1.user_id,
        SUM(CASE WHEN s1.obj2 IN ('item@3904', 'item@40431', 'item@40432', 'item@40433', 'item@40434') THEN s1.diff2 END) AS toolnum,
        SUM(CASE WHEN s1.obj2 = 'dmp:money' THEN -s1.diff2 END) AS toldiamond,
        SUM(CASE WHEN s1.obj2 = 'dmp:paidmoney' THEN -s1.diff2 END) AS paiddiamond
    FROM (
        SELECT
            day,
            log_t,
            user_id,
            a_typ,
            u1.obj,
            u3.obj2,
            CAST(u3.diff2 AS INT) AS diff2
        FROM (
            SELECT
                day,
                zone,
                log_t,
                user_id,
                a_typ,
                a_rst,
                d3.obj,
                d3.diff
            FROM g10000001.daily_game_log d1
            LATERAL VIEW EXPLODE(a_rst) d2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') d3 AS obj, diff
            WHERE obj IN ('item@3904', 'item@40431', 'item@40432', 'item@40433', 'item@40434')
                AND diff > 0
                AND a_typ = 'activity_buy'
                AND day BETWEEN ${datetime1} AND ${datetime2}
        ) u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj2, diff2
    ) s1
    GROUP BY s1.user_id
) p2 ON p1.user_id = p2.user_id
GROUP BY p1.zonetype, p1.viptype;


--------------------------------------------------------------------------------
-- Section: Force Purchase (跨服原力 -- 购买)
--------------------------------------------------------------------------------
SELECT
    p1.zonetype,
    p1.viptype,
    COUNT(DISTINCT p1.user_id) AS au,
    COUNT(DISTINCT p2.user_id) AS pu,
    COUNT(DISTINCT CASE WHEN p2.toolnum >= 268 THEN p2.user_id END) AS pu2,
    SUM(p2.toolnum) AS toolnum,
    SUM(p2.toldiamond) - SUM(COALESCE(p2.paiddiamond, 0)) AS freediamond,
    SUM(COALESCE(p2.paiddiamond, 0)) AS paiddiamond,
    SUM(-p3.backdiamond) AS backdiamond,
    SUM(sales) AS sales
FROM (
    SELECT
        s1.user_id,
        s2.beforemergezone,
        s3.zone,
        s2.beforelevel,
        s2.beforevip,
        CASE
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
            ELSE '疑似内网用户'
        END AS zonetype,
        CASE
            WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
            WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
            WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
            WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
            WHEN s2.beforevip = 18 THEN '鲸鱼'
            ELSE '非R或跨服新角色'
        END AS viptype
    FROM (
        -- AU
        SELECT
            user_id,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 活动前的等级与VIP
        SELECT
            user_id,
            CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
            MAX(level) AS beforelevel,
            MAX(vip) AS beforevip
        FROM g10000001.daily_user_snapshot
        WHERE day = ${datetime0}
            AND zone <> ''
        GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s4 ON s3.zone = s4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) s5 ON s1.user_id = s5.user_id
    WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
        AND s5.user_id IS NULL
) p1
LEFT JOIN (
    -- 跨服原力购买
    SELECT
        s1.user_id,
        SUM(CASE WHEN s1.obj2 = 'item@40185' THEN s1.diff2 END) AS toolnum,
        SUM(CASE WHEN s1.obj2 = 'dmp:money' THEN -s1.diff2 END) AS toldiamond,
        SUM(CASE WHEN s1.obj2 = 'dmp:paidmoney' THEN -s1.diff2 END) AS paiddiamond
    FROM (
        SELECT
            day,
            log_t,
            user_id,
            a_typ,
            u1.obj,
            u1.diff,
            u3.obj2,
            u3.diff2
        FROM (
            SELECT
                day,
                zone,
                log_t,
                user_id,
                a_typ,
                a_rst,
                d3.obj,
                d3.diff
            FROM g10000001.daily_game_log d1
            LATERAL VIEW EXPLODE(a_rst) d2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') d3 AS obj, diff
            WHERE obj IN ('item@40185')
                AND diff > 0
                AND a_typ = 'activity_buy'
                AND day BETWEEN ${datetime1} AND ${datetime2}
        ) u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj2, diff2
    ) s1
    GROUP BY s1.user_id
) p2 ON p1.user_id = p2.user_id
LEFT JOIN (
    -- 红包返钻
    SELECT
        user_id,
        SUM(CASE WHEN s1.obj = 'dmp:money' THEN CAST(s1.diff AS INT) END) AS backdiamond
    FROM (
        SELECT
            day,
            log_t,
            user_id,
            a_typ,
            SIZE(a_rst) / 2 AS times,
            u3.obj,
            u3.diff
        FROM g10000001.daily_game_log u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj, diff
        WHERE a_typ = 'item_use'
            AND GET_JSON_OBJECT(a_rst[0], '$.obj') IN ('item@5271')
            AND CAST(GET_JSON_OBJECT(a_rst[0], '$.diff') AS INT) < 0
            AND u3.obj = 'dmp:money'
            AND u3.diff > 0
            AND day BETWEEN ${datetime1} AND ${datetime2}
    ) s1
    GROUP BY user_id
) p3 ON p1.user_id = p3.user_id
LEFT JOIN (
    -- 充值
    SELECT
        s1.user_id,
        SUM(IF(s3.transaction_id IS NOT NULL, s3.paid_lnum / 10, s1.rmb)) AS sales
    FROM (
        SELECT
            day,
            zone,
            record_time,
            user_id,
            money AS giftid_,
            money AS diamond,
            rmb,
            order_id
        FROM g10000001.bi_order_logs
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
    ) s1
    LEFT JOIN (
        SELECT *
        FROM g10000001_dev.orderidblacklist
    ) s2 ON s1.order_id = s2.orderid
    LEFT JOIN (
        SELECT
            lid,
            transaction_id,
            paid_lnum,
            free_lnum
        FROM g10000001.consume_vc
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
    ) s3 ON s1.order_id = s3.transaction_id
    WHERE s2.orderid IS NULL
    GROUP BY s1.user_id
) p4 ON p1.user_id = p4.user_id
GROUP BY p1.zonetype, p1.viptype;

--------------------------------------------------------------------------------
-- Section: Force Exchange (跨服原力 -- 兑换)
--------------------------------------------------------------------------------
SELECT
    CASE
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END AS zonetype,
    CASE
        WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.beforevip = 18 THEN '鲸鱼'
        ELSE '非R或跨服新角色'
    END AS viptype,
    s1.obtain_obj,
    COUNT(DISTINCT s1.user_id) AS pu,
    SUM(-consume_diff) AS consume_diff,
    SUM(obtain_diff) AS obtain_diff
FROM (
    -- 跨服原力兑换
    SELECT
        d1.user_id,
        beforemergezone,
        REGEXP_REPLACE(obj2, '[\\{\\[\\}\\]\\@\\:\\_a-zA-Z]', '') AS obtain_obj,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday,
        SUM(CAST(diff AS INT)) AS consume_diff,
        SUM(CAST(diff2 AS INT)) AS obtain_diff
    FROM (
        SELECT
            day,
            CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
            log_t,
            user_id,
            a_typ,
            u1.obj,
            u1.diff,
            u3.obj2,
            u3.diff2
        FROM (
            SELECT
                day,
                zone,
                log_t,
                user_id,
                a_typ,
                a_rst,
                e3.obj,
                e3.diff
            FROM g10000001.daily_game_log e1
            LATERAL VIEW EXPLODE(a_rst) e2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') e3 AS obj, diff
            WHERE e3.obj IN ('item@40094')
                AND diff < 0
                AND a_typ = 'activity_exchange'
                AND day BETWEEN ${datetime1} AND ${datetime3}
        ) u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj2, diff2
        WHERE u3.obj2 NOT IN ('item@40094')
    ) d1
    GROUP BY
        user_id,
        beforemergezone,
        REGEXP_REPLACE(obj2, '[\\{\\[\\}\\]\\@\\:\\_a-zA-Z]', '')
) s1
LEFT JOIN (
    -- 活动前的等级与VIP
    SELECT
        user_id,
        CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
        MAX(level) AS beforelevel,
        MAX(vip) AS beforevip
    FROM g10000001.daily_user_snapshot
    WHERE day = ${datetime0}
        AND zone <> ''
    GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
) s2 ON s1.user_id = s2.user_id
LEFT JOIN (
    -- 区服
    SELECT
        user_id,
        SPLIT(zone, '_s')[0] AS zonetype,
        CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
        CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
    FROM g10000001.bi_player
    WHERE day >= ${datetime3}
        AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
        AND CONCAT(user_id, zone) NOT IN (
            '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
            '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
            '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
        )
    GROUP BY user_id, SPLIT(zone, '_s')[0]
) s3 ON s1.user_id = s3.user_id
LEFT JOIN (
    -- 开服时间维表
    SELECT
        zone,
        MIN(day) AS day,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
    FROM (
        SELECT
            zone,
            FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
            COUNT(DISTINCT user_id) AS nu
        FROM g10000001.bi_player
        WHERE day >= ${datetime3}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND zone <> 'ios_s190'
        GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
    ) u1
    WHERE nu >= 15
    GROUP BY zone
    UNION ALL
    SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
) s4 ON s3.zone = s4.zone
LEFT JOIN (
    SELECT DISTINCT user_id
    FROM g10000001.user_blacklist
) s5 ON s1.user_id = s5.user_id
WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
    AND s5.user_id IS NULL
GROUP BY
    CASE
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END,
    CASE
        WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.beforevip = 18 THEN '鲸鱼'
        ELSE '非R或跨服新角色'
    END,
    s1.obtain_obj;



--跨服原力--消耗
/*
SELECT day,CONCAT_WS('-',SUBSTR(day,1,4),SUBSTR(day,5,2),SUBSTR(day,7,2)) loginday
,zone,IF(CAST(zone AS INT)>=1000,CAST(zone AS INT)-1000,zone) zoneid
,log_t,user_id,a_typ,d1.obj,d3.obj2,d3.diff
FROM (
SELECT day,zone,log_t,user_id,a_typ,a_rst,e3.obj,e3.diff
FROM g10000001.daily_game_log e1
LATERAL VIEW explode(a_rst) e2 as rst
LATERAL VIEW json_tuple(rst,'obj','diff') e3 as obj,diff
where obj IN ('item@40185') 
AND diff<0 AND a_typ='gacha_force'
AND day IN (20200328,20200329) 
) d1
LATERAL VIEW explode(a_rst) d2 as rst
LATERAL VIEW json_tuple(rst,'obj','diff') d3 as obj2,diff
*/





--------------------------------------------------------------------------------
-- Section: Jackpot Purchase (转盘 -- 购买)
--------------------------------------------------------------------------------
SELECT
    p1.zonetype,
    p1.viptype,
    COUNT(DISTINCT p1.user_id) AS au,
    COUNT(DISTINCT p2.user_id) AS pu,
    SUM(p2.toolnum) AS toolnum,
    SUM(p2.toldiamond) - SUM(COALESCE(p2.paiddiamond, 0)) AS freediamond,
    SUM(COALESCE(p2.paiddiamond, 0)) AS paiddiamond,
    SUM(-p3.backdiamond) AS backdiamond,
    SUM(sales) AS sales
FROM (
    SELECT
        s1.user_id,
        s3.zone,
        s2.beforelevel,
        s2.beforevip,
        CASE
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
            ELSE '疑似内网用户'
        END AS zonetype,
        CASE
            WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
            WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
            WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
            WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
            WHEN s2.beforevip = 18 THEN '鲸鱼'
            ELSE '非R或跨服新角色'
        END AS viptype
    FROM (
        -- AU
        SELECT
            user_id,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 活动前的等级与VIP
        SELECT
            user_id,
            CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
            MAX(level) AS beforelevel,
            MAX(vip) AS beforevip
        FROM g10000001.daily_user_snapshot
        WHERE day = ${datetime0}
            AND zone <> ''
        GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s4 ON s3.zone = s4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) s5 ON s1.user_id = s5.user_id
    WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
        AND s5.user_id IS NULL
) p1
LEFT JOIN (
    SELECT
        s1.user_id,
        SUM(CASE WHEN s1.obj2 = 'item@3787' THEN s1.diff2 END) AS toolnum,
        SUM(CASE WHEN s1.obj2 = 'dmp:money' THEN -s1.diff2 END) AS toldiamond,
        SUM(CASE WHEN s1.obj2 = 'dmp:paidmoney' THEN -s1.diff2 END) AS paiddiamond
    FROM (
        SELECT
            day,
            log_t,
            user_id,
            a_typ,
            u1.obj,
            u3.obj2,
            CAST(u3.diff2 AS INT) AS diff2
        FROM (
            SELECT
                day,
                zone,
                log_t,
                user_id,
                a_typ,
                a_rst,
                d3.obj,
                d3.diff
            FROM g10000001.daily_game_log d1
            LATERAL VIEW EXPLODE(a_rst) d2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') d3 AS obj, diff
            WHERE obj IN ('item@3787')
                AND diff > 0
                AND a_typ = 'activity_buy'
                AND day BETWEEN ${datetime1} AND ${datetime2}
        ) u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj2, diff2
    ) s1
    GROUP BY s1.user_id
) p2 ON p1.user_id = p2.user_id
LEFT JOIN (
    -- 转盘返钻
    SELECT
        user_id,
        SUM(CASE WHEN s1.obj = 'dmp:money' THEN CAST(s1.diff AS INT) END) AS backdiamond
    FROM (
        SELECT
            day,
            log_t,
            user_id,
            a_typ,
            SIZE(a_rst) / 2 AS times,
            u3.obj,
            u3.diff
        FROM g10000001.daily_game_log u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj, diff
        WHERE GET_JSON_OBJECT(a_rst[0], '$.obj') IN ('item@3787')
            AND CAST(GET_JSON_OBJECT(a_rst[0], '$.diff') AS INT) < 0
            AND u3.obj = 'dmp:money'
            AND u3.diff > 0
            AND a_typ = 'activity_jackpot'
            AND day BETWEEN ${datetime1} AND ${datetime2}
    ) s1
    GROUP BY user_id
) p3 ON p1.user_id = p3.user_id
LEFT JOIN (
    -- 充值
    SELECT
        s1.user_id,
        SUM(IF(s3.transaction_id IS NOT NULL, s3.paid_lnum / 10, s1.rmb)) AS sales
    FROM (
        SELECT
            day,
            zone,
            record_time,
            user_id,
            money AS giftid_,
            money AS diamond,
            rmb,
            order_id
        FROM g10000001.bi_order_logs
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
    ) s1
    LEFT JOIN (
        SELECT *
        FROM g10000001_dev.orderidblacklist
    ) s2 ON s1.order_id = s2.orderid
    LEFT JOIN (
        SELECT
            lid,
            transaction_id,
            paid_lnum,
            free_lnum
        FROM g10000001.consume_vc
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
    ) s3 ON s1.order_id = s3.transaction_id
    WHERE s2.orderid IS NULL
    GROUP BY s1.user_id
) p4 ON p1.user_id = p4.user_id
GROUP BY p1.zonetype, p1.viptype;


--------转盘 --兑换
SET odps.sql.hive.compatible=True; 
--------------------------------------------------------------------------------
-- Section: Jackpot Exchange (转盘 -- 兑换)
--------------------------------------------------------------------------------
SELECT
    CASE
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END AS zonetype,
    CASE
        WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.beforevip = 18 THEN '鲸鱼'
        ELSE '非R或跨服新角色'
    END AS viptype,
    s1.consume_obj,
    s1.obtain_obj,
    COUNT(DISTINCT s1.user_id) AS pu,
    -SUM(consume_diff) AS consume_diff,
    SUM(obtain_diff) AS obtain_diff,
    '' AS obtain_name
FROM (
    -- 转盘
    SELECT
        d1.user_id,
        REGEXP_REPLACE(obj, '[\\{\\[\\}\\]\\@\\:\\_a-zA-Z]', '') AS consume_obj,
        IF(obj2 = 'dmp:gold', obj2, REGEXP_REPLACE(obj2, '[\\{\\[\\}\\]\\@\\:\\_a-zA-Z]', '')) AS obtain_obj,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday,
        SUM(CAST(diff AS INT)) AS consume_diff,
        SUM(CAST(diff2 AS INT)) AS obtain_diff
    FROM (
        SELECT
            day,
            log_t,
            user_id,
            a_typ,
            u1.obj,
            u1.diff,
            u3.obj2,
            u3.diff2
        FROM (
            SELECT
                day,
                zone,
                log_t,
                user_id,
                a_typ,
                a_rst,
                e3.obj,
                e3.diff
            FROM g10000001.daily_game_log e1
            LATERAL VIEW EXPLODE(a_rst) e2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') e3 AS obj, diff
            WHERE SUBSTR(obj, 1, 7) = 'item@40'
                AND LENGTH(obj) = 10
                AND diff < 0
                AND a_typ = 'activity_exchange'
                AND day BETWEEN ${datetime1} AND ${datetime3}
        ) u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj2, diff2
    ) d1
    GROUP BY
        d1.user_id,
        REGEXP_REPLACE(obj, '[\\{\\[\\}\\]\\@\\:\\_a-zA-Z]', ''),
        IF(obj2 = 'dmp:gold', obj2, REGEXP_REPLACE(obj2, '[\\{\\[\\}\\]\\@\\:\\_a-zA-Z]', ''))
) s1
LEFT JOIN (
    -- 活动前的等级与VIP
    SELECT
        user_id,
        CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
        MAX(level) AS beforelevel,
        MAX(vip) AS beforevip
    FROM g10000001.daily_user_snapshot
    WHERE day = ${datetime0}
        AND zone <> ''
    GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
) s2 ON s1.user_id = s2.user_id
LEFT JOIN (
    -- 区服
    SELECT
        user_id,
        SPLIT(zone, '_s')[0] AS zonetype,
        CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
        CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
    FROM g10000001.bi_player
    WHERE day >= ${datetime3}
        AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
        AND CONCAT(user_id, zone) NOT IN (
            '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
            '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
            '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
        )
    GROUP BY user_id, SPLIT(zone, '_s')[0]
) s3 ON s1.user_id = s3.user_id
LEFT JOIN (
    -- 开服时间维表
    SELECT
        zone,
        MIN(day) AS day,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
    FROM (
        SELECT
            zone,
            FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
            COUNT(DISTINCT user_id) AS nu
        FROM g10000001.bi_player
        WHERE day >= ${datetime3}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND zone <> 'ios_s190'
        GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
    ) u1
    WHERE nu >= 15
    GROUP BY zone
    UNION ALL
    SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
) s4 ON s3.zone = s4.zone
LEFT JOIN (
    SELECT DISTINCT user_id
    FROM g10000001.user_blacklist
) s5 ON s1.user_id = s5.user_id
WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
    AND s5.user_id IS NULL
GROUP BY
    CASE
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END,
    CASE
        WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.beforevip = 18 THEN '鲸鱼'
        ELSE '非R或跨服新角色'
    END,
    s1.consume_obj,
    s1.obtain_obj
HAVING SUM(obtain_diff) > 0;


--消耗 ----这个不对,a_rst的3787会生成十条,所有记录乘以10
/*
SELECT day,CONCAT_WS('-',SUBSTR(day,1,4),SUBSTR(day,5,2),SUBSTR(day,7,2)) loginday
,zone,IF(CAST(zone AS INT)>=1000,CAST(zone AS INT)-1000,zone) zoneid
,log_t,user_id,a_typ,d1.obj,d3.obj2,d3.diff
FROM (
SELECT day,zone,log_t,user_id,a_typ,a_rst,e3.obj,e3.diff
FROM g10000001.daily_game_log e1
LATERAL VIEW explode(a_rst) e2 as rst
LATERAL VIEW json_tuple(rst,'obj','diff') e3 as obj,diff
where obj IN ('item@3787') 
AND diff<0 AND a_typ='activity_jackpot'
AND day IN (20200405,20200406)
*/


--魂匣--消耗
SET odps.sql.hive.compatible=True; 
--------------------------------------------------------------------------------
-- Section: Soul Box (魂匣)
--------------------------------------------------------------------------------
SELECT
    l1.day,
    l1.zonetype,
    l1.viptype,
    l1.card_id,
    l2.au,
    l1.pu,
    l1.toolnum,
    l1.paiddiamond,
    l1.freediamond
FROM (
    SELECT
        p1.day,
        p1.zonetype,
        p1.viptype,
        p2.card_id,
        COUNT(DISTINCT p1.user_id) AS au,
        COUNT(DISTINCT p2.user_id) AS pu,
        SUM(p2.toolnum) AS toolnum,
        AVG(paiddiamondper) AS paiddiamondper,
        SUM(p2.toolnum) * 40 * AVG(paiddiamondper) AS paiddiamond,
        SUM(p2.toolnum) * 40 * (1 - AVG(paiddiamondper)) AS freediamond
    FROM (
        SELECT
            s1.day,
            s1.user_id,
            s3.zone,
            s2.beforelevel,
            s2.beforevip,
            CASE
                WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
                WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
                WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
                WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
                WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
                ELSE '疑似内网用户'
            END AS zonetype,
            CASE
                WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
                WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
                WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
                WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
                WHEN s2.beforevip = 18 THEN '鲸鱼'
                ELSE '非R或跨服新角色'
            END AS viptype
        FROM (
            -- AU
            SELECT
                day,
                user_id,
                CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday
            FROM g10000001.daily_game_log
            WHERE day = ${datetime2}
            GROUP BY day, user_id
        ) s1
        LEFT JOIN (
            -- 活动前的等级与VIP
            SELECT
                user_id,
                CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
                MAX(level) AS beforelevel,
                MAX(vip) AS beforevip
            FROM g10000001.daily_user_snapshot
            WHERE day = ${datetime2}
                AND zone <> ''
            GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
        ) s2 ON s1.user_id = s2.user_id
        LEFT JOIN (
            -- 区服
            SELECT
                user_id,
                SPLIT(zone, '_s')[0] AS zonetype,
                CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
                CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND CONCAT(user_id, zone) NOT IN (
                    '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                    '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                    '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
                )
            GROUP BY user_id, SPLIT(zone, '_s')[0]
        ) s3 ON s1.user_id = s3.user_id
        LEFT JOIN (
            -- 开服时间维表
            SELECT
                zone,
                MIN(day) AS day,
                CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
            FROM (
                SELECT
                    zone,
                    FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                    COUNT(DISTINCT user_id) AS nu
                FROM g10000001.bi_player
                WHERE day >= ${datetime2}
                    AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                    AND zone <> 'ios_s190'
                GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
            ) u1
            WHERE nu >= 15
            GROUP BY zone
            UNION ALL
            SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
        ) s4 ON s3.zone = s4.zone
        LEFT JOIN (
            SELECT DISTINCT user_id
            FROM g10000001.user_blacklist
        ) s5 ON s1.user_id = s5.user_id
        WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
            AND s5.user_id IS NULL
    ) p1
    INNER JOIN (
        -- 魂匣参与
        SELECT
            s1.user_id,
            s1.card_id,
            SUM(-diff) AS toolnum
        FROM (
            SELECT
                day,
                log_t,
                user_id,
                a_typ,
                REGEXP_REPLACE(GET_JSON_OBJECT(a_tar, '$.card_id'), '[\\"\\,\\{\\[\\}\\]\\_a-zA-Z]', '') AS card_id,
                a_rst,
                d3.obj,
                d3.diff
            FROM g10000001.daily_game_log d1
            LATERAL VIEW EXPLODE(a_rst) d2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') d3 AS obj, diff
            WHERE a_typ = 'soulbox'
                AND day = ${datetime2}
                AND obj = 'item@3789'
            UNION ALL
            SELECT
                day,
                log_t,
                user_id,
                a_typ,
                'total' AS card_id,
                a_rst,
                d3.obj,
                d3.diff
            FROM g10000001.daily_game_log d1
            LATERAL VIEW EXPLODE(a_rst) d2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') d3 AS obj, diff
            WHERE a_typ = 'soulbox'
                AND day = ${datetime2}
                AND obj = 'item@3789'
        ) s1
        GROUP BY s1.user_id, s1.card_id
    ) p2 ON p1.user_id = p2.user_id
    LEFT JOIN (
        -- 魂匣钻石比例
        SELECT
            s1.user_id,
            SUM(CASE WHEN s1.obj2 = 'dmp:paidmoney' THEN CAST(-s1.diff2 AS INT) END)
            / SUM(CASE WHEN s1.obj2 IN ('dmp:money') THEN CAST(-s1.diff2 AS INT) END) AS paiddiamondper
        FROM (
            SELECT
                day,
                log_t,
                user_id,
                a_typ,
                u1.obj,
                u1.diff,
                u3.obj2,
                u3.diff2
            FROM (
                SELECT
                    day,
                    zone,
                    log_t,
                    user_id,
                    a_typ,
                    a_rst,
                    d3.obj,
                    d3.diff
                FROM g10000001.daily_game_log d1
                LATERAL VIEW EXPLODE(a_rst) d2 AS rst
                LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') d3 AS obj, diff
                WHERE obj IN ('item@3789')
                    AND diff > 0
                    AND a_typ = 'activity_buy'
                    AND day = ${datetime2}
            ) u1
            LATERAL VIEW EXPLODE(a_rst) u2 AS rst
            LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj2, diff2
        ) s1
        GROUP BY s1.user_id
    ) p3 ON p1.user_id = p3.user_id
    GROUP BY p1.day, p1.zonetype, p1.viptype, p2.card_id
) l1
LEFT JOIN (
    SELECT
        CASE
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
            ELSE '疑似内网用户'
        END AS zonetype,
        CASE
            WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
            WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
            WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
            WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
            WHEN s2.beforevip = 18 THEN '鲸鱼'
            ELSE '非R或跨服新角色'
        END AS viptype,
        COUNT(DISTINCT s1.user_id) AS au
    FROM (
        -- AU
        SELECT
            user_id,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday
        FROM g10000001.daily_game_log
        WHERE day = ${datetime2}
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 活动前的等级与VIP
        SELECT
            user_id,
            CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
            MAX(level) AS beforelevel,
            MAX(vip) AS beforevip
        FROM g10000001.daily_user_snapshot
        WHERE day = ${datetime2}
            AND zone <> ''
        GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s4 ON s3.zone = s4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) s5 ON s1.user_id = s5.user_id
    WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
        AND s5.user_id IS NULL
        AND s2.beforevip >= 8
    GROUP BY
        CASE
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
            ELSE '疑似内网用户'
        END,
        CASE
            WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
            WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
            WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
            WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
            WHEN s2.beforevip = 18 THEN '鲸鱼'
            ELSE '非R或跨服新角色'
        END
) l2 ON l1.zonetype = l2.zonetype AND l1.viptype = l2.viptype;




--------------------------------------------------------------------------------
-- Section: Wish Pool (许愿池)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    p1.zonetype,
    p1.viptype,
    COALESCE(p2.index, 0) AS index,
    SUM(p5.sales) AS sales,
    COUNT(DISTINCT p1.user_id) AS au,
    COUNT(DISTINCT p2.user_id) AS au_join,
    COUNT(DISTINCT p5.user_id) AS pu,
    AVG(COALESCE(p4.tolmoney, 0)) AS totaldiamond,
    PERCENTILE(COALESCE(p4.tolmoney, 0), 0.1) AS percentile10,
    PERCENTILE(COALESCE(p4.tolmoney, 0), 0.25) AS first_quartile,
    PERCENTILE(COALESCE(p4.tolmoney, 0), 0.5) AS second_quartile,
    PERCENTILE(COALESCE(p4.tolmoney, 0), 0.75) AS third_quartile,
    PERCENTILE(COALESCE(p4.tolmoney, 0), 0.9) AS percentile90
FROM (
    SELECT
        s1.user_id,
        s2.beforemergezone,
        s3.zone,
        s2.beforelevel,
        s2.beforevip,
        CASE
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
            WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
            ELSE '疑似内网用户'
        END AS zonetype,
        CASE
            WHEN s2.beforevip BETWEEN 1 AND 8 THEN '小R'
            WHEN s2.beforevip BETWEEN 9 AND 12 THEN '中R'
            WHEN s2.beforevip BETWEEN 13 AND 15 THEN '大R'
            WHEN s2.beforevip BETWEEN 16 AND 17 THEN '超R'
            WHEN s2.beforevip = 18 THEN '鲸鱼'
            ELSE '非R或跨服新角色'
        END AS viptype
    FROM (
        -- AU
        SELECT
            user_id,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday
        FROM g10000001.daily_game_log
        WHERE day IN (${datetime1}, ${datetime2})
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 活动前的等级与VIP
        SELECT
            user_id,
            CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS beforemergezone,
            MAX(level) AS beforelevel,
            MAX(vip) AS beforevip
        FROM g10000001.daily_user_snapshot
        WHERE day = ${datetime0}
            AND zone <> ''
        GROUP BY user_id, CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s4 ON s3.zone = s4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) s5 ON s1.user_id = s5.user_id
    WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
        AND s5.user_id IS NULL
) p1
LEFT JOIN (
    SELECT
        day,
        log_t,
        zone,
        user_id,
        index
    FROM (
        SELECT
            day,
            log_t,
            zone,
            user_id,
            CAST(GET_JSON_OBJECT(a_tar, '$.index') AS INT) AS index,
            ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY CAST(GET_JSON_OBJECT(a_tar, '$.index') AS INT) DESC) AS rank
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND a_typ = 'wish'
    ) u1
    WHERE rank = 1
) p2 ON p1.user_id = p2.user_id
LEFT JOIN (
    SELECT
        user_id,
        tolmoney
    FROM (
        SELECT
            log_t,
            user_id,
            CAST(before AS INT) AS tolmoney,
            ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY log_t) AS rank
        FROM g10000001.daily_game_log
        LATERAL VIEW EXPLODE(a_rst) e2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'before') e3 AS obj, before
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND obj IN ('dmp:money')
    ) u2
    WHERE rank = 1
) p4 ON p1.user_id = p4.user_id
LEFT JOIN (
    SELECT
        user_id,
        SUM(CAST(GET_JSON_OBJECT(a_tar, '$.spend') AS INT)) AS sales
    FROM g10000001.daily_game_log
    WHERE day BETWEEN ${datetime1} AND ${datetime2}
        AND a_typ = 'charge'
    GROUP BY user_id
) p5 ON p1.user_id = p5.user_id
GROUP BY
    COALESCE(p2.index, 0),
    p1.zonetype,
    p1.viptype
ORDER BY index;


--------------------------------------------------------------------------------
-- Section: Lineup (阵容)
--------------------------------------------------------------------------------
-- (Queries for Lineup analysis go here)

--------------------------------------------------------------------------------
-- Section: Accumulated Charge Optional Items (累计充值自选道具)
--------------------------------------------------------------------------------
SELECT
    day,
    index,
    obj,
    diff,
    usernum,
    IF(DENSE_RANK() OVER (PARTITION BY day, index ORDER BY usernum DESC) = 1, '非自选道具', '自选道具') AS item_type
FROM (
    SELECT
        day,
        index,
        obj,
        diff,
        COUNT(DISTINCT user_id) AS usernum
    FROM (
        SELECT
            day,
            user_id,
            CAST(GET_JSON_OBJECT(a_tar, '$.index') AS INT) AS index,
            SPLIT(obj, '@')[1] AS obj,
            CAST(diff AS INT) AS diff
        FROM g10000001.daily_game_log
        LATERAL VIEW EXPLODE(a_rst) b AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
        WHERE a_typ = 'activity'
            AND day >= 20200403
            AND GET_JSON_OBJECT(a_tar, '$.activity_id') = 2
            AND GET_JSON_OBJECT(a_tar, '$.index') IN ('198', '328', '648', '1296', '2592', '5184', '7776', '11111')
    ) d
    GROUP BY day, index, obj, diff
) s
ORDER BY day, index, usernum DESC;


--------------------------------------------------------------------------------
-- Section: Accumulated Diamond Consumption (累计钻石消耗)
--------------------------------------------------------------------------------
SELECT
    day,
    index,
    obj,
    diff,
    usernum,
    IF(DENSE_RANK() OVER (PARTITION BY day, index ORDER BY usernum DESC) = 1, '非自选道具', '自选道具') AS item_type
FROM (
    SELECT
        day,
        index,
        obj,
        diff,
        COUNT(DISTINCT user_id) AS usernum
    FROM (
        SELECT
            day,
            user_id,
            CAST(GET_JSON_OBJECT(a_tar, '$.index') AS INT) AS index,
            IF(obj = 'dmp:gold', 'dmp:gold', SPLIT(obj, '@')[1]) AS obj,
            CAST(diff AS INT) AS diff
        FROM g10000001.daily_game_log
        LATERAL VIEW EXPLODE(a_rst) b AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
        WHERE a_typ = 'activity'
            AND day >= 20200403
            AND GET_JSON_OBJECT(a_tar, '$.activity_id') = 3
    ) d
    GROUP BY day, index, obj, diff
) s
ORDER BY day, index, usernum DESC;



IFNA(VLOOKUP(C2,[SEIYA2CN_WKLYREPORT_DATA_v3.xlsx]DIM_ITEM!$A:$B,2,0)
,IFNA(VLOOKUP(C2,[SEIYA2CN_WKLYREPORT_DATA_v3.xlsx]DIM_HEROCARD!$A:$B,2,0),
 IFNA(VLOOKUP(C2,[SEIYA2CN_WKLYREPORT_DATA_v3.xlsx]DIM_FORCECARD!$A:$B,2,0),C2)))











--------------------------------------------------------------------------------
-- Section: Daily Recharge Tiers (每日充值档位人数)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    day,
    CASE
        WHEN spend BETWEEN 0 AND 197 THEN '198_below'
        WHEN spend BETWEEN 198 AND 327 THEN '198'
        WHEN spend BETWEEN 328 AND 647 THEN '328'
        WHEN spend BETWEEN 648 AND 1295 THEN '648'
        WHEN spend BETWEEN 1296 AND 2591 THEN '1296'
        WHEN spend BETWEEN 2592 AND 5183 THEN '2592'
        WHEN spend BETWEEN 5184 AND 7775 THEN '5184'
        WHEN spend BETWEEN 7776 AND 11109 THEN '7776'
        WHEN spend BETWEEN 11110 AND 12959 THEN '11110'
        WHEN spend BETWEEN 12960 AND 49999 THEN '12960'
        WHEN spend > 49999 THEN '50000'
    END AS index,
    COUNT(DISTINCT user_id) AS u,
    SUM(spend) AS s
FROM (
    SELECT
        day,
        user_id,
        SUM(CAST(GET_JSON_OBJECT(a_tar, '$.spend') AS INT)) AS spend
    FROM g10000001.daily_game_log
    WHERE day >= 20200403
        AND a_typ = 'charge'
    GROUP BY day, user_id
) p
GROUP BY
    day,
    CASE
        WHEN spend BETWEEN 0 AND 197 THEN '198_below'
        WHEN spend BETWEEN 198 AND 327 THEN '198'
        WHEN spend BETWEEN 328 AND 647 THEN '328'
        WHEN spend BETWEEN 648 AND 1295 THEN '648'
        WHEN spend BETWEEN 1296 AND 2591 THEN '1296'
        WHEN spend BETWEEN 2592 AND 5183 THEN '2592'
        WHEN spend BETWEEN 5184 AND 7775 THEN '5184'
        WHEN spend BETWEEN 7776 AND 11109 THEN '7776'
        WHEN spend BETWEEN 11110 AND 12959 THEN '11110'
        WHEN spend BETWEEN 12960 AND 49999 THEN '12960'
        WHEN spend > 49999 THEN '50000'
    END;




--------------------------------------------------------------------------------
-- Section: Average Diamond Stock (人均存钻)
--------------------------------------------------------------------------------
SELECT
    p1.day,
    PERCENTILE((CASE WHEN COALESCE(p2.vip, 0) = 0 THEN p1.diamond END), 0.5) AS v0,
    PERCENTILE((CASE WHEN p2.vip = 1 THEN p1.diamond END), 0.5) AS v1,
    PERCENTILE((CASE WHEN p2.vip = 2 THEN p1.diamond END), 0.5) AS v2,
    PERCENTILE((CASE WHEN p2.vip = 3 THEN p1.diamond END), 0.5) AS v3,
    PERCENTILE((CASE WHEN p2.vip = 4 THEN p1.diamond END), 0.5) AS v4,
    PERCENTILE((CASE WHEN p2.vip = 5 THEN p1.diamond END), 0.5) AS v5,
    PERCENTILE((CASE WHEN p2.vip = 6 THEN p1.diamond END), 0.5) AS v6,
    PERCENTILE((CASE WHEN p2.vip = 7 THEN p1.diamond END), 0.5) AS v7,
    PERCENTILE((CASE WHEN p2.vip = 8 THEN p1.diamond END), 0.5) AS v8,
    PERCENTILE((CASE WHEN p2.vip = 9 THEN p1.diamond END), 0.5) AS v9,
    PERCENTILE((CASE WHEN p2.vip = 10 THEN p1.diamond END), 0.5) AS v10,
    PERCENTILE((CASE WHEN p2.vip = 11 THEN p1.diamond END), 0.5) AS v11,
    PERCENTILE((CASE WHEN p2.vip = 12 THEN p1.diamond END), 0.5) AS v12,
    PERCENTILE((CASE WHEN p2.vip = 13 THEN p1.diamond END), 0.5) AS v13,
    PERCENTILE((CASE WHEN p2.vip = 14 THEN p1.diamond END), 0.5) AS v14,
    PERCENTILE((CASE WHEN p2.vip = 15 THEN p1.diamond END), 0.5) AS v15,
    PERCENTILE((CASE WHEN p2.vip = 16 THEN p1.diamond END), 0.5) AS v16,
    PERCENTILE((CASE WHEN p2.vip = 17 THEN p1.diamond END), 0.5) AS v17,
    PERCENTILE((CASE WHEN p2.vip = 18 THEN p1.diamond END), 0.5) AS v18
FROM (
    -- 提取日结钻量
    SELECT
        s1.day,
        s1.user_id,
        s1.diamond
    FROM (
        SELECT
            u1.day,
            u1.user_id,
            u2.diamond,
            ROW_NUMBER() OVER(PARTITION BY u1.day, u1.user_id ORDER BY u2.day DESC) AS rank
        FROM (
            -- 取每一个统计日的近7日登陆用户
            SELECT
                d1.day,
                d2.user_id,
                COUNT(1) AS cnt
            FROM (
                SELECT
                    day,
                    CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS sday,
                    COUNT(1) AS cnt,
                    '1' AS t
                FROM g10000001.bi_login_logs_day
                WHERE day BETWEEN 20200301 AND 20200617
                GROUP BY day
            ) d1
            LEFT JOIN (
                SELECT
                    day,
                    CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS sday,
                    user_id,
                    COUNT(1) AS cnt,
                    '1' AS t
                FROM g10000001.bi_login_logs_day
                WHERE day BETWEEN 20200223 AND 20200617
                GROUP BY day, user_id
            ) d2 ON d1.t = d2.t
            WHERE DATEDIFF(d1.sday, d2.sday) BETWEEN 0 AND 6
            GROUP BY d1.day, d2.user_id
        ) u1
        LEFT JOIN (
            SELECT
                d1.day,
                d1.user_id,
                d1.balance AS diamond
            FROM (
                SELECT
                    day,
                    user_id,
                    balance,
                    ROW_NUMBER() OVER(PARTITION BY day, user_id ORDER BY record_time DESC) AS rank
                FROM g10000001.bi_money_list
                WHERE day BETWEEN 20200301 AND 20200617
                    AND money_type_id = 2
            ) d1
            WHERE d1.rank = 1
        ) u2 ON u1.user_id = u2.user_id
        LEFT JOIN g10000001_dev.user_blacklist u3 ON u1.user_id = u3.user_id
        WHERE u1.day >= u2.day
            AND u3.user_id IS NULL
    ) s1
    WHERE s1.rank = 1
) p1
LEFT JOIN (
    -- 人工划分的vip等级
    SELECT
        s1.day,
        s1.user_id,
        CASE
            WHEN s1.rmb BETWEEN 6 AND 11 THEN 1
            WHEN s1.rmb BETWEEN 12 AND 29 THEN 2
            WHEN s1.rmb BETWEEN 30 AND 49 THEN 3
            WHEN s1.rmb BETWEEN 50 AND 99 THEN 4
            WHEN s1.rmb BETWEEN 100 AND 199 THEN 5
            WHEN s1.rmb BETWEEN 200 AND 299 THEN 6
            WHEN s1.rmb BETWEEN 300 AND 499 THEN 7
            WHEN s1.rmb BETWEEN 500 AND 699 THEN 8
            WHEN s1.rmb BETWEEN 700 AND 999 THEN 9
            WHEN s1.rmb BETWEEN 1000 AND 1499 THEN 10
            WHEN s1.rmb BETWEEN 1500 AND 1999 THEN 11
            WHEN s1.rmb BETWEEN 2000 AND 2999 THEN 12
            WHEN s1.rmb BETWEEN 3000 AND 5999 THEN 13
            WHEN s1.rmb BETWEEN 6000 AND 11999 THEN 14
            WHEN s1.rmb BETWEEN 12000 AND 19999 THEN 15
            WHEN s1.rmb BETWEEN 20000 AND 29999 THEN 16
            WHEN s1.rmb BETWEEN 30000 AND 49999 THEN 17
            WHEN s1.rmb >= 50000 THEN 18
            ELSE 0
        END AS vip
    FROM (
        SELECT
            u1.day,
            u2.user_id,
            u2.rmb,
            ROW_NUMBER() OVER(PARTITION BY u1.day, u2.user_id ORDER BY u2.day DESC) AS rank
        FROM (
            SELECT
                day,
                COUNT(1) AS cnt,
                '1' AS t
            FROM g10000001.bi_order_logs
            WHERE day > 0
            GROUP BY day
        ) u1
        LEFT JOIN (
            SELECT
                day,
                user_id,
                SUM(rmb) OVER(PARTITION BY user_id ORDER BY day) AS rmb,
                '1' AS t
            FROM (
                SELECT
                    day,
                    user_id,
                    SUM(rmb) AS rmb
                FROM g10000001.bi_order_logs
                WHERE day > 0
                GROUP BY day, user_id
            ) d
        ) u2 ON u1.t = u2.t
        WHERE u1.day >= u2.day
    ) s1
    WHERE s1.rank = 1
) p2 ON p1.user_id = p2.user_id AND p1.day = p2.day
GROUP BY p1.day;




--------------------------------------------------------------------------------
-- Section: Monthly Card & Gift Pack Analysis (礼包与月卡分析)
--------------------------------------------------------------------------------
SELECT
    p1.day,
    CASE
        WHEN rmb = diamond / 10 AND p3.user_id IS NULL THEN '钻石'
        WHEN rmb = diamond / 10 AND p3.user_id IS NOT NULL THEN '月卡'
        WHEN rmb <> diamond / 10 AND p2.id = 39 THEN '月卡'
        ELSE '礼包'
    END AS charge_type,
    CASE
        WHEN rmb = diamond / 10 AND p3.user_id IS NOT NULL THEN CONCAT(rmb, '元档位月卡')
        WHEN rmb = diamond / 10 AND p3.user_id IS NULL THEN CONCAT(rmb, '元钻石')
        WHEN rmb <> diamond / 10 THEN COALESCE(p2.name, CONCAT('未知礼包', p2.id))
    END AS gear_type,
    SUM(p1.rmb) AS sales,
    COUNT(DISTINCT p1.user_id) AS pu
FROM (
    SELECT
        day,
        log_t,
        user_id,
        GET_JSON_OBJECT(a_tar, '$.index') AS giftid_,
        IF(GET_JSON_OBJECT(a_rst[0], '$.obj') = 'dmp:money', CAST(GET_JSON_OBJECT(a_rst[0], '$.diff') AS INT), 0) AS diamond,
        CAST(GET_JSON_OBJECT(a_tar, '$.spend') AS INT) AS rmb
    FROM g10000001.daily_game_log
    WHERE a_typ = 'charge'
        AND day >= 20200403
) p1
LEFT JOIN g10000001_dev.dim_giftpakage p2 ON p1.giftid_ = p2.id
LEFT JOIN (
    SELECT DISTINCT
        day,
        log_t,
        user_id
    FROM g10000001.daily_game_log
    WHERE a_typ = 'charge_mothscard'
        AND day >= 20200403
) p3 ON CONCAT(p1.log_t, p1.user_id) = CONCAT(p3.log_t, p3.user_id)
WHERE rmb <> 0
GROUP BY
    p1.day,
    CASE
        WHEN rmb = diamond / 10 AND p3.user_id IS NULL THEN '钻石'
        WHEN rmb = diamond / 10 AND p3.user_id IS NOT NULL THEN '月卡'
        WHEN rmb <> diamond / 10 AND p2.id = 39 THEN '月卡'
        ELSE '礼包'
    END,
    CASE
        WHEN rmb = diamond / 10 AND p3.user_id IS NOT NULL THEN CONCAT(rmb, '元档位月卡')
        WHEN rmb = diamond / 10 AND p3.user_id IS NULL THEN CONCAT(rmb, '元钻石')
        WHEN rmb <> diamond / 10 THEN COALESCE(p2.name, CONCAT('未知礼包', p2.id))
    END
ORDER BY charge_type;





--------------------------------------------------------------------------------
-- Section: Gift Pack User Type Analysis (礼包用户类型分析)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    s2.day,
    SPLIT(s1.zone, '_s')[1] AS zone,
    SPLIT(s1.zone, '_s')[0] AS zone_type,
    CASE
        WHEN s1.zone = s1.zonearray[0] THEN 'NU'
        ELSE CONCAT('OU', '_', s1.platarray[0])
    END AS user_type,
    SUM(s4.dsales) AS wsales,
    COUNT(DISTINCT s1.user_id) AS wnu,
    COUNT(DISTINCT s4.user_id) AS wpu
FROM (
    SELECT
        u1.phone_device,
        u1.user_id,
        u1.creroleday,
        u1.plat,
        u1.zone,
        u2.platarray,
        u2.zonearray,
        u1.record_time
    FROM (
        SELECT
            d1.phone_device,
            d1.user_id,
            d1.plat,
            d1.zone,
            d1.creroleday,
            d1.record_time
        FROM (
            SELECT
                phone_device,
                SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] AS plat,
                zone,
                user_id,
                record_time,
                FROM_UNIXTIME(record_time, 'yyyy-MM-dd') AS creroleday,
                ROW_NUMBER() OVER(PARTITION BY phone_device, user_id ORDER BY CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS dup
            FROM g10000001.bi_player
            WHERE day = 20200630
                AND zone <> ''
        ) d1
        WHERE d1.dup = 1
    ) u1
    LEFT JOIN (
        SELECT
            d1.phone_device,
            COLLECT_LIST(d1.plat) AS platarray,
            COLLECT_LIST(d1.zone) AS zonearray
        FROM (
            SELECT
                m1.phone_device,
                m1.user_id,
                m1.record_time,
                m1.plat,
                m1.zone,
                ROW_NUMBER() OVER(PARTITION BY m1.phone_device ORDER BY m1.record_time) AS user_rank
            FROM (
                SELECT
                    phone_device,
                    SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] AS plat,
                    zone,
                    user_id,
                    record_time,
                    ROW_NUMBER() OVER(PARTITION BY phone_device, user_id ORDER BY CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS dup
                FROM g10000001.bi_player
                WHERE day = 20200630
                    AND zone <> ''
            ) m1
            WHERE m1.dup = 1
        ) d1
        GROUP BY d1.phone_device
    ) u2 ON u1.phone_device = u2.phone_device
    WHERE CAST(FROM_UNIXTIME(u1.record_time, 'yyyyMMdd') AS INT) >= 20200101
) s1
INNER JOIN (
    SELECT
        zone,
        MIN(day) AS day,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
    FROM (
        SELECT
            zone,
            FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
            COUNT(DISTINCT user_id) AS nu
        FROM g10000001.bi_player
        WHERE day = 20200630
            AND zone <> 'ios_s190'
        GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
    ) u1
    WHERE nu >= 15
    GROUP BY zone
    UNION ALL
    SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
) s2 ON s1.zone = s2.zone
LEFT JOIN (
    SELECT DISTINCT user_id
    FROM g10000001_dev.user_blacklist
) s3 ON s1.user_id = s3.user_id
LEFT JOIN (
    SELECT
        day,
        CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS payday,
        user_id,
        SUM(rmb) AS dsales
    FROM g10000001.bi_order_logs d1
    LEFT JOIN g10000001_dev.orderidblacklist d2 ON d1.order_id = d2.orderid
    WHERE day >= 0
        AND d2.orderid IS NULL
    GROUP BY day, user_id
) s4 ON s1.user_id = s4.user_id
WHERE DATEDIFF(s1.creroleday, s2.openday) BETWEEN 0 AND 7
    AND (DATEDIFF(s4.payday, s2.openday) BETWEEN 0 AND 7 OR s4.payday IS NULL)
    AND s3.user_id IS NULL
GROUP BY
    s2.day,
    s1.zone,
    CASE
        WHEN s1.zone = s1.zonearray[0] THEN 'NU'
        ELSE CONCAT('OU', '_', s1.platarray[0])
    END;

--------------------------------------------------------------------------------
-- Section: Diamond Consumption (耗钻)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    l1.day,
    l1.a_typ,
    l1.totalmoney,
    l1.paidmoney,
    l2.backmoney
FROM (
    SELECT
        p1.day,
        CASE
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3787') THEN '转盘'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40185') THEN '跨服原力'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3904') THEN '主题召唤'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3789') THEN '魂匣'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40294') THEN '圣域宝箱'
            WHEN a_typ = 'activity_buy' AND obj2 NOT IN ('item@3789', 'item@40185', 'item@3787', 'item@40294', 'item@3904') THEN '其他活动'
            ELSE p2.atypname
        END AS a_typ,
        SUM(diff) AS totalmoney,
        SUM(CASE WHEN obj IN ('dmp:paidmoney') THEN diff END) AS paidmoney
    FROM (
        SELECT
            day,
            CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS loginday,
            user_id,
            a_typ,
            GET_JSON_OBJECT(a_rst[SIZE(a_rst) - 1], '$.obj') AS obj2,
            e3.obj,
            CAST(-e3.diff AS INT) AS diff
        FROM g10000001.daily_game_log e1
        LATERAL VIEW EXPLODE(a_rst) e2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') e3 AS obj, diff
        WHERE obj IN ('dmp:money', 'dmp:paidmoney')
            AND diff < 0
            AND day >= 20200310
    ) p1
    LEFT JOIN g10000001_dev.dim_atyp p2 ON TRIM(p1.a_typ) = TRIM(p2.atyp)
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) p3 ON p1.user_id = p3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) p4 ON p3.zone = p4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) p5 ON p1.user_id = p5.user_id
    WHERE DATEDIFF(p1.loginday, p4.openday) >= 7
        AND p5.user_id IS NULL
    GROUP BY
        p1.day,
        CASE
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3787') THEN '转盘'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40185') THEN '跨服原力'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3904') THEN '主题召唤'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3789') THEN '魂匣'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40294') THEN '圣域宝箱'
            WHEN a_typ = 'activity_buy' AND obj2 NOT IN ('item@3789', 'item@40185', 'item@3787', 'item@40294', 'item@3904') THEN '其他活动'
            ELSE p2.atypname
        END
) l1
LEFT JOIN (
    SELECT
        p1.day,
        CASE
            WHEN a_typ = 'item_use' AND a_rst0 IN ('item@5271') THEN '跨服原力'
            WHEN a_typ = 'activity_jackpot' AND a_rst0 IN ('item@3787') THEN '转盘'
            WHEN a_typ = 'gacha_force' AND a_rst0 IN ('item@40294') THEN '圣域宝箱'
            WHEN a_typ = 'wish' THEN '许愿池'
        END AS a_typ,
        SUM(diff) AS backmoney
    FROM (
        SELECT
            day,
            CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS loginday,
            user_id,
            GET_JSON_OBJECT(a_rst[0], '$.obj') AS a_rst0,
            a_typ,
            diff
        FROM g10000001.daily_game_log u1
        LATERAL VIEW EXPLODE(a_rst) u2 AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') u3 AS obj, diff
        WHERE a_typ IN ('item_use', 'activity_jackpot', 'gacha_force', 'wish')
            AND u3.obj = 'dmp:money'
            AND u3.diff > 0
            AND day >= 20200310
    ) p1
    LEFT JOIN (
        -- 区服
        SELECT
            user_id,
            SPLIT(zone, '_s')[0] AS zonetype,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
            CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone
        FROM g10000001.bi_player
        WHERE day >= ${datetime2}
            AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
            AND CONCAT(user_id, zone) NOT IN (
                '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
            )
        GROUP BY user_id, SPLIT(zone, '_s')[0]
    ) p3 ON p1.user_id = p3.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day >= ${datetime2}
                AND day = CONCAT_WS('', SPLIT(DATE_SUB(CURRENT_DATE(), 1), '-'))
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) p4 ON p3.zone = p4.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001.user_blacklist
    ) p5 ON p1.user_id = p5.user_id
    WHERE DATEDIFF(p1.loginday, p4.openday) >= 7
        AND p5.user_id IS NULL
    GROUP BY
        p1.day,
        CASE
            WHEN a_typ = 'item_use' AND a_rst0 IN ('item@5271') THEN '跨服原力'
            WHEN a_typ = 'activity_jackpot' AND a_rst0 IN ('item@3787') THEN '转盘'
            WHEN a_typ = 'gacha_force' AND a_rst0 IN ('item@40294') THEN '圣域宝箱'
            WHEN a_typ = 'wish' THEN '许愿池'
        END
) l2 ON l1.day = l2.day AND l1.a_typ = l2.a_typ;




--------------------------------------------------------------------------------
-- Section: Arena Team Composition (阵容)
--------------------------------------------------------------------------------
SELECT
    vip,
    COUNT(DISTINCT user_id) AS usernum,
    COUNT(log_t) AS times,
    COUNT(CASE WHEN result = 1 THEN log_t END) / COUNT(log_t) AS winper
FROM (
    -- 整理每人每场阵容(排序)，胜负等数据
    SELECT
        s1.log_t,
        s1.mbga_uid,
        s1.user_id,
        s1.lv,
        s1.result,
        s1.vip,
        SORT_ARRAY(COLLECT_LIST(COALESCE(s2.card_name, s1.memberid))) AS sortteam
    FROM (
        -- 清洗数据并列转行，方便排序
        SELECT
            u1.log_t,
            u1.a_typ,
            mbga_uid,
            user_id,
            u1.lv,
            result,
            memberid,
            u1.vip
        FROM (
            SELECT
                log_t,
                a_typ,
                mbga_uid,
                user_id,
                CAST(param1 AS INT) AS lv,
                CAST(param2 AS INT) AS vip,
                REGEXP_REPLACE(GET_JSON_OBJECT(a_tar, '$.team'), '\\[|\\]|\\\"|\\{|\\}', '') AS team,
                GET_JSON_OBJECT(a_tar, '$.resule') AS result
            FROM g10000001.daily_game_log
            WHERE day BETWEEN 20211227 AND 20211231
                AND a_typ = 'arena_fight'
        ) u1
        LATERAL VIEW EXPLODE(SPLIT(team, ',')) u2 AS memberid
    ) s1
    LEFT JOIN g10000001_dev.dim_card s2 ON s1.memberid = s2.card_id
    GROUP BY
        s1.log_t,
        s1.mbga_uid,
        s1.user_id,
        s1.lv,
        s1.result,
        s1.vip
) p
WHERE lv >= 150
    AND IF(ARRAY_CONTAINS(sortteam, '神圣金牛座·阿鲁迪巴'), 1, 0) = 1
GROUP BY vip
ORDER BY vip, times DESC, winper DESC;



--------------------------------------------------------------------------------
-- Section: Treasure Hunt (寻宝)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
-- 获取活动id
WITH view_act_method_id AS (
    SELECT
        act_method2,
        COUNT(1) AS cnt
    FROM (
        SELECT
            user_id,
            act_method2,
            SUM(-money) AS diamonds
        FROM g10000001.bi_money_list
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND money_type_id = 2
            AND money < 0
        GROUP BY user_id, act_method2
        HAVING diamonds = 25000
    ) s
    GROUP BY act_method2
    ORDER BY cnt DESC
    LIMIT 1
),
-- 获取活动礼包
view_act_package_id AS (
    SELECT
        money,
        SUM(rmb) AS sales
    FROM g10000001.bi_order_logs s1
    LEFT JOIN g10000001_dev.dim_giftpakage s2 ON s1.money = s2.id
    WHERE s1.day BETWEEN ${datetime1} AND ${datetime2}
        AND s1.money <> s1.rmb * 10
        AND s2.name LIKE '寻宝%'
    GROUP BY money
)
SELECT
    ${datetime1} AS staday,
    ${datetime2} AS endday,
    CASE
        WHEN p1.regdays BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN p1.regdays BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN p1.regdays BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN p1.regdays BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN p1.regdays > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END AS zonetype,
    CASE
        WHEN p1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN p1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN p1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN p1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN p1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    group,
    COUNT(DISTINCT user_id_login) AS au,
    COUNT(DISTINCT user_id_join) AS pu,
    COUNT(DISTINCT user_id_pay) AS pay_pu,
    SUM(diamonds) AS diamonds,
    COUNT(DISTINCT user_id_join) / COUNT(DISTINCT user_id_login) AS join_rate,
    SUM(times_tol) AS times_tol,
    SUM(times_diamond) AS times_diamond,
    IF(SUM(times_tol) - SUM(times_diamond) < 0, 0, SUM(times_tol) - SUM(times_diamond)) AS times_free,
    SUM(sales) AS sales
FROM (
    SELECT
        s1.user_id AS user_id_login,
        s2.user_id AS user_id_join,
        COALESCE(s2.times, 0) AS times_tol,
        s6.zone,
        s6.vip,
        DATEDIFF(s6.loginday, s7.openday) AS regdays,
        s3.diamonds,
        COALESCE(s3.diamonds / 50, 0) AS times_diamond,
        s4.user_id AS user_id_pay,
        s4.sales,
        CASE
            WHEN FLOOR(COALESCE(s5.max_lv, 0) / 10) < 12 THEN
                CONCAT_WS('~', CAST(FLOOR(COALESCE(s5.max_lv, 0) / 10) * 10 AS STRING), CAST(FLOOR(COALESCE(s5.max_lv, 0) / 10) * 10 + 9 AS STRING))
            ELSE '120层以上'
        END AS group
    FROM (
        -- 活跃用户
        SELECT
            user_id,
            COUNT(1) AS cnt
        FROM g10000001.bi_login_logs_day
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 参与次数
        SELECT
            user_id,
            SUM(CAST(GET_JSON_OBJECT(a_rst[0], '$.diff') AS INT)) AS times
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND a_typ = 'treasurehunt_start'
        GROUP BY user_id
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 耗钻
        SELECT
            u1.user_id,
            SUM(-u1.money) AS diamonds
        FROM g10000001.bi_money_list u1
        INNER JOIN (
            SELECT act_method2
            FROM view_act_method_id
        ) u2 ON u1.act_method2 = u2.act_method2
        WHERE u1.day BETWEEN ${datetime1} AND ${datetime2}
            AND u1.money_type_id = 2
            AND u1.money < 0
        GROUP BY u1.user_id
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 付费
        SELECT
            u1.user_id,
            SUM(IF(u3.transaction_id IS NOT NULL, u3.paid_lnum / 10, u1.rmb)) AS sales
        FROM (
            SELECT
                d1.day,
                d1.zone,
                d1.record_time,
                d1.user_id,
                d1.money AS giftid_,
                d1.money AS diamond,
                d1.rmb,
                d1.order_id
            FROM g10000001.bi_order_logs d1
            INNER JOIN view_act_package_id d2 ON d1.money = d2.money
            WHERE d1.day BETWEEN ${datetime1} AND ${datetime2}
                AND d1.money <> d1.rmb * 10
        ) u1
        LEFT JOIN (
            SELECT *
            FROM g10000001_dev.orderidblacklist
        ) u2 ON u1.order_id = u2.orderid
        LEFT JOIN (
            SELECT
                lid,
                transaction_id,
                paid_lnum,
                free_lnum
            FROM g10000001.consume_vc
            WHERE day BETWEEN ${datetime1} AND ${datetime2}
        ) u3 ON u1.order_id = u3.transaction_id
        WHERE u2.orderid IS NULL
        GROUP BY u1.user_id
    ) s4 ON s1.user_id = s4.user_id
    LEFT JOIN (
        SELECT
            user_id,
            MAX(CAST(REGEXP_REPLACE(SPLIT(a_tar, ':')[1], '}', '') AS INT)) AS max_lv
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND a_typ = 'treasurehunt_start'
        GROUP BY user_id
    ) s5 ON s1.user_id = s5.user_id
    LEFT JOIN (
        SELECT
            user_id,
            zone,
            name,
            vip,
            level,
            plat,
            regday,
            DATE_SUB(loginday, 3) AS loginday
        FROM (
            SELECT
                user_id,
                zone,
                name,
                vip,
                level,
                SPLIT(platform_user_id, '_')[0] AS plat,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS regday,
                CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS loginday,
                ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY CAST(SPLIT(zone, '_s')[1] AS INT)) AS depulication
            FROM g10000001.bi_player
            WHERE day = ${datetime2}
                AND CONCAT(user_id, zone) NOT IN (
                    '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                    '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                    '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
                )
        ) u1
        WHERE u1.depulication = 1
    ) s6 ON s1.user_id = s6.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day = ${datetime2}
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s7 ON s6.zone = s7.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001_dev.user_blacklist
    ) s8 ON s1.user_id = s8.user_id
    WHERE DATEDIFF(s6.loginday, s7.openday) >= 7
        AND s8.user_id IS NULL
) p1
GROUP BY
    CASE
        WHEN p1.regdays BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN p1.regdays BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN p1.regdays BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN p1.regdays BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN p1.regdays > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END,
    CASE
        WHEN p1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN p1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN p1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN p1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN p1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END,
    group;
;




--------------------------------------------------------------------------------
-- Section: Treasure Hunt Rewards (寻宝获得)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
WITH view_act_package_id AS (
    SELECT
        money,
        SUM(rmb) AS sales
    FROM g10000001.bi_order_logs s1
    LEFT JOIN g10000001_dev.dim_giftpakage s2 ON s1.money = s2.id
    WHERE s1.day BETWEEN ${datetime1} AND ${datetime2}
        AND s1.money <> s1.rmb * 10
        AND s2.name LIKE '寻宝%'
    GROUP BY money
)
SELECT
    lvrange,
    lv,
    obj,
    COUNT(1) AS total_count,
    SUM(CASE WHEN rank = 1 THEN 1 ELSE 0 END) AS first_time_count
FROM (
    SELECT
        user_id,
        log_t,
        CAST(REGEXP_REPLACE(SPLIT(a_tar, ':')[1], '}', '') AS INT) AS lv,
        SPLIT(GET_JSON_OBJECT(a_rst[2], '$.obj'), '@')[1] AS obj,
        ROW_NUMBER() OVER (PARTITION BY user_id, CAST(REGEXP_REPLACE(SPLIT(a_tar, ':')[1], '}', '') AS INT) ORDER BY log_t DESC) AS rank
    FROM (
        SELECT
            *
        FROM g10000001.daily_game_log
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND SPLIT(a_typ, '_')[0] = 'treasurehunt'
        UNION ALL
        SELECT
            u1.*
        FROM g10000001.daily_game_log u1
        INNER JOIN view_act_package_id u2 ON CAST(GET_JSON_OBJECT(u1.a_tar, '$.index') AS INT) = u2.money
        WHERE u1.day BETWEEN ${datetime1} AND ${datetime2}
            AND u1.a_typ = 'charge'
    ) d
    WHERE CAST(REGEXP_REPLACE(SPLIT(a_tar, ':')[1], '}', '') AS INT) % 10 = 0
        AND SIZE(a_rst) = 3
        AND a_typ = 'treasurehunt_start'
) p1
LEFT JOIN (
    SELECT
        user_id,
        FLOOR(max_lv / 10) + 1 AS lvrange
    FROM (
        SELECT
            user_id,
            MAX(CAST(REGEXP_REPLACE(SPLIT(a_tar, ':')[1], '}', '') AS INT)) AS max_lv
        FROM (
            SELECT
                *
            FROM g10000001.daily_game_log
            WHERE day BETWEEN ${datetime1} AND ${datetime2}
                AND SPLIT(a_typ, '_')[0] = 'treasurehunt'
            UNION ALL
            SELECT
                u1.*
            FROM g10000001.daily_game_log u1
            INNER JOIN view_act_package_id u2 ON CAST(GET_JSON_OBJECT(u1.a_tar, '$.index') AS INT) = u2.money
            WHERE u1.day BETWEEN ${datetime1} AND ${datetime2}
                AND u1.a_typ = 'charge'
        ) u1
        WHERE a_typ = 'treasurehunt_start'
        GROUP BY user_id
    ) s1
) p2 ON p1.user_id = p2.user_id
GROUP BY lvrange, lv, obj;



--------------------------------------------------------------------------------
-- Section: Guardian Activity (守护活动)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
-- 获取活动id
WITH view_act_method_id AS (
    SELECT
        act_method2,
        COUNT(1) AS cnt
    FROM (
        SELECT
            user_id,
            act_method2,
            SUM(-money) AS diamonds
        FROM g10000001.bi_money_list
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
            AND money_type_id = 2
            AND money < 0
        GROUP BY user_id, act_method2
        HAVING diamonds = 20000
    ) s
    GROUP BY act_method2
    ORDER BY cnt DESC
    LIMIT 1
),
-- 获取活动礼包
view_act_package_id AS (
    SELECT
        money,
        SUM(rmb) AS sales
    FROM g10000001.bi_order_logs s1
    LEFT JOIN g10000001_dev.dim_giftpakage s2 ON s1.money = s2.id
    WHERE s1.day BETWEEN ${datetime1} AND ${datetime2}
        AND s1.money <> s1.rmb * 10
        AND s2.name LIKE '守护召唤券特惠礼包%'
    GROUP BY money
)
SELECT
    ${datetime1} AS staday,
    ${datetime2} AS endday,
    CASE
        WHEN p1.regdays BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN p1.regdays BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN p1.regdays BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN p1.regdays BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN p1.regdays > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END AS zonetype,
    CASE
        WHEN p1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN p1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN p1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN p1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN p1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    COUNT(DISTINCT user_id_login) AS au,
    COUNT(DISTINCT CASE WHEN level >= 5 THEN user_id_login END) AS au5,
    COUNT(DISTINCT CASE WHEN level >= 120 THEN user_id_login END) AS au125,
    COUNT(DISTINCT CASE WHEN user_id_join IS NOT NULL OR user_id_pay IS NOT NULL THEN user_id_login END) AS pu,
    COUNT(DISTINCT CASE WHEN user_id_pay IS NOT NULL THEN user_id_login END) AS payu,
    SUM(diamonds) AS diamonds,
    COUNT(DISTINCT user_id_join) / COUNT(DISTINCT user_id_login) AS pr,
    SUM(times_tol) AS times_tol,
    SUM(times_diamond) AS times_diamond,
    IF(SUM(times_tol) - SUM(times_diamond) < 0, 0, SUM(times_tol) - SUM(times_diamond)) AS times_free,
    SUM(sales) AS sales
FROM (
    SELECT
        s1.user_id AS user_id_login,
        s2.user_id AS user_id_join,
        s6.level,
        COALESCE(s2.times_tol, 0) AS times_tol,
        s6.zone,
        s6.vip,
        DATEDIFF(s6.loginday, s7.openday) AS regdays,
        s3.diamonds,
        COALESCE(s2.times_diamond, 0) AS times_diamond,
        s4.user_id AS user_id_pay,
        s4.sales
    FROM (
        -- 活跃用户
        SELECT
            user_id,
            COUNT(1) AS cnt
        FROM g10000001.bi_login_logs_day
        WHERE day BETWEEN ${datetime1} AND ${datetime2}
        GROUP BY user_id
    ) s1
    LEFT JOIN (
        -- 参与次数
        SELECT
            user_id,
            SUM(amount) AS times_tol,
            SUM(CASE WHEN u3.money IS NOT NULL THEN amount END) AS times_diamond
        FROM g10000001.bi_tool_list u1
        LEFT JOIN (
            SELECT act_method2
            FROM view_act_method_id -- 销钻购买
        ) u2 ON u1.act_method2 = u2.act_method2
        LEFT JOIN (
            SELECT money
            FROM view_act_package_id -- 充值购买
        ) u3 ON u1.act_method2 = u3.money
        WHERE u1.day BETWEEN ${datetime1} AND ${datetime2}
            AND u1.amount > 0
            AND u1.tool_id = 155
        GROUP BY user_id
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        -- 耗钻
        SELECT
            u1.user_id,
            SUM(-u1.money) AS diamonds
        FROM g10000001.bi_money_list u1
        INNER JOIN (
            SELECT act_method2
            FROM view_act_method_id
        ) u2 ON u1.act_method2 = u2.act_method2
        WHERE u1.day BETWEEN ${datetime1} AND ${datetime2}
            AND u1.money_type_id = 2
            AND u1.money < 0
        GROUP BY u1.user_id
    ) s3 ON s1.user_id = s3.user_id
    LEFT JOIN (
        -- 付费
        SELECT
            u1.user_id,
            SUM(IF(u3.transaction_id IS NOT NULL, u3.paid_lnum / 10, u1.rmb)) AS sales
        FROM (
            SELECT
                d1.day,
                d1.zone,
                d1.record_time,
                d1.user_id,
                d1.money AS giftid_,
                d1.money AS diamond,
                d1.rmb,
                d1.order_id
            FROM g10000001.bi_order_logs d1
            INNER JOIN view_act_package_id d2 ON d1.money = d2.money
            WHERE d1.day BETWEEN ${datetime1} AND ${datetime2}
                AND d1.money <> d1.rmb * 10
        ) u1
        LEFT JOIN (
            SELECT *
            FROM g10000001_dev.orderidblacklist
        ) u2 ON u1.order_id = u2.orderid
        LEFT JOIN (
            SELECT
                lid,
                transaction_id,
                paid_lnum,
                free_lnum
            FROM g10000001.consume_vc
            WHERE day BETWEEN ${datetime1} AND ${datetime2}
        ) u3 ON u1.order_id = u3.transaction_id
        WHERE u2.orderid IS NULL
        GROUP BY u1.user_id
    ) s4 ON s1.user_id = s4.user_id
    LEFT JOIN (
        SELECT
            user_id,
            zone,
            name,
            vip,
            level,
            plat,
            regday,
            DATE_SUB(loginday, 3) AS loginday
        FROM (
            SELECT
                user_id,
                zone,
                name,
                vip,
                level,
                SPLIT(platform_user_id, '_')[0] AS plat,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS regday,
                CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS loginday,
                ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY CAST(SPLIT(zone, '_s')[1] AS INT)) AS depulication
            FROM g10000001.bi_player
            WHERE day = ${datetime2}
                AND CONCAT(user_id, zone) NOT IN (
                    '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
                    '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
                    '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
                )
        ) u1
        WHERE u1.depulication = 1
    ) s6 ON s1.user_id = s6.user_id
    LEFT JOIN (
        -- 开服时间维表
        SELECT
            zone,
            MIN(day) AS day,
            CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
        FROM (
            SELECT
                zone,
                FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
                COUNT(DISTINCT user_id) AS nu
            FROM g10000001.bi_player
            WHERE day = ${datetime2}
                AND zone <> 'ios_s190'
            GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
        ) u1
        WHERE nu >= 15
        GROUP BY zone
        UNION ALL
        SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
    ) s7 ON s6.zone = s7.zone
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM g10000001_dev.user_blacklist
    ) s8 ON s1.user_id = s8.user_id
    WHERE DATEDIFF(s6.loginday, s7.openday) >= 7
        AND s8.user_id IS NULL
) p1
GROUP BY
    CASE
        WHEN p1.regdays BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN p1.regdays BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN p1.regdays BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN p1.regdays BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN p1.regdays > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END,
    CASE
        WHEN p1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN p1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN p1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN p1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN p1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END;

--------------------------------------------------------------------------------
-- Section: Guardian Exchange (守护兑换)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    ${datetime1} AS startday,
    ${datetime3} AS endday,
    CASE
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END AS zonetype,
    CASE
        WHEN s3.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s3.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s3.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s3.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s3.vip = 18 THEN '鲸鱼'
        ELSE '非R或跨服新角色'
    END AS viptype,
    s1.obtain_obj,
    COUNT(DISTINCT s1.user_id) AS pu,
    SUM(-consume_diff) AS consume_diff,
    SUM(obtain_diff) AS obtain_diff
FROM (
    -- 跨服守护兑换
    SELECT
        u1.user_id,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS loginday,
        u1.tool_id AS consume_obj,
        u2.tool_id AS obtain_obj,
        SUM(CAST(u1.amount AS INT)) AS consume_diff,
        SUM(CAST(u2.amount AS INT)) AS obtain_diff
    FROM (
        SELECT
            user_id,
            tool_id,
            amount,
            record_time,
            day
        FROM g10000001.bi_tool_list
        WHERE day BETWEEN ${datetime1} AND ${datetime3}
            AND amount < 0
            AND act_method = '-1006004'
            AND tool_id = '40877'
    ) u1
    INNER JOIN (
        SELECT
            user_id,
            tool_id,
            amount,
            record_time
        FROM g10000001.bi_tool_list
        WHERE day BETWEEN ${datetime1} AND ${datetime3}
            AND act_method = '-1006004'
            AND amount > 0
            AND tool_id <> 155 --- 守护召唤券
    ) u2 ON u1.user_id = u2.user_id AND u1.record_time = u2.record_time
    GROUP BY
        u1.user_id,
        u1.tool_id,
        u2.tool_id
) s1
LEFT JOIN (
    -- 区服
    SELECT
        user_id,
        SPLIT(zone, '_s')[0] AS zonetype,
        CONCAT(SPLIT(zone, '_s')[0], '_s', MIN(server_id)) AS mergezone,
        CONCAT(SPLIT(zone, '_s')[0], '_s', MAX(server_id)) AS zone,
        MAX(vip) AS vip
    FROM g10000001.bi_player
    WHERE day = ${datetime3}
        AND CONCAT(user_id, zone) NOT IN (
            '359226769670145xiaoqi_s1', '359226769690150xiaoqi_s1', '359226769690152xiaoqi_s1',
            '359226769690146xiaoqi_s1', '359226769690148xiaoqi_s1', '359226769690149xiaoqi_s1', '359226769670149xiaoqi_s1',
            '359226769690145xiaoqi_s1', '359226769690147xiaoqi_s1', '359226769690151xiaoqi_s1'
        )
    GROUP BY user_id, SPLIT(zone, '_s')[0]
) s3 ON s1.user_id = s3.user_id
LEFT JOIN (
    -- 开服时间维表
    SELECT
        zone,
        MIN(day) AS day,
        CONCAT_WS('-', SUBSTR(MIN(day), 1, 4), SUBSTR(MIN(day), 5, 2), SUBSTR(MIN(day), 7, 2)) AS openday
    FROM (
        SELECT
            zone,
            FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
            COUNT(DISTINCT user_id) AS nu
        FROM g10000001.bi_player
        WHERE day = ${datetime3}
            AND zone <> 'ios_s190'
        GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
    ) u1
    WHERE nu >= 15
    GROUP BY zone
    UNION ALL
    SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
) s4 ON s3.zone = s4.zone
LEFT JOIN (
    SELECT DISTINCT user_id
    FROM g10000001.user_blacklist
) s5 ON s1.user_id = s5.user_id
WHERE DATEDIFF(s1.loginday, s4.openday) >= 7
    AND s5.user_id IS NULL
GROUP BY
    CASE
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 0 AND 90 THEN '开服3月-'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 91 AND 180 THEN '开服3月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 181 AND 360 THEN '开服6月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) BETWEEN 361 AND 719 THEN '开服12月+'
        WHEN DATEDIFF(s1.loginday, s4.openday) > 720 THEN '开服24月+'
        ELSE '疑似内网用户'
    END,
    CASE
        WHEN s3.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s3.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s3.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s3.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s3.vip = 18 THEN '鲸鱼'
        ELSE '非R或跨服新角色'
    END,
    s1.obtain_obj;
