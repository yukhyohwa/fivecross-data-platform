/*
================================================================================
Game: Saint Seiya 2
Region: TW & SEA
Description: Weekly activity statistics tracking for various in-game events.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  1. Treasure Box Performance (宝箱)
  2. Treasure Box Reward Exchange (宝箱兑换)
  3. Jackpot Performance (转盘)
  4. Jackpot Reward Exchange (转盘兑换)
  5. Force Gacha Statistics (原力)
  6. Force Reward Exchange (原力兑换)

Parameters: 
  - ${start_day}: Start date of the reporting period
  - ${end_day}: End date of the reporting period
  - ${exchange_end}: End date for exchange activities
================================================================================
*/

--------------------------------------------------------------------------------
-- Section: Treasure Box Performance (宝箱)
--------------------------------------------------------------------------------
WITH dim_tool_id AS (
    SELECT
        tool_id
    FROM (
        SELECT
            tool_id,
            ROW_NUMBER() OVER (ORDER BY amts DESC) AS rank
        FROM (
            SELECT
                tool_id,
                SUM(-amount) AS amts
            FROM g23000113.bi_tool_list
            WHERE day BETWEEN ${start_day} AND ${end_day}
                AND tool_id BETWEEN 9000 AND 10000
                AND amount > 0
                AND act_method2 IN (1, 2)
                AND (CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 1 AND 22 OR CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42)
            GROUP BY tool_id
        ) u
    ) s
    WHERE s.rank = 1
)
SELECT
    ${start_day} AS day,
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END AS zone_type,
    CASE
        WHEN s2.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    COUNT(DISTINCT s1.user_id) AS au,
    COUNT(DISTINCT s3.user_id) AS pu,
    '' AS toolnum,
    SUM(CASE WHEN money_type_id = 2 THEN s3.money ELSE 0 END) - SUM(CASE WHEN money_type_id = 3 THEN s3.money ELSE 0 END) AS freediamond,
    SUM(CASE WHEN money_type_id = 3 THEN s3.money ELSE 0 END) AS paiddiamond,
    '' AS backdiamond
FROM (
    -- 活跃人数
    SELECT
        d1.user_id,
        server
    FROM (
        SELECT
            user_id,
            MIN(CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS server
        FROM g23000113.bi_login_logs_day
        WHERE day BETWEEN ${start_day} AND ${end_day}
        GROUP BY user_id
    ) d1
    LEFT JOIN (
        SELECT
            user_id
        FROM g23000113.user_blacklist
    ) d2 ON d1.user_id = d2.user_id
    WHERE d2.user_id IS NULL
) s1
LEFT JOIN (
    -- VIP
    SELECT
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day = ${start_day}
    GROUP BY user_id
) s2 ON s1.user_id = s2.user_id
LEFT JOIN (
    -- 行为数据
    SELECT
        u2.user_id,
        money_type_id,
        SUM(money) AS money
    FROM (
        SELECT DISTINCT
            user_id,
            record_time
        FROM g23000113.bi_tool_list d1
        INNER JOIN dim_tool_id d2 ON d1.tool_id = d2.tool_id
        WHERE day BETWEEN ${start_day} AND ${end_day}
            AND act_method = '-1000012'
            AND act_method2 IN (1, 2)
            AND amount > 0
    ) u1
    INNER JOIN (
        SELECT
            user_id,
            money_type_id,
            -money AS money,
            record_time
        FROM g23000113.bi_money_list
        WHERE day BETWEEN ${start_day} AND ${end_day}
            AND act_method = '-1000012'
            AND act_method2 IN (1, 2)
            AND money < 0
            AND money_type_id IN (2, 3)
    ) u2 ON u1.user_id = u2.user_id AND u1.record_time = u2.record_time
    GROUP BY u2.user_id, money_type_id
) s3 ON s1.user_id = s3.user_id
GROUP BY
    ${start_day},
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END,
    CASE
        WHEN s2.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END;

--------------------------------------------------------------------------------
-- Section: Treasure Box Reward Exchange (宝箱兑换)
--------------------------------------------------------------------------------
WITH dim_tool_id AS (
    SELECT
        tool_id
    FROM (
        SELECT
            tool_id,
            ROW_NUMBER() OVER (ORDER BY amts DESC) AS rank
        FROM (
            SELECT
                tool_id,
                SUM(-amount) AS amts
            FROM g23000113.bi_tool_list
            WHERE day BETWEEN ${start_day} AND ${end_day}
                AND act_method = '-1000012'
                AND act_method2 > 10
                AND tool_id > 50000
                AND tool_id <> 50904
                AND amount < 0
                AND (CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 1 AND 22 OR CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42)
            GROUP BY tool_id
        ) u
    ) s
    WHERE s.rank = 1
)
SELECT
    ${start_day} AS day,
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END AS zone_type,
    CASE
        WHEN s1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    consume_obj,
    obtain_obj,
    COUNT(DISTINCT s2.user_id) AS pu,
    SUM(consume_diff) AS consume_diff, -- 消耗道具数量
    SUM(obtain_diff) AS obtain_diff, -- 获得道具数量
    '' AS obtain_name,
    COUNT(DISTINCT s1.user_id) AS desc_au
FROM (
    -- 活跃用户相关信息
    SELECT
        u1.user_id,
        COALESCE(vip, 0) AS vip,
        server
    FROM (
        SELECT
            user_id,
            MIN(CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS server
        FROM g23000113.bi_login_logs_day
        WHERE day BETWEEN ${start_day} AND ${end_day}
        GROUP BY user_id
    ) u1
    LEFT JOIN g23000113.user_blacklist u2 ON u1.user_id = u2.user_id
    LEFT JOIN (
        SELECT
            user_id,
            MAX(vip) AS vip
        FROM g23000113.bi_player
        WHERE day = ${start_day}
        GROUP BY user_id
    ) u3 ON u1.user_id = u3.user_id
    WHERE u2.user_id IS NULL
) s1
LEFT JOIN (
    -- 行为数据
    SELECT
        u1.user_id,
        u1.tool_id AS consume_obj,
        u2.tool_id AS obtain_obj,
        SUM(u1.amount) AS consume_diff,
        SUM(u2.amount) AS obtain_diff
    FROM (
        SELECT
            user_id,
            d1.tool_id,
            record_time,
            -amount AS amount
        FROM g23000113.bi_tool_list d1
        INNER JOIN dim_tool_id d2 ON d1.tool_id = d2.tool_id
        WHERE d1.day BETWEEN ${start_day} AND ${exchange_end}
            AND d1.act_method = '-1000012'
            AND d1.amount < 0
    ) u1
    INNER JOIN (
        SELECT
            user_id,
            record_time,
            tool_id,
            amount
        FROM g23000113.bi_tool_list
        WHERE day BETWEEN ${start_day} AND ${exchange_end}
            AND act_method = '-1000012'
            AND amount > 0
    ) u2 ON u1.user_id = u2.user_id AND u1.record_time = u2.record_time
    GROUP BY u1.user_id, u1.tool_id, u2.tool_id
) s2 ON s1.user_id = s2.user_id
WHERE consume_obj IS NOT NULL
GROUP BY
    ${start_day},
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END,
    CASE
        WHEN s1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END,
    consume_obj,
    obtain_obj;










--------------------------------------------------------------------------------
-- Section: Jackpot Performance (转盘)
--------------------------------------------------------------------------------
WITH dim_act_method2 AS (
    SELECT
        act_method2,
        ROW_NUMBER() OVER (ORDER BY amts DESC) AS rank
    FROM (
        SELECT
            act_method2,
            SUM(-money) AS amts
        FROM g23000113.bi_money_list
        WHERE day BETWEEN ${start_day} AND ${end_day}
            AND act_method = '-1000012'
            AND money < 0
            AND money_type_id IN (2, 3)
            AND server_id < 23
            AND LENGTH(act_method2) = 10
        GROUP BY act_method2
    ) s
)
SELECT
    ${start_day} AS day,
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END AS zone_type,
    CASE
        WHEN s2.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    COUNT(DISTINCT s1.user_id) AS au,
    COUNT(DISTINCT s3.user_id) AS pu,
    '' AS toolnum,
    SUM(CASE WHEN money_type_id = 2 THEN s3.money ELSE 0 END) - SUM(CASE WHEN money_type_id = 3 THEN s3.money ELSE 0 END) AS freediamond,
    SUM(CASE WHEN money_type_id = 3 THEN s3.money ELSE 0 END) AS paiddiamond,
    '' AS backdiamond
FROM (
    -- 活跃人数
    SELECT
        d1.user_id,
        server
    FROM (
        SELECT
            user_id,
            MIN(CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS server
        FROM g23000113.bi_login_logs_day
        WHERE day BETWEEN ${start_day} AND ${end_day}
        GROUP BY user_id
    ) d1
    LEFT JOIN (
        SELECT
            user_id
        FROM g23000113.user_blacklist
    ) d2 ON d1.user_id = d2.user_id
    WHERE d2.user_id IS NULL
) s1
LEFT JOIN (
    -- VIP
    SELECT
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day = ${start_day}
    GROUP BY user_id
) s2 ON s1.user_id = s2.user_id
LEFT JOIN (
    -- 行为数据
    SELECT
        user_id,
        money_type_id,
        -money AS money,
        record_time
    FROM g23000113.bi_money_list d1
    INNER JOIN dim_act_method2 d2 ON d1.act_method2 = d2.act_method2
    WHERE day BETWEEN ${start_day} AND ${end_day}
        AND act_method = '-1000012'
        AND money < 0
        AND money_type_id IN (2, 3)
        AND d2.rank = 1
) s3 ON s1.user_id = s3.user_id
GROUP BY
    ${start_day},
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END,
    CASE
        WHEN s2.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END;

--------------------------------------------------------------------------------
-- Section: Jackpot Reward Exchange (转盘兑换)
--------------------------------------------------------------------------------
WITH dim_tool_id AS (
    SELECT
        p2.tool_type,
        p2.tool_id
    FROM (
        SELECT
            tool_id AS nid,
            tool_id + 1 AS sid
        FROM (
            SELECT
                tool_id,
                ROW_NUMBER() OVER (ORDER BY amts DESC) AS rank
            FROM (
                SELECT
                    tool_id,
                    SUM(-amount) AS amts
                FROM g23000113.bi_tool_list
                WHERE day BETWEEN ${start_day} AND ${end_day}
                    AND act_method = '-1000012'
                    AND act_method2 > 10
                    AND tool_id > 50000
                    AND amount < 0
                    AND (CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 1 AND 22 OR CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42)
                GROUP BY tool_id
            ) u
        ) s
        WHERE s.rank = 1
    ) p1
    LATERAL VIEW EXPLODE(MAP('nid', nid, 'sid', sid)) p2 AS tool_type, tool_id
)
SELECT
    ${start_day} AS day,
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END AS zone_type,
    CASE
        WHEN s1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    consume_obj,
    obtain_obj,
    COUNT(DISTINCT s2.user_id) AS pu,
    SUM(consume_diff) AS consume_diff, -- 消耗道具数量
    SUM(obtain_diff) AS obtain_diff, -- 获得道具数量
    '' AS obtain_name
FROM (
    -- 活跃用户相关信息
    SELECT
        u1.user_id,
        COALESCE(vip, 0) AS vip,
        server
    FROM (
        SELECT
            user_id,
            MIN(CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS server
        FROM g23000113.bi_login_logs_day
        WHERE day BETWEEN ${start_day} AND ${end_day}
        GROUP BY user_id
    ) u1
    LEFT JOIN g23000113.user_blacklist u2 ON u1.user_id = u2.user_id
    LEFT JOIN (
        SELECT
            user_id,
            MAX(vip) AS vip
        FROM g23000113.bi_player
        WHERE day = ${start_day}
        GROUP BY user_id
    ) u3 ON u1.user_id = u3.user_id
    WHERE u2.user_id IS NULL
) s1
LEFT JOIN (
    -- 行为数据
    SELECT
        u1.user_id,
        u1.tool_id AS consume_obj,
        u2.tool_id AS obtain_obj,
        SUM(u1.amount) AS consume_diff,
        SUM(u2.amount) AS obtain_diff
    FROM (
        SELECT
            user_id,
            d1.tool_id,
            record_time,
            -amount AS amount
        FROM g23000113.bi_tool_list d1
        INNER JOIN dim_tool_id d2 ON d1.tool_id = d2.tool_id
        WHERE d1.day BETWEEN ${start_day} AND ${exchange_end}
            AND d1.act_method = '-1000012'
            AND d1.amount < 0
    ) u1
    INNER JOIN (
        SELECT
            user_id,
            record_time,
            tool_id,
            amount
        FROM g23000113.bi_tool_list
        WHERE day BETWEEN ${start_day} AND ${exchange_end}
            AND act_method = '-1000012'
            AND amount > 0
    ) u2 ON u1.user_id = u2.user_id AND u1.record_time = u2.record_time
    GROUP BY u1.user_id, u1.tool_id, u2.tool_id
) s2 ON s1.user_id = s2.user_id
WHERE consume_obj IS NOT NULL
GROUP BY
    ${start_day},
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END,
    CASE
        WHEN s1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END,
    consume_obj,
    obtain_obj;




--------------------------------------------------------------------------------
-- Section: Force Gacha Statistics (原力)
--------------------------------------------------------------------------------
SELECT
    ${start_day} AS day,
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END AS zone_type,
    CASE
        WHEN s2.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    COUNT(DISTINCT s1.user_id) AS au,
    COUNT(DISTINCT s3.user_id) AS pu,
    '' AS toolnum,
    SUM(CASE WHEN money_type_id = 2 THEN s3.money ELSE 0 END) - SUM(CASE WHEN money_type_id = 3 THEN s3.money ELSE 0 END) AS freediamond,
    SUM(CASE WHEN money_type_id = 3 THEN s3.money ELSE 0 END) AS paiddiamond,
    '' AS backdiamond
FROM (
    -- 活跃人数
    SELECT
        d1.user_id,
        server
    FROM (
        SELECT
            user_id,
            MIN(CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS server
        FROM g23000113.bi_login_logs_day
        WHERE day BETWEEN ${start_day} AND ${end_day}
        GROUP BY user_id
    ) d1
    LEFT JOIN (
        SELECT
            user_id
        FROM g23000113.user_blacklist
    ) d2 ON d1.user_id = d2.user_id
    WHERE d2.user_id IS NULL
) s1
LEFT JOIN (
    -- VIP
    SELECT
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day = ${start_day}
    GROUP BY user_id
) s2 ON s1.user_id = s2.user_id
LEFT JOIN (
    SELECT
        user_id,
        money_type_id,
        SUM(-money) AS money
    FROM g23000113.bi_money_list
    WHERE day BETWEEN ${start_day} AND ${end_day}
        AND money_type_id IN (2, 3)
        AND act_method = '-1033102' -- 原力抽卡 (修正了 act_method 拼写)
        AND money < 0
    GROUP BY user_id, money_type_id
) s3 ON s1.user_id = s3.user_id
GROUP BY
    ${start_day},
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END,
    CASE
        WHEN s2.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s2.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s2.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s2.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s2.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END;

--------------------------------------------------------------------------------
-- Section: Force Reward Exchange (原力兑换)
--------------------------------------------------------------------------------
WITH dim_tool_id AS (
    SELECT
        p2.tool_type,
        p2.tool_id
    FROM (
        SELECT
            tool_id AS nid,
            tool_id - 1 AS sid
        FROM (
            SELECT
                tool_id,
                ROW_NUMBER() OVER (ORDER BY amts DESC) AS rank
            FROM (
                SELECT
                    tool_id,
                    SUM(amount) AS amts
                FROM g23000113.bi_tool_list
                WHERE day BETWEEN ${start_day} AND ${end_day}
                    AND act_method = '-1033102' -- 原力抽卡
                    AND tool_id BETWEEN 50000 AND 60000
                    AND amount > 0
                    AND (CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 1 AND 22 OR CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42)
                GROUP BY tool_id
            ) u
        ) s
        WHERE s.rank = 1
    ) p1
    LATERAL VIEW EXPLODE(MAP('nid', nid, 'sid', sid)) p2 AS tool_type, tool_id
)
SELECT
    ${start_day} AS day,
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END AS zone_type,
    CASE
        WHEN s1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END AS viptype,
    consume_obj,
    obtain_obj,
    COUNT(DISTINCT s2.user_id) AS pu,
    SUM(consume_diff) AS consume_diff, -- 消耗道具数量
    SUM(obtain_diff) AS obtain_diff, -- 获得道具数量
    '' AS obtain_name
FROM (
    -- 活跃用户相关信息
    SELECT
        u1.user_id,
        COALESCE(vip, 0) AS vip,
        server
    FROM (
        SELECT
            user_id,
            MIN(CAST(REGEXP_REPLACE(server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS server
        FROM g23000113.bi_login_logs_day
        WHERE day BETWEEN ${start_day} AND ${end_day}
        GROUP BY user_id
    ) u1
    LEFT JOIN g23000113.user_blacklist u2 ON u1.user_id = u2.user_id
    LEFT JOIN (
        SELECT
            user_id,
            MAX(vip) AS vip
        FROM g23000113.bi_player
        WHERE day = ${start_day}
        GROUP BY user_id
    ) u3 ON u1.user_id = u3.user_id
    WHERE u2.user_id IS NULL
) s1
LEFT JOIN (
    -- 行为数据
    SELECT
        u1.user_id,
        u1.tool_id AS consume_obj,
        u2.tool_id AS obtain_obj,
        SUM(u1.amount) AS consume_diff,
        SUM(u2.amount) AS obtain_diff
    FROM (
        SELECT
            user_id,
            d1.tool_id,
            record_time,
            -amount AS amount
        FROM g23000113.bi_tool_list d1
        INNER JOIN dim_tool_id d2 ON d1.tool_id = d2.tool_id
        WHERE d1.day BETWEEN ${start_day} AND ${exchange_end}
            AND d1.act_method <> '-1000001'
            AND d1.amount < 0
    ) u1
    LEFT JOIN (
        SELECT
            user_id,
            record_time,
            tool_id,
            amount
        FROM g23000113.bi_tool_list
        WHERE day BETWEEN ${start_day} AND ${exchange_end}
            AND amount > 0
    ) u2 ON u1.user_id = u2.user_id AND u1.record_time = u2.record_time
    GROUP BY u1.user_id, u1.tool_id, u2.tool_id
) s2 ON s1.user_id = s2.user_id
WHERE consume_obj IS NOT NULL
GROUP BY
    ${start_day},
    CASE
        WHEN server BETWEEN 1 AND 22 THEN 'TW_LF'
        WHEN server BETWEEN 23 AND 41 THEN 'SEA'
        WHEN server = 42 THEN 'TW_HG'
    END,
    CASE
        WHEN s1.vip BETWEEN 1 AND 8 THEN '小R'
        WHEN s1.vip BETWEEN 9 AND 12 THEN '中R'
        WHEN s1.vip BETWEEN 13 AND 15 THEN '大R'
        WHEN s1.vip BETWEEN 16 AND 17 THEN '超R'
        WHEN s1.vip = 18 THEN '鲸鱼'
        ELSE '非R'
    END,
    consume_obj,
    obtain_obj;

