/*
================================================================================
Game: Saint Seiya 2
Region: TW & SEA
Description: Character growth statistics tracking.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  1. Card Development Ranking (卡牌养成 TOP10)
  2. Card Development Statistics (卡牌养成)
  3. Ultimate Power Development (究极之力)

Parameters: 
  - ${datetime_1}: Snapshot day 1
  - ${datetime_7}: Snapshot day 7 (previous week)
  - ${datetime_14}: Active user window (14 days)
================================================================================
*/

-- Configuration
--------------------------------------------------------------------------------
-- Section: Card Development Ranking (卡牌养成 TOP10)
--------------------------------------------------------------------------------
SELECT
    p.card_sid,
    p.country,
    q2.vip,
    user_act,
    COUNT(DISTINCT p.user_id) AS user_get,
    COUNT(DISTINCT q1.user_id) AS user_get_lw,
    SUM(p.card_power) AS card_power,
    SUM(p.card_power) - COALESCE(SUM(q1.cpower_lw), 0) AS cpower_change,
    AVG(card_upstar) AS card_upstar,
    AVG(card_talent) AS card_talent,
    AVG(adamwar) AS adamwar,
    AVG(anima_adamwar) AS anima_adamwar,
    AVG(cloth_stone) AS cloth_stone,
    AVG(universe_stone) AS universe_stone,
    AVG(universe_crystal) AS universe_crystal,
    AVG(cloth_kobel) AS cloth_kobel
FROM (
    SELECT
        p1.user_id,
        card_sid,
        card_power,
        country,
        -- 卡牌升星 魂石（max600）
        CASE
            WHEN p1.star = 2 THEN 20
            WHEN p1.star = 3 THEN 50
            WHEN p1.star = 4 THEN 100
            WHEN p1.star = 5 THEN 200
            WHEN p1.star = 6 THEN 360
            WHEN p1.star = 7 THEN 600
            ELSE 0
        END AS card_upstar,
        -- 卡牌天赋 魂石（max840）
        COALESCE(
            CASE
                WHEN p1.hero_talent[0] = 1 THEN 0 + 10 * p1.hero_talent[1] + 2 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 2 THEN 70 + 10 * p1.hero_talent[1] + 2 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 3 THEN 140 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 4 THEN 240 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 5 THEN 340 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 6 THEN 440 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 7 THEN 540 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 8 THEN 640 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 9 THEN 740 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                ELSE 0
            END,
            0
        ) AS card_talent,
        -- 斗士之魂 魂石（max150）
        COALESCE((adamwar[1] + adamwar[3] + adamwar[5]) * 5, 0) AS adamwar,
        -- 天赋精华（max210）
        CASE
            WHEN p1.hero_talent[0] = 2 THEN 0 + 2 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 4, 1, 0) + IF(p1.hero_talent[5] > 4, 1, 0) + IF(p1.hero_talent[7] > 4, 1, 0) + IF(p1.hero_talent[9] > 4, 1, 0) + IF(p1.hero_talent[11] > 4, 1, 0) + IF(p1.hero_talent[13] > 4, 1, 0)
            WHEN p1.hero_talent[0] = 3 THEN 8 + 4 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 3, p1.hero_talent[3] - 3, 0) + IF(p1.hero_talent[5] > 3, p1.hero_talent[5] - 3, 0) + IF(p1.hero_talent[7] > 3, p1.hero_talent[7] - 3, 0) + IF(p1.hero_talent[9] > 3, p1.hero_talent[9] - 3, 0) + IF(p1.hero_talent[11] > 3, p1.hero_talent[11] - 3, 0) + IF(p1.hero_talent[13] > 3, p1.hero_talent[13] - 3, 0)
            WHEN p1.hero_talent[0] = 4 THEN 24 + 4 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 2, p1.hero_talent[3] - 2, 0) + IF(p1.hero_talent[5] > 2, p1.hero_talent[5] - 2, 0) + IF(p1.hero_talent[7] > 2, p1.hero_talent[7] - 2, 0) + IF(p1.hero_talent[9] > 2, p1.hero_talent[9] - 2, 0) + IF(p1.hero_talent[11] > 2, p1.hero_talent[11] - 2, 0) + IF(p1.hero_talent[13] > 2, p1.hero_talent[13] - 2, 0)
            WHEN p1.hero_talent[0] = 5 THEN 46 + 4 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 1, p1.hero_talent[3] - 1, 0) + IF(p1.hero_talent[5] > 1, p1.hero_talent[5] - 1, 0) + IF(p1.hero_talent[7] > 1, p1.hero_talent[7] - 1, 0) + IF(p1.hero_talent[9] > 1, p1.hero_talent[9] - 1, 0) + IF(p1.hero_talent[11] > 1, p1.hero_talent[11] - 1, 0) + IF(p1.hero_talent[13] > 1, p1.hero_talent[13] - 1, 0)
            WHEN p1.hero_talent[0] = 6 THEN 74 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            WHEN p1.hero_talent[0] = 7 THEN 108 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            WHEN p1.hero_talent[0] = 8 THEN 142 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            WHEN p1.hero_talent[0] = 9 THEN 176 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            ELSE 0
        END AS anima_adamwar,
        -- 圣衣 遗石（max378）
        COALESCE(POWER(2, p1.cloth[2]) + POWER(2, p1.cloth[5]) + POWER(2, p1.cloth[8]) + POWER(2, p1.cloth[11]) + POWER(2, p1.cloth[14]) + POWER(2, p1.cloth[17]) - 6, 0) AS cloth_stone,
        -- 小宇宙 遗石（max508）
        COALESCE(POWER(2, p1.universe_realm[2]) + POWER(2, p1.universe_realm[5]) + POWER(2, p1.universe_realm[8]) + POWER(2, p1.universe_realm[11]) - 4, 0) AS universe_stone,
        -- 小宇宙 晶3（max28）
        COALESCE(p1.universe_realm[2] + p1.universe_realm[5] + p1.universe_realm[8] + p1.universe_realm[11], 0) AS universe_crystal,
        -- 圣衣 神钢（max5）
        COALESCE(LEAST(CAST(cloth[2] AS INT), CAST(cloth[5] AS INT), CAST(cloth[8] AS INT), CAST(cloth[11] AS INT), CAST(cloth[14] AS INT), CAST(cloth[17] AS INT)), 0) AS cloth_kobel
    FROM (
        SELECT
            day,
            user_id,
            card_sid,
            star,
            CASE
                WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
                WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
                ELSE 'TC'
            END AS country,
            card_power,
            skill,
            SPLIT(cloth, ',') AS cloth,
            universe_nebula,
            SPLIT(universe_realm, ',') AS universe_realm,
            time,
            awaken,
            SPLIT(adamwar, ',') AS adamwar,
            SPLIT(REGEXP_REPLACE(ht.hero_talent, '[^0-9,]', ''), ',') AS hero_talent,
            ROW_NUMBER() OVER (PARTITION BY user_id, card_sid ORDER BY REGEXP_EXTRACT(ht.hero_talent, '[0-9]', 0) DESC) AS rank1,
            DENSE_RANK() OVER (PARTITION BY user_id ORDER BY card_power DESC) AS rank2
        FROM g23000113.bi_card s
        LATERAL VIEW EXPLODE(SPLIT(hero_talent, '}]},')) ht AS hero_talent
        WHERE day = ${datetime_1}
            AND card_sid NOT IN (1000, 1001, 1002, 1003, 1004, 1006, 1009, 1013, 1015, 1017, 1019, 1021, 1023, 1025, 1026, 1033, 1040, 1046)
    ) p1
    INNER JOIN (
        SELECT DISTINCT
            user_id
        FROM g23000113.bi_login_logs_day
        WHERE day >= ${datetime_14}
    ) p2 ON p1.user_id = p2.user_id
    WHERE rank1 = 1
        AND rank2 <= 10
) p
LEFT JOIN (
    -- 上周战力计算
    SELECT
        user_id,
        card_sid,
        card_power AS cpower_lw
    FROM g23000113.bi_card
    WHERE day = ${datetime_7}
) q1 ON p.user_id = q1.user_id AND p.card_sid = q1.card_sid
INNER JOIN (
    -- 匹配VIP
    SELECT
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day = ${datetime_1}
    GROUP BY user_id
) q2 ON p.user_id = q2.user_id
INNER JOIN (
    -- 两周内活跃人数
    SELECT
        CASE
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
            ELSE 'TC'
        END AS country,
        vip,
        COUNT(DISTINCT q3_2.user_id) AS user_act
    FROM (
        SELECT DISTINCT
            user_id,
            server
        FROM g23000113.bi_login_logs_day
        WHERE day >= ${datetime_14}
    ) q3_1
    INNER JOIN (
        SELECT
            user_id,
            MAX(vip) AS vip
        FROM g23000113.bi_player
        WHERE day = ${datetime_1}
        GROUP BY user_id
    ) q3_2 ON q3_1.user_id = q3_2.user_id
    GROUP BY
        CASE
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
            ELSE 'TC'
        END,
        vip
) q3 ON q2.vip = q3.vip AND p.country = q3.country
GROUP BY
    p.country,
    q2.vip,
    p.card_sid,
    user_act
ORDER BY vip DESC;


--------------------------------------------------------------------------------
-- Section: Card Development Statistics (卡牌养成)
--------------------------------------------------------------------------------
SELECT
    p.card_sid,
    p.country,
    q2.vip,
    user_act,
    COUNT(DISTINCT p.user_id) AS user_get,
    COUNT(DISTINCT q1.user_id) AS user_get_lw,
    SUM(p.card_power) AS card_power,
    SUM(p.card_power) - COALESCE(SUM(q1.cpower_lw), 0) AS cpower_change,
    AVG(card_upstar) AS card_upstar,
    AVG(card_talent) AS card_talent,
    AVG(adamwar) AS adamwar,
    AVG(anima_adamwar) AS anima_adamwar,
    AVG(cloth_stone) AS cloth_stone,
    AVG(universe_stone) AS universe_stone,
    AVG(universe_crystal) AS universe_crystal,
    AVG(cloth_kobel) AS cloth_kobel
FROM (
    SELECT
        p1.user_id,
        card_sid,
        card_power,
        country,
        -- 卡牌升星 魂石（max600）
        CASE
            WHEN p1.star = 2 THEN 20
            WHEN p1.star = 3 THEN 50
            WHEN p1.star = 4 THEN 100
            WHEN p1.star = 5 THEN 200
            WHEN p1.star = 6 THEN 360
            WHEN p1.star = 7 THEN 600
            ELSE 0
        END AS card_upstar,
        -- 卡牌天赋 魂石（max840）
        COALESCE(
            CASE
                WHEN p1.hero_talent[0] = 1 THEN 0 + 10 * p1.hero_talent[1] + 2 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 2 THEN 70 + 10 * p1.hero_talent[1] + 2 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 3 THEN 140 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 4 THEN 240 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 5 THEN 340 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 6 THEN 440 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 7 THEN 540 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 8 THEN 640 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                WHEN p1.hero_talent[0] = 9 THEN 740 + 10 * p1.hero_talent[1] + 3 * (p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13])
                ELSE 0
            END,
            0
        ) AS card_talent,
        -- 斗士之魂 魂石（max150）
        COALESCE((adamwar[1] + adamwar[3] + adamwar[5]) * 5, 0) AS adamwar,
        -- 天赋精华（max210）
        CASE
            WHEN p1.hero_talent[0] = 2 THEN 0 + 2 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 4, 1, 0) + IF(p1.hero_talent[5] > 4, 1, 0) + IF(p1.hero_talent[7] > 4, 1, 0) + IF(p1.hero_talent[9] > 4, 1, 0) + IF(p1.hero_talent[11] > 4, 1, 0) + IF(p1.hero_talent[13] > 4, 1, 0)
            WHEN p1.hero_talent[0] = 3 THEN 8 + 4 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 3, p1.hero_talent[3] - 3, 0) + IF(p1.hero_talent[5] > 3, p1.hero_talent[5] - 3, 0) + IF(p1.hero_talent[7] > 3, p1.hero_talent[7] - 3, 0) + IF(p1.hero_talent[9] > 3, p1.hero_talent[9] - 3, 0) + IF(p1.hero_talent[11] > 3, p1.hero_talent[11] - 3, 0) + IF(p1.hero_talent[13] > 3, p1.hero_talent[13] - 3, 0)
            WHEN p1.hero_talent[0] = 4 THEN 24 + 4 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 2, p1.hero_talent[3] - 2, 0) + IF(p1.hero_talent[5] > 2, p1.hero_talent[5] - 2, 0) + IF(p1.hero_talent[7] > 2, p1.hero_talent[7] - 2, 0) + IF(p1.hero_talent[9] > 2, p1.hero_talent[9] - 2, 0) + IF(p1.hero_talent[11] > 2, p1.hero_talent[11] - 2, 0) + IF(p1.hero_talent[13] > 2, p1.hero_talent[13] - 2, 0)
            WHEN p1.hero_talent[0] = 5 THEN 46 + 4 * p1.hero_talent[1] + IF(p1.hero_talent[3] > 1, p1.hero_talent[3] - 1, 0) + IF(p1.hero_talent[5] > 1, p1.hero_talent[5] - 1, 0) + IF(p1.hero_talent[7] > 1, p1.hero_talent[7] - 1, 0) + IF(p1.hero_talent[9] > 1, p1.hero_talent[9] - 1, 0) + IF(p1.hero_talent[11] > 1, p1.hero_talent[11] - 1, 0) + IF(p1.hero_talent[13] > 1, p1.hero_talent[13] - 1, 0)
            WHEN p1.hero_talent[0] = 6 THEN 74 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            WHEN p1.hero_talent[0] = 7 THEN 108 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            WHEN p1.hero_talent[0] = 8 THEN 142 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            WHEN p1.hero_talent[0] = 9 THEN 176 + 4 * p1.hero_talent[1] + p1.hero_talent[3] + p1.hero_talent[5] + p1.hero_talent[7] + p1.hero_talent[9] + p1.hero_talent[11] + p1.hero_talent[13]
            ELSE 0
        END AS anima_adamwar,
        -- 圣衣 遗石（max378）
        COALESCE(POWER(2, p1.cloth[2]) + POWER(2, p1.cloth[5]) + POWER(2, p1.cloth[8]) + POWER(2, p1.cloth[11]) + POWER(2, p1.cloth[14]) + POWER(2, p1.cloth[17]) - 6, 0) AS cloth_stone,
        -- 小宇宙 遗石（max508）
        COALESCE(POWER(2, p1.universe_realm[2]) + POWER(2, p1.universe_realm[5]) + POWER(2, p1.universe_realm[8]) + POWER(2, p1.universe_realm[11]) - 4, 0) AS universe_stone,
        -- 小宇宙 晶3（max28）
        COALESCE(p1.universe_realm[2] + p1.universe_realm[5] + p1.universe_realm[8] + p1.universe_realm[11], 0) AS universe_crystal,
        -- 圣衣 神钢（max5）
        COALESCE(LEAST(CAST(cloth[2] AS INT), CAST(cloth[5] AS INT), CAST(cloth[8] AS INT), CAST(cloth[11] AS INT), CAST(cloth[14] AS INT), CAST(cloth[17] AS INT)), 0) AS cloth_kobel
    FROM (
        SELECT
            day,
            user_id,
            card_sid,
            star,
            CASE
                WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
                WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
                ELSE 'TC'
            END AS country,
            card_power,
            skill,
            SPLIT(cloth, ',') AS cloth,
            universe_nebula,
            SPLIT(universe_realm, ',') AS universe_realm,
            time,
            awaken,
            SPLIT(adamwar, ',') AS adamwar,
            SPLIT(REGEXP_REPLACE(ht.hero_talent, '[^0-9,]', ''), ',') AS hero_talent,
            ROW_NUMBER() OVER (PARTITION BY user_id, card_sid ORDER BY REGEXP_EXTRACT(ht.hero_talent, '[0-9]', 0) DESC) AS rank
        FROM g23000113.bi_card s
        LATERAL VIEW EXPLODE(SPLIT(hero_talent, '}]},')) ht AS hero_talent
        WHERE day = ${datetime_1}
            AND card_sid NOT IN (1000, 1001, 1002, 1003, 1004, 1006, 1009, 1013, 1015, 1017, 1019, 1021, 1023, 1025, 1026, 1033, 1040, 1046)
    ) p1
    INNER JOIN (
        SELECT DISTINCT
            user_id
        FROM g23000113.bi_login_logs_day
        WHERE day >= ${datetime_14}
    ) p2 ON p1.user_id = p2.user_id
    WHERE rank = 1
) p
LEFT JOIN (
    -- 上周战力计算
    SELECT
        user_id,
        card_sid,
        card_power AS cpower_lw
    FROM g23000113.bi_card
    WHERE day = ${datetime_7}
) q1 ON p.user_id = q1.user_id AND p.card_sid = q1.card_sid
INNER JOIN (
    -- 匹配VIP
    SELECT
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day = ${datetime_1}
    GROUP BY user_id
) q2 ON p.user_id = q2.user_id
INNER JOIN (
    -- 两周内活跃人数
    SELECT
        CASE
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
            ELSE 'TC'
        END AS country,
        vip,
        COUNT(DISTINCT q3_2.user_id) AS user_act
    FROM (
        SELECT DISTINCT
            user_id,
            server
        FROM g23000113.bi_login_logs_day
        WHERE day >= ${datetime_14}
    ) q3_1
    INNER JOIN (
        SELECT
            user_id,
            MAX(vip) AS vip
        FROM g23000113.bi_player
        WHERE day = ${datetime_1}
        GROUP BY user_id
    ) q3_2 ON q3_1.user_id = q3_2.user_id
    GROUP BY
        CASE
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
            ELSE 'TC'
        END,
        vip
) q3 ON q2.vip = q3.vip AND p.country = q3.country
GROUP BY
    p.country,
    q2.vip,
    p.card_sid,
    user_act
ORDER BY vip DESC;



--------------------------------------------------------------------------------
-- Section: Ultimate Power Development (究极之力)
--------------------------------------------------------------------------------
-- CREATE TABLE g23000113_dev.tmp_forcecard_20210705 AS
SELECT
    a.country,
    b.vip,
    d.force_card_sid,
    -- d.name,
    equip_hero,
    COUNT(DISTINCT d.user_id) AS user_count,
    SUM(slevel) AS total_slevel,
    SUM(star) AS total_star,
    SUM(sexp) AS total_sexp
FROM (
    SELECT DISTINCT
        user_id,
        CASE
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 23 AND 41 THEN 'SEA'
            WHEN CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42 THEN 'HG'
            ELSE 'TC'
        END AS country
    FROM g23000113.bi_login_logs_day
    WHERE day >= 20210605
) a
INNER JOIN (
    SELECT
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day = 20210705
        AND level >= 125
    GROUP BY user_id
) b ON a.user_id = b.user_id
LEFT JOIN (
    SELECT DISTINCT
        user_id
    FROM g23000113.user_blacklist
) c ON a.user_id = c.user_id
INNER JOIN (
    SELECT
        user_id,
        force_card_sid,
        name,
        slevel,
        max_level,
        sexp,
        init_star,
        quality,
        equip_hero,
        stime,
        stype,
        CASE
            WHEN star <= 2 THEN 1 * star
            WHEN star BETWEEN 3 AND 5 THEN 2 * (star - 2) + 2
            WHEN star BETWEEN 6 AND 7 THEN 3 * (star - 5) + 8
            ELSE 0
        END AS star
    FROM (
        SELECT
            user_id,
            force_card_uid,
            force_card_sid,
            name,
            slevel,
            max_level,
            sexp,
            star,
            init_star,
            quality,
            equip_hero,
            stime,
            stype,
            ROW_NUMBER() OVER (PARTITION BY user_id, equip_hero, force_card_sid ORDER BY stime DESC) AS rank
        FROM g23000113.bi_force_card_state
        WHERE day >= 20180604
    ) t
    WHERE rank = 1
        AND stype IN ('up_star', 'add_exp', 'equip_card')
        AND equip_hero > 0
) d ON a.user_id = d.user_id
WHERE c.user_id IS NULL
GROUP BY
    a.country,
    b.vip,
    d.force_card_sid,
    d.name,
    equip_hero;