/*
================================================================================
Game: Saint Seiya 2
Region: TW
Description: Weekly KPI statistics tracking for project performance.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  1. Weekly Project KPI (WAU, WNU, Revenue)
  2. Weekly User Retention (RR1, RR3, RR7, RR14)
  3. Daily Project KPI (DAU, NUU, Revenue)
  4. Daily Recharge Gear Distribution (每日充值档位人数)
  5. User Registration Time Analysis (KPI_USER REGTIME)
  6. Diamond Stock and Flow Tracking (CUR_STOCK)

Parameters: 
  - ${start_day}: Start date for daily reports
  - ${end_day}: End date for daily reports
================================================================================
*/

-- Configuration
SET odps.sql.hive.compatible=True; 

--------------------------------------------------------------------------------
-- Section: Weekly Project KPI (WAU, WNU, Revenue)
--------------------------------------------------------------------------------
SELECT
    p1.week,
    p1.md_md,
    p1.wau,
    p2.nuu,
    p1.wau - p2.nuu AS ouu,
    p3.sales,
    p3.payuu,
    ROUND(p3.sales / p1.wau, 2) AS arpu,
    ROUND(p3.sales / p3.payuu, 2) AS arppu,
    ROUND(p3.payuu / p1.wau, 4) AS payrate
FROM (
    -- WAU
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 2), '.', SUBSTR(MIN(day), 7, 2), '-', SUBSTR(MAX(day), 5, 2), '.', SUBSTR(MAX(day), 7, 2)) AS md_md,
        COUNT(DISTINCT lid) AS wau
    FROM g23000113.user_session_new
    WHERE day >= 20191210
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p1
LEFT JOIN (
    -- WNU
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 4), '-', SUBSTR(MAX(day), 5, 4)) AS day,
        COUNT(DISTINCT lid) AS nuu
    FROM g23000113.user_data_new
    WHERE day >= 20191210
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p2 ON p1.week = p2.week
LEFT JOIN (
    -- WKLY Revenue
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 4), '-', SUBSTR(MAX(day), 5, 4)) AS day,
        COUNT(DISTINCT lid) AS payuu,
        SUM(lnum / 5) AS sales
    FROM g23000113.purchase_vc_new
    WHERE day >= 20191210
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p3 ON p1.week = p3.week
ORDER BY p1.week;

--------------------------------------------------------------------------------
-- Section: Weekly User Retention (RR1, RR3, RR7, RR14)
--------------------------------------------------------------------------------
SELECT
    CEIL(DATEDIFF(CONCAT(SUBSTR(p.day, 1, 4), '-', SUBSTR(p.day, 5, 2), '-', SUBSTR(p.day, 7, 2)), '2018-07-29') / 7) AS week,
    CONCAT(SUBSTR(MIN(day), 5, 2), '.', SUBSTR(MIN(day), 7, 2), '-', SUBSTR(MAX(day), 5, 2), '.', SUBSTR(MAX(day), 7, 2)) AS md_md,
    p.device_id AS plat,
    SUM(nuu) AS wnu,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 1 THEN ROUND(SUM(p.r1) / SUM(nuu), 4)
    END AS RR1,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 3 THEN ROUND(SUM(p.r3) / SUM(nuu), 4)
    END AS RR3,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 7 THEN ROUND(SUM(p.r7) / SUM(nuu), 4)
    END AS RR7,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 14 THEN ROUND(SUM(p.r14) / SUM(nuu), 4)
    END AS RR14
FROM (
    -- 新用户与之后各个日期的留存人数
    SELECT
        s1.day,
        s1.device_id,
        COUNT(DISTINCT s1.user_id) AS nuu,
        COUNT(DISTINCT CASE WHEN DATEDIFF(s2.day2, s1.day1) = 1 THEN s2.user_id ELSE NULL END) AS r1,
        COUNT(DISTINCT CASE WHEN DATEDIFF(s2.day2, s1.day1) = 3 THEN s2.user_id ELSE NULL END) AS r3,
        COUNT(DISTINCT CASE WHEN DATEDIFF(s2.day2, s1.day1) = 7 THEN s2.user_id ELSE NULL END) AS r7,
        COUNT(DISTINCT CASE WHEN DATEDIFF(s2.day2, s1.day1) = 14 THEN s2.user_id ELSE NULL END) AS r14
    FROM (
        SELECT DISTINCT
            day,
            CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)) AS day1,
            lid AS user_id,
            store_type AS device_id
        FROM g23000113.user_data_new
        WHERE day >= 20191210
    ) s1
    LEFT JOIN (
        SELECT
            day,
            CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)) AS day2,
            lid AS user_id,
            COUNT(1) AS cnt
        FROM g23000113.user_session_new
        WHERE day >= 20191210
        GROUP BY day, lid
    ) s2 ON s1.user_id = s2.user_id
    GROUP BY s1.day, s1.device_id
) p
GROUP BY
    CEIL(DATEDIFF(CONCAT(SUBSTR(p.day, 1, 4), '-', SUBSTR(p.day, 5, 2), '-', SUBSTR(p.day, 7, 2)), '2018-07-29') / 7),
    p.device_id
ORDER BY plat, week DESC;

--------------------------------------------------------------------------------
-- Section: Daily Project KPI (DAU, NUU, Revenue)
--------------------------------------------------------------------------------
SELECT
    SUBSTR(p1.day, 1, 4) AS year,
    CONCAT(SUBSTR(p1.day, 5, 2), '.', SUBSTR(p1.day, 7, 2)) AS md,
    p1.dau,
    p2.nuu,
    p1.dau - p2.nuu AS ouu,
    p3.sales,
    p3.payuu,
    ROUND(p3.sales / p1.dau, 2) AS arpu,
    ROUND(p3.sales / p3.payuu) AS arppu,
    ROUND(p3.payuu / p1.dau, 4) AS payrate
FROM (
    -- DAU
    SELECT
        day,
        COUNT(DISTINCT lid) AS dau
    FROM g23000113.user_session_new
    WHERE day >= 20191210
    GROUP BY day
) p1
LEFT JOIN (
    -- NUU
    SELECT
        day,
        COUNT(DISTINCT lid) AS nuu
    FROM g23000113.user_data_new
    WHERE day >= 20191210
    GROUP BY day
) p2 ON p1.day = p2.day
LEFT JOIN (
    -- 充值
    SELECT
        day,
        COUNT(DISTINCT lid) AS payuu,
        SUM(lnum / 5) AS sales
    FROM g23000113.purchase_vc_new
    WHERE day >= 20191210
    GROUP BY day
) p3 ON p1.day = p3.day
ORDER BY year DESC, md DESC;

--------------------------------------------------------------------------------
-- Section: Daily Recharge Gear Distribution (每日充值档位人数)
--------------------------------------------------------------------------------
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
        lid AS user_id,
        SUM(lnum / 5) AS spend
    FROM g23000113.purchase_vc_new
    WHERE day >= 20200403
    GROUP BY day, lid
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
-- Section: User Registration Time Analysis (KPI_USER REGTIME)
--------------------------------------------------------------------------------
SELECT
    p3.week,
    p3.md_md,
    COALESCE(p2.reg_month, '201604') AS reg_month,
    COUNT(DISTINCT p1.user_id) AS user_count
FROM (
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        day,
        lid AS user_id,
        COUNT(1) AS cnt
    FROM g23000113.user_session_new
    WHERE day >= 20191210
    GROUP BY
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7),
        day,
        lid
) p1
LEFT JOIN (
    SELECT
        SUBSTR(day, 1, 6) AS reg_month,
        lid AS user_id
    FROM g23000113.user_data_new
    WHERE day >= 20160401
) p2 ON p1.user_id = p2.user_id
LEFT JOIN (
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 2), '.', SUBSTR(MIN(day), 7, 2), '-', SUBSTR(MAX(day), 5, 2), '.', SUBSTR(MAX(day), 7, 2)) AS md_md
    FROM g23000113.user_data_new
    WHERE day >= 20191210
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p3 ON p1.week = p3.week
GROUP BY
    p3.week,
    p3.md_md,
    COALESCE(p2.reg_month, '201604')
ORDER BY p3.week, p3.md_md, reg_month;

--------------------------------------------------------------------------------
-- Section: Diamond Stock and Flow Tracking (CUR_STOCK)
--------------------------------------------------------------------------------
SELECT
    p1.day,
    PERCENTILE(CAST(CASE WHEN COALESCE(p2.vip, 0) = 0 THEN p1.diamond END AS INT), 0.5) AS v0,
    PERCENTILE(CAST(CASE WHEN p2.vip = 1 THEN p1.diamond END AS INT), 0.5) AS v1,
    PERCENTILE(CAST(CASE WHEN p2.vip = 2 THEN p1.diamond END AS INT), 0.5) AS v2,
    PERCENTILE(CAST(CASE WHEN p2.vip = 3 THEN p1.diamond END AS INT), 0.5) AS v3,
    PERCENTILE(CAST(CASE WHEN p2.vip = 4 THEN p1.diamond END AS INT), 0.5) AS v4,
    PERCENTILE(CAST(CASE WHEN p2.vip = 5 THEN p1.diamond END AS INT), 0.5) AS v5,
    PERCENTILE(CAST(CASE WHEN p2.vip = 6 THEN p1.diamond END AS INT), 0.5) AS v6,
    PERCENTILE(CAST(CASE WHEN p2.vip = 7 THEN p1.diamond END AS INT), 0.5) AS v7,
    PERCENTILE(CAST(CASE WHEN p2.vip = 8 THEN p1.diamond END AS INT), 0.5) AS v8,
    PERCENTILE(CAST(CASE WHEN p2.vip = 9 THEN p1.diamond END AS INT), 0.5) AS v9,
    PERCENTILE(CAST(CASE WHEN p2.vip = 10 THEN p1.diamond END AS INT), 0.5) AS v10,
    PERCENTILE(CAST(CASE WHEN p2.vip = 11 THEN p1.diamond END AS INT), 0.5) AS v11,
    PERCENTILE(CAST(CASE WHEN p2.vip = 12 THEN p1.diamond END AS INT), 0.5) AS v12,
    PERCENTILE(CAST(CASE WHEN p2.vip = 13 THEN p1.diamond END AS INT), 0.5) AS v13,
    PERCENTILE(CAST(CASE WHEN p2.vip = 14 THEN p1.diamond END AS INT), 0.5) AS v14,
    PERCENTILE(CAST(CASE WHEN p2.vip = 15 THEN p1.diamond END AS INT), 0.5) AS v15,
    PERCENTILE(CAST(CASE WHEN p2.vip = 16 THEN p1.diamond END AS INT), 0.5) AS v16,
    PERCENTILE(CAST(CASE WHEN p2.vip = 17 THEN p1.diamond END AS INT), 0.5) AS v17,
    PERCENTILE(CAST(CASE WHEN p2.vip = 18 THEN p1.diamond END AS INT), 0.5) AS v18
FROM (
    SELECT
        s1.day,
        s1.user_id,
        s1.server,
        s1.diamond
    FROM (
        SELECT
            u1.day,
            u1.user_id,
            u1.server,
            u2.diamond,
            ROW_NUMBER() OVER (PARTITION BY u1.day, u1.user_id ORDER BY u2.day DESC) AS rank
        FROM (
            SELECT
                d1.day,
                d2.user_id,
                d2.server,
                COUNT(1) AS cnt
            FROM (
                SELECT
                    day,
                    CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS sday,
                    COUNT(1) AS cnt,
                    '1' AS t
                FROM g23000113.bi_login_logs_day
                WHERE day BETWEEN ${start_day} AND ${end_day}
                GROUP BY day
            ) d1
            LEFT JOIN (
                SELECT
                    day,
                    server,
                    CONCAT_WS('-', SUBSTR(day, 1, 4), SUBSTR(day, 5, 2), SUBSTR(day, 7, 2)) AS sday,
                    user_id,
                    COUNT(1) AS cnt,
                    '1' AS t
                FROM g23000113.bi_login_logs_day
                WHERE day BETWEEN ${start_day} AND ${end_day}
                GROUP BY day, user_id, server
            ) d2 ON d1.t = d2.t
            WHERE DATEDIFF(d1.sday, d2.sday) BETWEEN 0 AND 13
            GROUP BY d1.day, d2.user_id, d2.server
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
                    ROW_NUMBER() OVER (PARTITION BY day, user_id ORDER BY record_time DESC) AS rank
                FROM g23000113.bi_money_list
                WHERE day BETWEEN ${start_day} AND ${end_day}
                    AND money_type_id = 2
            ) d1
            WHERE d1.rank = 1
        ) u2 ON u1.user_id = u2.user_id
        LEFT JOIN g23000113.user_blacklist u3 ON u1.user_id = u3.user_id
        WHERE u1.day >= u2.day
            AND u3.user_id IS NULL
    ) s1
    WHERE s1.rank = 1
) p1
LEFT JOIN (
    SELECT
        day,
        user_id,
        MAX(vip) AS vip
    FROM g23000113.bi_player
    WHERE day >= ${start_day}
    GROUP BY day, user_id
) p2 ON p1.user_id = p2.user_id AND p1.day = p2.day
WHERE CAST(REGEXP_REPLACE(p1.server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) BETWEEN 1 AND 22
    OR CAST(REGEXP_REPLACE(p1.server, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) = 42
GROUP BY p1.day
ORDER BY p1.day;
