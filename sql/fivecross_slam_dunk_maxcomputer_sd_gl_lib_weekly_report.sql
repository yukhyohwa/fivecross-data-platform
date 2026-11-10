/*
================================================================================
Game: Slam Dunk
Description: Weekly report library for Slam Dunk (g33002013).
Author: Antigravity
Created: 2026-01-20

Current Queries:
  1. VIP Distribution (weeklyreport_vip)
  2. Recharge Tiers (weeklyreport_paidrank)
  3. Currency Inventory (weeklyreport_paidremaind)
  4. Resource Production/Consumption (weeklyreport_coin)
  5. Battle Pass Upgrade (weeklyreport_battlepassgrade)
  6. Battle Pass Purchase (weeklyreport_battlepassbuy)
  7. Match Participation (weeklyreport_matchtype)
  8. Rank Distribution (weeklyreport_rankname)
  9. Match Participation by Rank (weeklyreport_matchrank)
  10. Player (Card) Development (weeklyreport_carddevelop)
  11. Player (Card) Usage in Matches (weeklyreport_cards)
  12. Talent Usage (weeklyreport_talents)
  13. Shop Purchases (weeklyreport_shopbuy)
  14. Potential/Proficiency Level (weeklyreport_proficiency)
  15. Roulette/Gacha Spin (weeklyreport_qnzp)
  16. Trait Development (weeklyreport_tzyc)

Notes:
  - Replace {day1}, {day7}, {day15}, {initday} with actual dates (e.g., 20200101).
================================================================================
*/

-- Configuration
SET odps.sql.hive.compatible=True;

--------------------------------------------------------------------------------
-- Section: VIP Distribution (weeklyreport_vip)
--------------------------------------------------------------------------------
SELECT
    b.day,
    vip,
    COUNT(DISTINCT a.mbga_uid, a.user_id) AS au
FROM (
    SELECT
        *
    FROM g33002013.daily_vip
    WHERE day >= {day15}
) a
LEFT JOIN (
    SELECT DISTINCT
        GET_JSON_OBJECT(value, '$.roleId') AS user_id,
        lid AS mbga_uid,
        day
    FROM g33002013.user_event
    WHERE day >= {day15}
) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id AND a.day = b.day
GROUP BY
    b.day,
    vip;

--------------------------------------------------------------------------------
-- Section: Recharge Tiers (weeklyreport_paidrank)
--------------------------------------------------------------------------------
SELECT
    a.day,
    sales_typ,
    all_uu,
    uu,
    sales
FROM (
    SELECT
        day,
        COUNT(DISTINCT lid) AS all_uu
    FROM g33002013.active_user_info
    WHERE day >= {day15}
    GROUP BY day
) a
LEFT JOIN (
    SELECT
        day,
        SPLIT(memo1, ',')[1] AS sales_typ,
        COUNT(DISTINCT lid) AS uu,
        SUM(paid_lnum) AS sales
    FROM g33002013.consume_vc
    WHERE day >= {day15}
        AND paid_lnum > 0
    GROUP BY
        day,
        SPLIT(memo1, ',')[1]
) b ON a.day = b.day;

--------------------------------------------------------------------------------
-- Section: Currency Inventory (weeklyreport_paidremaind)
--------------------------------------------------------------------------------
SELECT
    a.day,
    vip,
    COUNT(DISTINCT a.mbga_uid, a.user_id) AS au,
    SUM(stamps) AS stamps,
    SUM(money) AS money,
    SUM(gold) AS gold,
    SUM(match_coin) AS match_coin
FROM (
    SELECT DISTINCT
        day,
        user_id,
        mbga_uid
    FROM g33002013.daily_game_log
    WHERE day >= {day15}
) a
INNER JOIN (
    SELECT
        day,
        user_id,
        mbga_uid,
        (stamps + free_stamps) AS stamps,
        money,
        gold,
        match_coin,
        CASE
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
            WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
            WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
            WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
            WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
            WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
            WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
            WHEN total_pay >= 1700001 THEN 'V8'
        END AS vip
    FROM g33002013.daily_user_snapshot
    WHERE day >= {day15}
) b ON a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid AND a.day = b.day
GROUP BY
    a.day,
    vip;

--------------------------------------------------------------------------------
-- Section: Resource Production/Consumption (weeklyreport_coin)
--------------------------------------------------------------------------------
SELECT
    a.day,
    vip,
    a_typ,
    type,
    coin_typ,
    COUNT(DISTINCT a.mbga_uid, a.user_id) AS uu,
    SUM(amount) AS amount
FROM (
    SELECT
        day,
        mbga_uid,
        user_id,
        CASE
            WHEN diff < 0 THEN '消费'
            WHEN diff > 0 THEN '产出'
        END AS type,
        CASE
            WHEN obj IN ('dmp:stamps', 'dmp:freestamps') THEN 'stamps'
            ELSE SPLIT(obj, ':|@')[1]
        END AS coin_typ,
        a_typ,
        SUM(ABS(CAST(diff AS INT))) AS amount
    FROM g33002013.daily_game_log
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day >= {day15}
        AND SPLIT(obj, ':|@')[1] IN ('stamps', 'freestamps', 'money', 'gold')
        AND diff <> 0
        AND zone BETWEEN 'ali_tt_10001' AND 'ali_tt_39001'
        AND a_typ NOT IN ('gacha_buy')
    GROUP BY
        mbga_uid,
        user_id,
        CASE
            WHEN diff < 0 THEN '消费'
            WHEN diff > 0 THEN '产出'
        END,
        CASE
            WHEN obj IN ('dmp:stamps', 'dmp:freestamps') THEN 'stamps'
            ELSE SPLIT(obj, ':|@')[1]
        END,
        a_typ,
        day
) a
LEFT JOIN (
    SELECT
        day,
        mbga_uid,
        user_id,
        CASE
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
            WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
            WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
            WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
            WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
            WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
            WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
            WHEN total_pay >= 1700001 THEN 'V8'
        END AS vip
    FROM g33002013.daily_user_snapshot
    WHERE day >= {day15}
) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id AND a.day = b.day
LEFT JOIN (
    SELECT DISTINCT
        mbga_uid
    FROM g33002013.user_blacklist
) bl ON a.mbga_uid = bl.mbga_uid
WHERE bl.mbga_uid IS NULL
GROUP BY
    vip,
    type,
    coin_typ,
    a_typ,
    a.day;

--------------------------------------------------------------------------------
-- Section: Battle Pass Upgrade (weeklyreport_battlepassgrade)
--------------------------------------------------------------------------------
SELECT
    vip,
    COUNT(DISTINCT a.mbga_uid, a.user_id) AS all_uu,
    AVG(b.level) AS avg_level,
    COUNT(DISTINCT c.mbga_uid, c.user_id) AS buy_uu,
    SUM(battlepass_buy) AS battlepass_buy,
    SUM(battlepass_levelbuy) AS battlepass_levelbuy
FROM (
    SELECT
        *
    FROM g33002013.daily_vip
    WHERE day = {day1}
) a
INNER JOIN (
    SELECT
        *
    FROM g33002013.daily_user_snapshot
    WHERE day = {day1}
        AND TO_CHAR(FROM_UNIXTIME(CAST(last_login AS INT)), 'yyyymmdd') >= {initday}
) e ON a.mbga_uid = e.mbga_uid AND a.user_id = e.user_id
LEFT JOIN (
    SELECT
        mbga_uid,
        user_id,
        MAX(CAST(REGEXP_REPLACE(level, '\\\\[|\\\\]', '') AS INT)) AS level
    FROM g33002013.daily_game_log
    LATERAL VIEW EXPLODE(SPLIT(GET_JSON_OBJECT(a_tar, '$.index'), ',')) a_tar AS level
    WHERE day >= {initday}
        AND a_typ = 'battlepass_reward'
    GROUP BY
        mbga_uid,
        user_id
) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id
LEFT JOIN (
    SELECT DISTINCT
        mbga_uid,
        user_id
    FROM g33002013.daily_game_log
    WHERE day >= {initday}
        AND a_typ = 'battlepass_buy'
) c ON a.mbga_uid = c.mbga_uid AND a.user_id = c.user_id
LEFT JOIN (
    SELECT
        mbga_uid,
        user_id,
        SUM(CASE WHEN a_typ = 'battlepass_buy' THEN ABS(CAST(diff AS INT)) ELSE 0 END) AS battlepass_buy,
        SUM(CASE WHEN a_typ = 'battlepass_levelbuy' THEN ABS(CAST(diff AS INT)) ELSE 0 END) AS battlepass_levelbuy
    FROM g33002013.daily_game_log
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day >= {initday}
        AND SPLIT(obj, ':|@')[1] IN ('stamps', 'freestamps')
        AND diff <> 0
        AND a_typ IN ('battlepass_buy', 'battlepass_levelbuy')
    GROUP BY
        mbga_uid,
        user_id
) d ON a.mbga_uid = d.mbga_uid AND a.user_id = d.user_id
GROUP BY
    vip
ORDER BY
    vip;

--------------------------------------------------------------------------------
-- Section: Battle Pass Purchase (weeklyreport_battlepassbuy)
--------------------------------------------------------------------------------
SELECT
    vip,
    COUNT(DISTINCT b.user_id) AS buy_uu,
    SUM(sales) AS sales
FROM (
    SELECT
        *
    FROM g33002013.daily_vip
    WHERE day = {day1}
) a
INNER JOIN (
    SELECT
        lid AS mbga_uid,
        SPLIT(memo1, ',')[0] AS user_id,
        SUM(paid_lnum) AS sales
    FROM g33002013.consume_vc
    WHERE day >= {initday}
        AND SPLIT(memo1, ',')[1] IN (13220151, 13220150)
        AND paid_lnum > 0
    GROUP BY
        lid,
        SPLIT(memo1, ',')[0]
) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id
GROUP BY
    vip
ORDER BY
    vip;

--------------------------------------------------------------------------------
-- Section: Match Participation (weeklyreport_matchtype)
--------------------------------------------------------------------------------
SELECT
    all_uu,
    b.type,
    match_times,
    uu,
    times,
    win,
    pvp_uu,
    pvp_times,
    pvp_win,
    ping,
    a.day
FROM (
    SELECT
        day,
        COUNT(DISTINCT user_id, mbga_uid) AS all_uu
    FROM g33002013.daily_game_log
    WHERE day >= {day15}
    GROUP BY
        day
) a
LEFT JOIN (
    SELECT
        a.day,
        c.name AS type,
        COUNT(DISTINCT a.match_id) AS match_times,
        COUNT(DISTINCT a.mbga_uid) AS uu,
        COUNT(DISTINCT a.mbga_uid, log_t) AS times,
        COUNT(DISTINCT CASE WHEN reuslt = 'true' THEN CONCAT(a.mbga_uid, log_t) ELSE NULL END) AS win,
        COUNT(DISTINCT CASE WHEN AI_num < TAR_num THEN a.match_id ELSE NULL END) AS match_pvp_times,
        COUNT(DISTINCT CASE WHEN AI_num < TAR_num THEN a.mbga_uid ELSE NULL END) AS pvp_uu,
        COUNT(DISTINCT CASE WHEN AI_num < TAR_num THEN CONCAT(a.mbga_uid, log_t) ELSE NULL END) AS pvp_times,
        COUNT(DISTINCT CASE WHEN AI_num < TAR_num AND reuslt = 'true' THEN CONCAT(a.mbga_uid, log_t) ELSE NULL END) AS pvp_win
    FROM (
        SELECT
            day,
            GET_JSON_OBJECT(a_tar, '$.type') AS type,
            GET_JSON_OBJECT(a_tar, '$.match_id') AS match_id,
            mbga_uid,
            user_id,
            log_t,
            GET_JSON_OBJECT(a_tar, '$.reuslt') AS reuslt
        FROM g33002013.daily_game_log
        WHERE day >= {day15}
            AND a_typ IN ('match_fight', 'arena_fight', 'com_fight', 'custom_fight')
        UNION ALL
        SELECT
            day,
            'tower_fight' AS type,
            CONCAT(log_t, mbga_uid) AS match_id,
            mbga_uid,
            user_id,
            log_t,
            GET_JSON_OBJECT(a_tar, '$.reuslt') AS reuslt
        FROM g33002013.daily_game_log
        WHERE day >= {day15}
            AND a_typ = 'tower_fight'
    ) a
    LEFT JOIN (
        SELECT
            match_id,
            COUNT(DISTINCT CASE WHEN SUBSTR(teammate, 1, 2) = '23' THEN teammate ELSE NULL END) AS AI_num,
            COUNT(DISTINCT teammate) AS TAR_num
        FROM (
            SELECT DISTINCT
                day,
                match_id,
                REGEXP_REPLACE(teammate_id2, '\\[|\\]|"', '') AS teammate
            FROM (
                SELECT DISTINCT
                    day,
                    GET_JSON_OBJECT(a_tar, '$.match_id') AS match_id,
                    GET_JSON_OBJECT(a_tar, '$.target_id') AS teammate_id
                FROM g33002013.daily_game_log
                WHERE day >= {day15}
                    AND a_typ IN ('match_fight', 'arena_fight', 'com_fight', 'custom_fight')
            ) a
            LATERAL VIEW EXPLODE(SPLIT(teammate_id, ',')) teammate AS teammate_id2
        ) a
        GROUP BY
            match_id
    ) b ON a.match_id = b.match_id
    LEFT JOIN g33002013.dim_match c ON a.type = c.id
    GROUP BY
        a.day,
        c.name
) b ON a.day = b.day
LEFT JOIN (
    SELECT
        a.day,
        name AS type,
        ping
    FROM (
        SELECT
            day,
            GET_JSON_OBJECT(a_tar, '$.type') AS type,
            SUM(GET_JSON_OBJECT(a_tar, '$.ping')) AS ping
        FROM g33002013.daily_game_log
        WHERE day >= {day15}
            AND a_typ = 'fight_data'
        GROUP BY
            day,
            GET_JSON_OBJECT(a_tar, '$.type')
    ) a
    LEFT JOIN g33002013.dim_match b ON a.type = b.id
) c ON b.day = c.day AND b.type = c.type
WHERE b.type IS NOT NULL;

--------------------------------------------------------------------------------
-- Section: Rank Distribution (weeklyreport_rankname)
--------------------------------------------------------------------------------
SELECT
    rank_name,
    COUNT(DISTINCT a.mbga_uid, a.user_id) AS all_uu
FROM (
    SELECT DISTINCT
        GET_JSON_OBJECT(value, '$.roleId') AS user_id,
        lid AS mbga_uid,
        CONCAT('ali_tt_', GET_JSON_OBJECT(value, '$.zoneId')) AS zone
    FROM g33002013.user_event
    WHERE day >= {day7}
) a
LEFT JOIN (
    SELECT
        mbga_uid,
        user_id,
        match_rank,
        '1' AS a1,
        CASE
            WHEN total_pay = 0 THEN 'V0'
        END AS vip
    FROM (
        SELECT
            *,
            ROW_NUMBER() OVER (PARTITION BY mbga_uid, user_id ORDER BY last_login DESC) AS rank
        FROM g33002013.daily_user_snapshot
        WHERE day = {day1}
            AND CAST(level AS INT) >= 8
    ) a
    WHERE rank = 1
) b ON a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid
LEFT JOIN (
    SELECT
        *,
        '1' AS a1
    FROM g33002013.dim_rank
) d ON b.a1 = d.a1
LEFT JOIN g33002013.user_blacklist e ON a.mbga_uid = e.mbga_uid
WHERE b.match_rank >= d.min_star
    AND b.match_rank <= d.max_star
    AND e.mbga_uid IS NULL
GROUP BY
    rank_name;

--------------------------------------------------------------------------------
-- Section: Match Participation by Rank (weeklyreport_matchrank)
--------------------------------------------------------------------------------
SELECT
    a.day,
    c.name AS type,
    rank_name,
    COUNT(DISTINCT a.mbga_uid, a.user_id) AS uu,
    COUNT(DISTINCT a.mbga_uid, a.session) AS matchs,
    SUM(match_time) AS match_time,
    COUNT(DISTINCT CASE WHEN a.result = 'true' THEN CONCAT(a.mbga_uid, a.session) ELSE NULL END) AS win,
    COUNT(DISTINCT CASE WHEN a.result <> b.result AND b.players <> 0 THEN CONCAT(a.mbga_uid, a.session) ELSE NULL END) AS pvp_times,
    COUNT(DISTINCT CASE WHEN a.result = 'true' AND a.result <> b.result AND b.players <> 0 THEN CONCAT(a.mbga_uid, a.session) ELSE NULL END) AS pvp_win
FROM (
    SELECT
        day,
        mbga_uid,
        user_id,
        session,
        type,
        match_time,
        SPLIT(star, '#')[0] AS star,
        result,
        '1' AS a1
    FROM g33002013.daily_match_snapshot
    WHERE day >= {day15}
        AND ai = 'false'
) a
LEFT JOIN (
    SELECT
        *,
        '1' AS a1
    FROM g33002013.dim_rank
) d ON a.a1 = d.a1
LEFT JOIN g33002013.dim_match c ON a.type = c.id
LEFT JOIN (
    SELECT
        session,
        result,
        COUNT(DISTINCT CASE WHEN ai = 'false' THEN user_id ELSE NULL END) AS players
    FROM g33002013.daily_match_snapshot
    WHERE day >= {day15}
    GROUP BY
        session,
        result
) b ON a.session = b.session
LEFT JOIN g33002013.user_blacklist e ON a.mbga_uid = e.mbga_uid
WHERE a.star >= d.min_star
    AND a.star <= d.max_star
    AND e.mbga_uid IS NULL
GROUP BY
    a.day,
    c.name,
    rank_name;

--------------------------------------------------------------------------------
-- Section: Player (Card) Development (weeklyreport_carddevelop)
--------------------------------------------------------------------------------
SELECT
    a.vip,
    all_uu,
    card_id,
    get_uu,
    grade,
    level,
    D_GRADE,
    C_GRADE,
    B_GRADE,
    A_GRADE,
    S_GRADE
FROM (
    SELECT
        vip,
        COUNT(DISTINCT a.mbga_uid, a.user_id) AS all_uu
    FROM (
        SELECT DISTINCT
            GET_JSON_OBJECT(value, '$.roleId') AS user_id,
            lid AS mbga_uid,
            CONCAT('ali_tt_', GET_JSON_OBJECT(value, '$.zoneId')) AS zone
    FROM g33002013.user_event
    WHERE day >= {day7}
    ) a
    LEFT JOIN (
        SELECT
            mbga_uid,
            user_id,
            CASE
                WHEN total_pay = 0 THEN 'V0'
                WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
                WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
                WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
                WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
                WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
                WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
                WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
                WHEN total_pay >= 1700001 THEN 'V8'
            END AS vip
        FROM g33002013.daily_user_snapshot
        WHERE day = {day1}
    ) b ON a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid
    LEFT JOIN g33002013.user_blacklist e ON a.mbga_uid = e.mbga_uid
    WHERE e.mbga_uid IS NULL
    GROUP BY
        vip
) a
LEFT JOIN (
    SELECT
        vip,
        card_id,
        COUNT(DISTINCT a.mbga_uid, a.user_id) AS get_uu,
        SUM(grade) AS grade,
        SUM(level) AS level,
        COUNT(DISTINCT CASE WHEN grade = 1 THEN a.user_id ELSE NULL END) AS D_GRADE,
        COUNT(DISTINCT CASE WHEN grade = 2 THEN a.user_id ELSE NULL END) AS C_GRADE,
        COUNT(DISTINCT CASE WHEN grade = 3 THEN a.user_id ELSE NULL END) AS B_GRADE,
        COUNT(DISTINCT CASE WHEN grade = 4 THEN a.user_id ELSE NULL END) AS A_GRADE,
        COUNT(DISTINCT CASE WHEN grade = 5 THEN a.user_id ELSE NULL END) AS S_GRADE,
        AVG(honor) AS honor
    FROM (
        SELECT DISTINCT
            GET_JSON_OBJECT(value, '$.roleId') AS user_id,
            lid AS mbga_uid
        FROM g33002013.user_event
        WHERE day >= {day7}
    ) a
    LEFT JOIN (
        SELECT
            mbga_uid,
            user_id,
            match_rank,
            '1' AS a1,
            CASE
                WHEN total_pay = 0 THEN 'V0'
                WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
                WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
                WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
                WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
                WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
                WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
                WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
                WHEN total_pay >= 1700001 THEN 'V8'
            END AS vip
        FROM g33002013.daily_user_snapshot
        WHERE day = {day1}
    ) b ON a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid
    LEFT JOIN (
        SELECT
            mbga_uid,
            user_id,
            card_id,
            grade,
            level,
            user_card_id,
            GET_JSON_OBJECT(extra_info, '$.honor') AS honor
        FROM g33002013.daily_user_card_snapshot
        WHERE day = {day1}
            AND status = '1'
    ) c ON a.mbga_uid = c.mbga_uid AND a.user_id = c.user_id
    LEFT JOIN (
        SELECT
            *,
            '1' AS a1
        FROM g33002013.dim_rank
    ) d ON b.a1 = d.a1
    LEFT JOIN g33002013.user_blacklist e ON a.mbga_uid = e.mbga_uid
    WHERE b.match_rank >= d.min_star
        AND b.match_rank <= d.max_star
        AND e.mbga_uid IS NULL
    GROUP BY
        vip,
        card_id
) b ON a.vip = b.vip;

--------------------------------------------------------------------------------
-- Section: Player (Card) Usage in Matches (weeklyreport_cards)
--------------------------------------------------------------------------------
SELECT
    CASE
        WHEN pvp = 1 THEN '单机'
        WHEN pvp = 2 THEN 'PVP'
    END AS pvp_type,
    rank_name,
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
    stealG AS stealG,
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
    a.day
FROM (
    SELECT
        a.day,
        pvp,
        rank_name,
        GET_JSON_OBJECT(player, '$.player') AS player,
        type,
        COUNT(DISTINCT a.mbga_uid, a.session) AS match_times,
        COUNT(DISTINCT CASE WHEN GET_JSON_OBJECT(player, '$.state') = '1' THEN CONCAT(a.mbga_uid, a.user_id) ELSE NULL END) AS get_player,
        COUNT(CASE WHEN result = 'true' THEN log_t ELSE NULL END) AS win,
        SUM(score) AS score,
        SUM(GET_JSON_OBJECT(adata, '$.twoN')) AS twoN,
        SUM(GET_JSON_OBJECT(adata, '$.twoG')) AS twoG,
        SUM(GET_JSON_OBJECT(adata, '$.layupN')) AS layupN,
        SUM(GET_JSON_OBJECT(adata, '$.layupG')) AS layupG,
        SUM(GET_JSON_OBJECT(adata, '$.dunkN')) AS dunkN,
        SUM(GET_JSON_OBJECT(adata, '$.dunkG')) AS dunkG,
        SUM(GET_JSON_OBJECT(adata, '$.threeN')) AS threeN,
        SUM(GET_JSON_OBJECT(adata, '$.threeG')) AS threeG,
        SUM(GET_JSON_OBJECT(adata, '$.blockG')) AS blockG,
        SUM(GET_JSON_OBJECT(adata, '$.stealG')) AS stealG,
        SUM(GET_JSON_OBJECT(adata, '$.rebG')) AS rebG,
        SUM(GET_JSON_OBJECT(adata, '$.asitN')) AS asitN,
        SUM(GET_JSON_OBJECT(adata, '$.intercept')) AS intercept,
        SUM(GET_JSON_OBJECT(adata, '$.ballT')) AS ballT,
        SUM(GET_JSON_OBJECT(adata, '$.groundN')) AS groundN,
        SUM(GET_JSON_OBJECT(player, '$.mark')) / 10000 AS mark,
        SUM(GET_JSON_OBJECT(adata, '$.twoN_open')) AS twoN_open,
        SUM(GET_JSON_OBJECT(adata, '$.twoG_open')) AS twoG_open,
        SUM(GET_JSON_OBJECT(adata, '$.threeN_open')) AS threeN_open,
        SUM(GET_JSON_OBJECT(adata, '$.threeG_open')) AS threeG_open,
        SUM(GET_JSON_OBJECT(adata, '$.downN')) AS downN,
        SUM(GET_JSON_OBJECT(adata, '$.downND')) AS downND
    FROM (
        SELECT
            player,
            mbga_uid,
            user_id,
            session,
            score,
            result,
            adata,
            CAST(SPLIT(star, '#')[0] AS INT) AS star,
            '1' AS a1,
            type,
            log_t,
            day
        FROM g33002013.daily_match_snapshot
        WHERE day >= {day15}
            AND ai = 'false'
            AND type = 'RankH3V3'
    ) a
    INNER JOIN (
        SELECT DISTINCT
            user_id,
            mbga_uid,
            card_id,
            day
        FROM g33002013.daily_user_card_snapshot
        WHERE day >= {day15}
            AND grade = 5
    ) e ON a.mbga_uid = e.mbga_uid AND a.user_id = e.user_id AND a.day = e.day AND GET_JSON_OBJECT(a.player, '$.player') = e.card_id
    LEFT JOIN (
        SELECT
            *,
            '1' AS a1
        FROM g33002013.dim_rank
    ) d ON a.a1 = d.a1
    LEFT JOIN (
        SELECT
            session,
            COUNT(DISTINCT result) AS pvp
        FROM g33002013.match_snapshot
        WHERE day >= {day15}
            AND ai = 'false'
        GROUP BY
            session
    ) b ON a.session = b.session
    WHERE a.star >= d.min_star
        AND a.star <= d.max_star
    GROUP BY
        a.day,
        pvp,
        GET_JSON_OBJECT(player, '$.player'),
        type,
        rank_name
) a
LEFT JOIN (
    SELECT
        type,
        COUNT(DISTINCT mbga_uid, session) AS total_match
    FROM g33002013.match_snapshot
    WHERE day >= {day15}
        AND ai = 'false'
    GROUP BY
        type
) c ON a.type = c.type
LEFT JOIN g33002013.dim_match d ON a.type = d.id
LEFT JOIN g33002013.dim_card_h5 e ON a.player = e.card_id
WHERE pvp = 2;

--------------------------------------------------------------------------------
-- Section: Talent Usage (weeklyreport_talents)
--------------------------------------------------------------------------------
SELECT
    a.*,
    b.skill1,
    uu
FROM (
    SELECT
        vip,
        card_id,
        COUNT(DISTINCT a.mbga_uid, a.user_id) AS get_uu
    FROM (
        SELECT
            card_id,
            mbga_uid,
            user_id
        FROM g33002013.daily_user_card_snapshot
        WHERE day = {day1}
            AND status = '1'
    ) a
    INNER JOIN (
        SELECT
            mbga_uid,
            user_id,
            match_rank,
            '1' AS a1,
            CASE
                WHEN total_pay = 0 THEN 'V0'
                WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
                WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
                WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
                WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
                WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
                WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
                WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
                WHEN total_pay >= 1700001 THEN 'V8'
            END AS vip
        FROM g33002013.daily_user_snapshot
        WHERE day = {day1}
            AND TO_CHAR(FROM_UNIXTIME(CAST(last_login AS INT)), 'yyyymmdd') >= {day7}
    ) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id
    GROUP BY
        card_id,
        vip
) a
LEFT JOIN (
    SELECT
        vip,
        card_id,
        skill1,
        COUNT(DISTINCT a.mbga_uid, a.user_id) AS uu
    FROM (
        SELECT
            mbga_uid,
            user_id,
            card_id,
            skill1
        FROM g33002013.daily_user_card_snapshot
        LATERAL VIEW EXPLODE(SPLIT(skill, ',|\\\\[|\\\\]')) a_tar AS skill1
        WHERE day = {day1}
            AND LENGTH(skill1) BETWEEN 4 AND 6
    ) a
    INNER JOIN (
        SELECT
            mbga_uid,
            user_id,
            match_rank,
            '1' AS a1,
            CASE
                WHEN total_pay = 0 THEN 'V0'
                WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
                WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
                WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
                WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
                WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
                WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
                WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
                WHEN total_pay >= 1700001 THEN 'V8'
            END AS vip
        FROM g33002013.daily_user_snapshot
        WHERE day = {day1}
            AND TO_CHAR(FROM_UNIXTIME(CAST(last_login AS INT)), 'yyyymmdd') >= {day7}
    ) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id
    GROUP BY
        card_id,
        skill1,
        vip
) b ON a.card_id = b.card_id AND a.vip = b.vip;

--------------------------------------------------------------------------------
-- Section: Shop Purchases (weeklyreport_shopbuy)
--------------------------------------------------------------------------------
SELECT
    a.vip,
    all_uu,
    shop,
    a.item_id,
    coin_typ,
    uu,
    amount,
    num
FROM (
    SELECT
        vip,
        item_id,
        COUNT(DISTINCT a.mbga_uid, a.user_id) AS all_uu
    FROM (
        SELECT DISTINCT
            day,
            GET_JSON_OBJECT(value, '$.roleId') AS user_id,
            lid AS mbga_uid
        FROM g33002013.user_event
        WHERE day BETWEEN {day7} AND {day1}
    ) a
    INNER JOIN (
        SELECT
            *
        FROM g33002013.daily_vip
        WHERE day = {day1}
    ) b ON a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid
    INNER JOIN (
        SELECT DISTINCT
            GET_JSON_OBJECT(a_tar, '$.item_id') AS item_id,
            day
        FROM g33002013.daily_game_log
        WHERE day BETWEEN {day7} AND {day1}
            AND a_typ = 'shop_buy'
    ) c ON a.day = c.day
    GROUP BY
        vip,
        item_id
) a
LEFT JOIN (
    SELECT
        vip,
        shop,
        item_id,
        coin_typ,
        COUNT(DISTINCT a.user_id, a.mbga_uid) AS uu,
        SUM(a.amount) AS amount,
        SUM(a.num) AS num
    FROM (
        SELECT
            GET_JSON_OBJECT(a_tar, '$.shop_id') AS shop,
            GET_JSON_OBJECT(a_tar, '$.item_id') AS item_id,
            CASE
                WHEN obj IN ('dmp:stamps', 'dmp:freestamps') THEN 'stamps'
                ELSE SPLIT(obj, ':|@')[1]
            END AS coin_typ,
            log_t,
            user_id,
            mbga_uid,
            -diff AS amount,
            GET_JSON_OBJECT(a_tar, '$.num') AS num
        FROM g33002013.daily_game_log
        LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
        LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
        WHERE day BETWEEN {day7} AND {day1}
            AND a_typ IN ('shop_buy')
            AND diff < 0
    ) a
    INNER JOIN (
        SELECT
            *
        FROM g33002013.daily_vip
        WHERE day = {day1}
    ) b ON a.user_id = b.user_id AND a.mbga_uid = b.mbga_uid
    LEFT JOIN (
        SELECT DISTINCT
            mbga_uid
        FROM g33002013.user_blacklist
    ) bl ON a.mbga_uid = bl.mbga_uid
    WHERE bl.mbga_uid IS NULL
    GROUP BY
        vip,
        shop,
        item_id,
        coin_typ
) b ON a.vip = b.vip AND a.item_id = b.item_id;

--------------------------------------------------------------------------------
-- Section: Potential/Proficiency Level (weeklyreport_proficiency)
--------------------------------------------------------------------------------
SELECT
    vip,
    COUNT(DISTINCT a.user_id, a.mbga_uid) AS all_uu,
    COUNT(DISTINCT b.mbga_uid, plan) AS plan_num,
    SUM(CASE WHEN row = 1 THEN lv ELSE 0 END) AS plan1,
    SUM(CASE WHEN row = 2 THEN lv ELSE 0 END) AS plan2,
    SUM(CASE WHEN row = 3 THEN lv ELSE 0 END) AS plan3
FROM (
    SELECT
        mbga_uid,
        user_id,
        plan,
        lv,
        ROW_NUMBER() OVER (PARTITION BY mbga_uid, user_id ORDER BY lv DESC) AS row
    FROM (
        SELECT
            mbga_uid,
            user_id,
            plan,
            SUM(CAST(SUBSTR(item_id, 4, 1) AS INT)) AS lv
        FROM g33002013.daily_user_proficiency_snapshot
        WHERE day = {day1}
            AND (aindex < 22 OR aindex > 24)
        GROUP BY
            mbga_uid,
            user_id,
            plan
    ) a
) a
INNER JOIN (
    SELECT
        *
    FROM g33002013.daily_vip
    WHERE day = {day1}
) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id
INNER JOIN (
    SELECT DISTINCT
        GET_JSON_OBJECT(value, '$.roleId') AS user_id,
        lid AS mbga_uid
    FROM g33002013.user_event
    WHERE day BETWEEN {day7} AND {day1}
) c ON a.mbga_uid = c.mbga_uid AND a.user_id = c.user_id
GROUP BY
    vip;

--------------------------------------------------------------------------------
-- Section: Roulette/Gacha Spin (weeklyreport_qnzp)
--------------------------------------------------------------------------------
SELECT
    a.day,
    a.vip,
    all_uu,
    a_typ,
    uu,
    times
FROM (
    SELECT
        day,
        CASE
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
            WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
            WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
            WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
            WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
            WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
            WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
            WHEN total_pay >= 1700001 THEN 'V8'
        END AS vip,
        COUNT(DISTINCT user_id) AS all_uu
    FROM g33002013.daily_user_snapshot t
    WHERE day >= {day15}
    GROUP BY
        day,
        CASE
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
            WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
            WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
            WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
            WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
            WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
            WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
            WHEN total_pay >= 1700001 THEN 'V8'
        END
) a
LEFT JOIN (
    SELECT
        b.vip,
        a.a_typ,
        COUNT(DISTINCT a.mbga_uid) AS uu,
        SUM(times) AS times,
        a.day
    FROM (
        SELECT
            day,
            mbga_uid,
            user_id,
            a_typ,
            SUM(GET_JSON_OBJECT(a_tar, '$.times')) AS times
        FROM g33002013.daily_game_log
        WHERE day >= {day15}
            AND a_typ IN ('proficiency_gacha', 'roulette_buy')
        GROUP BY
            mbga_uid,
            user_id,
            a_typ,
            day
    ) a
    LEFT JOIN (
        SELECT
            t.*,
            CASE
                WHEN total_pay = 0 THEN 'V0'
                WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
                WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
                WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
                WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
                WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
                WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
                WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
                WHEN total_pay >= 1700001 THEN 'V8'
            END AS vip
        FROM g33002013.daily_user_snapshot t
        WHERE day >= {day15}
    ) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id AND a.day = b.day
    GROUP BY
        b.vip,
        a.a_typ,
        a.day
) b ON a.day = b.day AND a.vip = b.vip;

--------------------------------------------------------------------------------
-- Section: Trait Development (weeklyreport_tzyc)
--------------------------------------------------------------------------------
SELECT
    a.*,
    b.all_uu
FROM (
    SELECT
        vip,
        item_id,
        lv,
        COUNT(DISTINCT b.user_id) AS uu
    FROM (
        SELECT
            user_id,
            mbga_uid,
            CAST(match_rank AS INT) AS match_rank,
            '1' AS a1,
            CASE
                WHEN total_pay = 0 THEN 'V0'
                WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
                WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
                WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
                WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
                WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
                WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
                WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
                WHEN total_pay >= 1700001 THEN 'V8'
            END AS vip
        FROM g33002013.daily_user_snapshot
        WHERE day = {day1}
            AND TO_CHAR(FROM_UNIXTIME(CAST(last_login AS INT)), 'yyyymmdd') >= {day7}
    ) a
    LEFT JOIN (
        SELECT
            SUBSTR(GET_JSON_OBJECT(a_tar, '$.item_id'), 5, 4) AS item_id,
            mbga_uid,
            user_id,
            MAX(SUBSTR(GET_JSON_OBJECT(a_tar, '$.item_id'), 4, 1)) AS lv
        FROM g33002013.daily_game_log
        WHERE day >= 20200729
            AND a_typ IN ('proficiency_decompose', 'proficiency_equip', 'proficiency_levelup')
            AND SUBSTR(GET_JSON_OBJECT(a_tar, '$.item_id'), 5, 1) = 4
        GROUP BY
            SUBSTR(GET_JSON_OBJECT(a_tar, '$.item_id'), 5, 4),
            mbga_uid,
            user_id
    ) b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id
    GROUP BY
        vip,
        item_id,
        lv
) a
LEFT JOIN (
    SELECT
        CASE
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
            WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
            WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
            WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
            WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
            WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
            WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
            WHEN total_pay >= 1700001 THEN 'V8'
        END AS vip,
        COUNT(DISTINCT user_id) AS all_uu
    FROM g33002013.daily_user_snapshot
    WHERE day = {day1}
        AND TO_CHAR(FROM_UNIXTIME(CAST(last_login AS INT)), 'yyyymmdd') >= {day7}
    GROUP BY
        CASE
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 1200 THEN 'V1'
            WHEN total_pay BETWEEN 1201 AND 5900 THEN 'V2'
            WHEN total_pay BETWEEN 5901 AND 20000 THEN 'V3'
            WHEN total_pay BETWEEN 20001 AND 80000 THEN 'V4'
            WHEN total_pay BETWEEN 80001 AND 170000 THEN 'V5'
            WHEN total_pay BETWEEN 170001 AND 500000 THEN 'V6'
            WHEN total_pay BETWEEN 500001 AND 1700000 THEN 'V7'
            WHEN total_pay >= 1700001 THEN 'V8'
        END
) b ON a.vip = b.vip;
