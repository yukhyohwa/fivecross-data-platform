/*
================================================================================
Game: Saint Seiya 2
Region: CN
Description: Weekly general statistics for project performance tracking.
Author: Antigravity
Created: 2026-01-20

Current Queries:
  1. Install Data Modification (daily_game_install_mod)
  2. Payment Data Modification (daily_game_payment_mod)
  3. Login Data Modification (daily_game_login_mod)
  4. Blacklist Generation (dangle_blacklist)
  5. Weekly New/Old User Stats (KPI Calculation)
  6. Weekly KPI (WAU, WNU, Revenue)
  7. Weekly Retention Rates (RR1, RR3, RR7, RR14)
  8. Daily KPI (DAU, NUU, Revenue)
  9. Daily Recharge Gear Distribution (每日充值档位人数)
  10. Weekly Channel Performance (KPI_CHANNEL)
  11. User registration time analysis (KPI_USER REGTIME)
  12. Daily Currency Spend Detail (CUR_SPEND)
  13. Daily Currency Stock (CUR_STOCK)
================================================================================
*/

-- Configuration
SET odps.sql.hive.compatible=True; 

--------------------------------------------------------------------------------
-- Section: Install Data Modification (daily_game_install_mod)
--------------------------------------------------------------------------------
INSERT OVERWRITE TABLE g10000001.daily_game_install_mod
SELECT
    COALESCE(phone_device, 0) AS user_id,
    record_time AS install_time,
    COALESCE(p1.platform_id, 'unknown') AS store,
    COALESCE(COALESCE(p2.platform_name, p1.platform_id), 'unknown') AS affcode,
    '' AS app_ver,
    CASE
        WHEN system_type = 'IOS' THEN 8
        WHEN system_type = 'Android' THEN 16
        ELSE 'unknown'
    END AS device_id,
    '' AS devicename,
    '' AS mac,
    ip,
    '' AS province,
    '' AS city,
    '' AS carrier,
    CASE
        WHEN system_type = 'IOS' THEN SPLIT(phone_device, '_')[1]
        ELSE NULL
    END AS idfa,
    CASE
        WHEN system_type = 'Android' AND LENGTH(phone_device) NOT IN (15, 16) THEN phone_device
        ELSE NULL
    END AS Android_id,
    '' AS imsi,
    CASE
        WHEN system_type = 'Android' AND LENGTH(phone_device) IN (15, 16) THEN phone_device
        ELSE NULL
    END AS imei,
    FROM_UNIXTIME(record_time, 'yyyyMMdd') AS day,
    zone
FROM (
    SELECT
        phone_device,
        record_time,
        ip,
        system_type,
        platform_user_id,
        platform_id,
        zone,
        ROW_NUMBER() OVER (PARTITION BY phone_device ORDER BY record_time) AS phone_rank
    FROM (
        SELECT
            CASE
                WHEN system_type IN ('IOS')
                    AND SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] IN ('360IOS', 'MbaoGios', 'ZD')
                    THEN REGEXP_REPLACE(platform_user_id, '__', '_')
                ELSE phone_device
            END AS phone_device,
            record_time,
            ip,
            system_type,
            platform_user_id,
            user_id,
            vip,
            level,
            zone,
            CASE
                WHEN bi_platform_id IN (222, 19) THEN bi_platform_id
                ELSE platform_id
            END AS platform_id,
            ROW_NUMBER() OVER (PARTITION BY platform_user_id ORDER BY record_time) AS plat_rank
        FROM g10000001.bi_player
        WHERE day = 20201227
    ) s1
    WHERE s1.plat_rank = 1
) p1
LEFT JOIN g10000001.dim_affcode p2 ON p1.platform_id = p2.platform_id
WHERE p1.phone_rank = 1;

--------------------------------------------------------------------------------
-- Section: Payment Data Modification (daily_game_payment_mod)
--------------------------------------------------------------------------------
INSERT OVERWRITE TABLE g10000001.daily_game_payment_mod
SELECT
    s1.record_time AS payment_time,
    COALESCE(s2.phone_device, 0) AS user_id,
    COALESCE(s2.platform_id, 'unknown') AS store,
    COALESCE(COALESCE(s4.platform_name, s2.platform_id), 'unknown') AS affcode,
    '' AS app_ver,
    CASE
        WHEN s2.system_type = 'IOS' THEN 8
        WHEN s2.system_type = 'Android' THEN 16
        ELSE 'unknown'
    END AS device_id,
    '' AS province,
    '' AS city,
    '' AS idfa,
    rmb AS paid_num,
    '' AS free_num,
    day
FROM (
    SELECT
        day,
        order_id,
        user_id,
        rmb,
        record_time
    FROM g10000001.bi_order_logs
    WHERE day BETWEEN 20191210 AND 20201227
) s1
LEFT JOIN (
    SELECT
        u1.phone_device,
        u1.system_type,
        u1.platform_id,
        u1.ip,
        u2.user_id
    FROM (
        SELECT
            d.phone_device,
            d.platform_user_id,
            d.system_type,
            d.platform_id,
            d.ip
        FROM (
            SELECT
                CASE
                    WHEN system_type IN ('IOS')
                        AND SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] IN ('360IOS', 'MbaoGios', 'ZD')
                        THEN REGEXP_REPLACE(platform_user_id, '__', '_')
                    ELSE phone_device
                END AS phone_device,
                record_time,
                ip,
                system_type,
                platform_user_id,
                user_id,
                vip,
                level,
                zone,
                CASE
                    WHEN bi_platform_id IN (222, 19) THEN bi_platform_id
                    ELSE platform_id
                END AS platform_id,
                ROW_NUMBER() OVER (PARTITION BY platform_user_id ORDER BY record_time) AS plat_rank
            FROM g10000001.bi_player
            WHERE day = 20201227
                AND system_type IN ('IOS', 'Android')
        ) d
        WHERE d.plat_rank = 1
    ) u1
    LEFT JOIN (
        SELECT DISTINCT
            platform_user_id,
            user_id
        FROM g10000001.bi_player
        WHERE day = 20201227
    ) u2 ON u1.platform_user_id = u2.platform_user_id
) s2 ON s1.user_id = s2.user_id
LEFT JOIN g10000001_dev.orderidblacklist s3 ON s1.order_id = s3.orderid
LEFT JOIN g10000001.dim_affcode s4 ON s2.platform_id = s4.platform_id
WHERE s3.orderid IS NULL;

--------------------------------------------------------------------------------
-- Section: Login Data Modification (daily_game_login_mod)
--------------------------------------------------------------------------------
INSERT OVERWRITE TABLE g10000001.daily_game_login_mod
SELECT DISTINCT
    COALESCE(s2.phone_device, 0) AS user_id,
    COALESCE(s2.platform_id, 'unknown') AS store,
    COALESCE(COALESCE(s3.platform_name, s2.platform_id), 'unknown') AS affcode,
    '' AS app_ver,
    CASE
        WHEN s2.system_type = 'IOS' THEN 8
        WHEN s2.system_type = 'Android' THEN 16
        ELSE 'unknown'
    END AS device_id,
    '' AS devicename,
    '' AS mac,
    s2.ip,
    '' AS province,
    '' AS city,
    '' AS carrier,
    CASE
        WHEN s2.system_type = 'IOS' THEN SPLIT(s2.phone_device, '_')[1]
        ELSE NULL
    END AS idfa,
    CASE
        WHEN s2.system_type = 'Android' AND LENGTH(s2.phone_device) NOT IN (15, 16) THEN s2.phone_device
        ELSE NULL
    END AS Android_id,
    '' AS imsi,
    CASE
        WHEN s2.system_type = 'Android' AND LENGTH(s2.phone_device) IN (15, 16) THEN s2.phone_device
        ELSE NULL
    END AS imei,
    day
FROM (
    SELECT DISTINCT
        day,
        user_id
    FROM g10000001.bi_login_logs_day
    WHERE day BETWEEN 20191210 AND 20201227
) s1
LEFT JOIN (
    SELECT
        u1.phone_device,
        u1.system_type,
        u1.platform_id,
        u1.ip,
        u2.user_id
    FROM (
        SELECT
            d.phone_device,
            d.platform_user_id,
            d.system_type,
            d.platform_id,
            d.ip
        FROM (
            SELECT
                CASE
                    WHEN system_type IN ('IOS')
                        AND SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] IN ('360IOS', 'MbaoGios', 'ZD')
                        THEN REGEXP_REPLACE(platform_user_id, '__', '_')
                    ELSE phone_device
                END AS phone_device,
                record_time,
                ip,
                system_type,
                platform_user_id,
                user_id,
                vip,
                level,
                zone,
                CASE
                    WHEN bi_platform_id IN (222, 19) THEN bi_platform_id
                    ELSE platform_id
                END AS platform_id,
                ROW_NUMBER() OVER (PARTITION BY platform_user_id ORDER BY record_time) AS plat_rank
            FROM g10000001.bi_player
            WHERE day = 20201227
                AND system_type IN ('IOS', 'Android')
        ) d
        WHERE d.plat_rank = 1
    ) u1
    LEFT JOIN (
        SELECT DISTINCT
            platform_user_id,
            user_id
        FROM g10000001.bi_player
        WHERE day = 20201227
    ) u2 ON u1.platform_user_id = u2.platform_user_id
) s2 ON s1.user_id = s2.user_id
LEFT JOIN g10000001.dim_affcode s3 ON s2.platform_id = s3.platform_id;

--------------------------------------------------------------------------------
-- Section: Blacklist Generation (dangle_blacklist)
--------------------------------------------------------------------------------
INSERT OVERWRITE TABLE g10000001.dangle_blacklist
SELECT DISTINCT
    user_id
FROM (
    SELECT
        user_id
    FROM g10000001.daily_game_install_mod
    WHERE day >= 20200401
        AND affcode = '当乐安卓2'
) p1
LEFT JOIN (
    SELECT
        phone_device,
        zone
    FROM (
        SELECT
            phone_device,
            zone,
            ROW_NUMBER() OVER (PARTITION BY phone_device ORDER BY record_time) AS rank
        FROM g10000001.bi_player
        WHERE day = 20201227
    ) s
    WHERE s.rank = 1
) p2 ON p1.user_id = p2.phone_device
WHERE p2.zone IN ('mix_s260', 'mix_s239');


--------------------------------------------------------------------------------
-- Section: Weekly New/Old User Stats (KPI Calculation)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    p2.day,
    SPLIT(p1.zone, '_s')[1] AS zone,
    SPLIT(p1.zone, '_s')[0] AS zone_type,
    CASE
        WHEN p1.zone = p1.zonearray[0] THEN 'NU'
        ELSE CONCAT('OU', '_', p1.platarray[0])
    END AS user_type,
    SUM(p4.dsales) AS wsales,
    COUNT(DISTINCT p1.user_id) AS wnu,
    COUNT(DISTINCT p4.user_id) AS wpu
FROM (
    SELECT
        s1.phone_device,
        s1.user_id,
        s1.creroleday,
        s1.plat,
        s1.zone,
        s2.platarray,
        s2.zonearray,
        s1.record_time
    FROM (
        SELECT
            u1.phone_device,
            u2.user_id,
            u2.plat,
            u2.zone,
            u2.creroleday,
            u2.record_time
        FROM (
            SELECT
                d.phone_device,
                record_time,
                ip,
                system_type,
                platform_user_id,
                user_id,
                vip,
                level,
                zone,
                platform_id,
                plat_rank
            FROM (
                SELECT
                    CASE
                        WHEN system_type IN ('IOS')
                            AND SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] IN ('360IOS', 'MbaoGios', 'ZD')
                            THEN REGEXP_REPLACE(platform_user_id, '__', '_')
                        ELSE phone_device
                    END AS phone_device,
                    record_time,
                    ip,
                    system_type,
                    platform_user_id,
                    user_id,
                    vip,
                    level,
                    zone,
                    CASE
                        WHEN bi_platform_id IN (222, 19) THEN bi_platform_id
                        ELSE platform_id
                    END AS platform_id,
                    ROW_NUMBER() OVER (PARTITION BY platform_user_id ORDER BY record_time) AS plat_rank
                FROM g10000001.bi_player
                WHERE day = 20201227
                    AND system_type IN ('IOS', 'Android')
            ) d
            WHERE d.plat_rank = 1
        ) u1
        LEFT JOIN (
            SELECT
                platform_user_id,
                user_id,
                zone,
                record_time,
                SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] AS plat,
                FROM_UNIXTIME(record_time, 'yyyy-MM-dd') AS creroleday,
                ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)) AS dup
            FROM g10000001.bi_player
            WHERE day = 20201227
        ) u2 ON u1.platform_user_id = u2.platform_user_id
        WHERE CAST(FROM_UNIXTIME(u2.record_time, 'yyyyMMdd') AS INT) >= 20191210
    ) s1
    LEFT JOIN (
        SELECT
            u.phone_device,
            COLLECT_LIST(u.plat) AS platarray,
            COLLECT_LIST(u.zone) AS zonearray
        FROM (
            SELECT
                d.phone_device,
                d.record_time,
                d.ip,
                d.system_type,
                d.platform_user_id,
                d.user_id,
                vip,
                level,
                zone,
                plat,
                ROW_NUMBER() OVER (PARTITION BY phone_device ORDER BY record_time) AS user_rank
            FROM (
                SELECT
                    CASE
                        WHEN system_type IN ('IOS')
                            AND SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] IN ('360IOS', 'MbaoGios', 'ZD')
                            THEN REGEXP_REPLACE(platform_user_id, '__', '_')
                        ELSE phone_device
                    END AS phone_device,
                    record_time,
                    ip,
                    system_type,
                    platform_user_id,
                    user_id,
                    vip,
                    level,
                    zone,
                    SPLIT(REGEXP_REPLACE(platform_user_id, '__', '_'), '_')[0] AS plat,
                    CASE
                        WHEN bi_platform_id IN (222, 19) THEN bi_platform_id
                        ELSE platform_id
                    END AS platform_id
                FROM g10000001.bi_player
                WHERE day = 20201227
                    AND system_type IN ('IOS', 'Android')
            ) d
        ) u
        GROUP BY u.phone_device
    ) s2 ON s1.phone_device = s2.phone_device
) p1
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
        WHERE day = 20201227
            AND zone <> 'ios_s190'
        GROUP BY zone, FROM_UNIXTIME(record_time, 'yyyyMMdd')
    ) u1
    WHERE nu >= 15
    GROUP BY zone
    UNION ALL
    SELECT 'ios_s190' AS zone, '20190531' AS day, '2019-05-31' AS openday
) p2 ON p1.zone = p2.zone
LEFT JOIN (
    SELECT DISTINCT user_id
    FROM (
        SELECT DISTINCT user_id
        FROM g10000001_dev.user_blacklist
        UNION ALL
        SELECT DISTINCT user_id
        FROM g10000001.dangle_blacklist
    ) d
) p3 ON p1.user_id = p3.user_id
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
) p4 ON p1.user_id = p4.user_id
WHERE DATEDIFF(p1.creroleday, p2.openday) BETWEEN 0 AND 7
    AND (DATEDIFF(p4.payday, p2.openday) BETWEEN 0 AND 7 OR p4.payday IS NULL)
    AND p3.user_id IS NULL
GROUP BY
    p2.day,
    p1.zone,
    CASE
        WHEN p1.zone = p1.zonearray[0] THEN 'NU'
        ELSE CONCAT('OU', '_', p1.platarray[0])
    END;

--------------------------------------------------------------------------------
-- Section: Weekly KPI (WAU, WNU, Revenue)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
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
        COUNT(DISTINCT s1.user_id) AS wau
    FROM g10000001.daily_game_login_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p1
LEFT JOIN (
    -- WNU
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 4), '-', SUBSTR(MAX(day), 5, 4)) AS day,
        COUNT(DISTINCT s1.user_id) AS nuu
    FROM g10000001.daily_game_install_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p2 ON p1.week = p2.week
LEFT JOIN (
    -- WKLY Revenue
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 4), '-', SUBSTR(MAX(day), 5, 4)) AS day,
        COUNT(DISTINCT s1.user_id) AS payuu,
        SUM(paid_num) AS sales
    FROM g10000001.daily_game_payment_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p3 ON p1.week = p3.week
ORDER BY week;

--------------------------------------------------------------------------------
-- Section: Weekly Retention Rates (RR1, RR3, RR7, RR14)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    CEIL(DATEDIFF(CONCAT(SUBSTR(p.day, 1, 4), '-', SUBSTR(p.day, 5, 2), '-', SUBSTR(p.day, 7, 2)), '2018-07-29') / 7) AS week,
    CONCAT(SUBSTR(MIN(day), 5, 2), '.', SUBSTR(MIN(day), 7, 2), '-', SUBSTR(MAX(day), 5, 2), '.', SUBSTR(MAX(day), 7, 2)) AS md_md,
    CASE
        WHEN p.device_id = 8 THEN 'ios'
        WHEN p.device_id = 16 THEN 'android'
        ELSE NULL
    END AS plat,
    SUM(nuu) AS wnu,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 1
            THEN ROUND(SUM(p.r1) / SUM(nuu), 4)
    END AS RR1,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 3
            THEN ROUND(SUM(p.r3) / SUM(nuu), 4)
    END AS RR3,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 7
            THEN ROUND(SUM(p.r7) / SUM(nuu), 4)
    END AS RR7,
    CASE
        WHEN DATEDIFF(TO_DATE(CURRENT_TIMESTAMP()), CONCAT_WS('-', SUBSTR(MAX(day), 1, 4), SUBSTR(MAX(day), 5, 2), SUBSTR(MAX(day), 7, 2))) > 14
            THEN ROUND(SUM(p.r14) / SUM(nuu), 4)
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
            user_id,
            device_id
        FROM g10000001.daily_game_install_mod
        WHERE day >= 20191210
    ) s1
    LEFT JOIN (
        SELECT DISTINCT
            day,
            CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)) AS day2,
            user_id
        FROM g10000001.daily_game_login_mod
        WHERE day >= 20191210
    ) s2 ON s1.user_id = s2.user_id
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE s3.user_id IS NULL
    GROUP BY s1.day, s1.device_id
) p
GROUP BY
    CEIL(DATEDIFF(CONCAT(SUBSTR(p.day, 1, 4), '-', SUBSTR(p.day, 5, 2), '-', SUBSTR(p.day, 7, 2)), '2018-07-29') / 7),
    CASE
        WHEN p.device_id = 8 THEN 'ios'
        WHEN p.device_id = 16 THEN 'android'
        ELSE NULL
    END
ORDER BY plat, week DESC;

--------------------------------------------------------------------------------
-- Section: Daily KPI (DAU, NUU, Revenue)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
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
        COUNT(DISTINCT s1.user_id) AS dau
    FROM g10000001.daily_game_login_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY day
) p1
LEFT JOIN (
    -- NUU
    SELECT
        day,
        COUNT(DISTINCT s1.user_id) AS nuu
    FROM g10000001.daily_game_install_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY day
) p2 ON p1.day = p2.day
LEFT JOIN (
    -- 充值
    SELECT
        day,
        COUNT(DISTINCT s1.user_id) AS payuu,
        SUM(paid_num) AS sales
    FROM g10000001.daily_game_payment_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY day
) p3 ON p1.day = p3.day
ORDER BY year DESC, md DESC;

--------------------------------------------------------------------------------
-- Section: Daily Recharge Gear Distribution (每日充值档位人数)
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
-- Section: Weekly Channel Performance (KPI_CHANNEL)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    p1.week,
    p1.md_md,
    p2.affcode,
    p2.wau,
    COALESCE(p3.wnu, 0) AS wnu
FROM (
    -- 取时间，payment表比较小
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 2), '.', SUBSTR(MIN(day), 7, 2), '-', SUBSTR(MAX(day), 5, 2), '.', SUBSTR(MAX(day), 7, 2)) AS md_md
    FROM g10000001.daily_game_payment_mod
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p1
RIGHT JOIN (
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        affcode,
        COUNT(DISTINCT s1.user_id) AS wau
    FROM g10000001.daily_game_login_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7),
        affcode
) p2 ON p1.week = p2.week
LEFT JOIN (
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        affcode,
        COUNT(DISTINCT s1.user_id) AS wnu
    FROM g10000001.daily_game_install_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
    GROUP BY
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7),
        affcode
) p3 ON p2.week = p3.week AND p2.affcode = p3.affcode
ORDER BY md_md, affcode;

--------------------------------------------------------------------------------
-- Section: User registration time analysis (KPI_USER REGTIME)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
SELECT
    p3.week,
    p3.md_md,
    COALESCE(p2.reg_month, '201604') AS reg_month,
    COUNT(DISTINCT p1.user_id) AS user_count
FROM (
    SELECT DISTINCT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        day,
        s1.user_id
    FROM g10000001.daily_game_login_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20191210
        AND s3.user_id IS NULL
) p1
LEFT JOIN (
    SELECT
        SUBSTR(day, 1, 6) AS reg_month,
        s1.user_id
    FROM g10000001.daily_game_install_mod s1
    LEFT JOIN (
        SELECT DISTINCT user_id
        FROM (
            SELECT DISTINCT mbga_uid AS user_id
            FROM g10000001_dev.user_blacklist
            UNION ALL
            SELECT DISTINCT user_id
            FROM g10000001.dangle_blacklist
        ) d
    ) s3 ON s1.user_id = s3.user_id
    WHERE day >= 20160401
        AND s3.user_id IS NULL
) p2 ON p1.user_id = p2.user_id
LEFT JOIN (
    SELECT
        CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7) AS week,
        CONCAT(SUBSTR(MIN(day), 5, 2), '.', SUBSTR(MIN(day), 7, 2), '-', SUBSTR(MAX(day), 5, 2), '.', SUBSTR(MAX(day), 7, 2)) AS md_md
    FROM g10000001.daily_game_login_mod
    WHERE day >= 20191210
    GROUP BY CEIL(DATEDIFF(CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)), '2018-07-29') / 7)
) p3 ON p1.week = p3.week
GROUP BY
    p3.week,
    p3.md_md,
    COALESCE(p2.reg_month, '201604')
ORDER BY week, md_md, reg_month;

--------------------------------------------------------------------------------
-- Section: Daily Currency Spend Detail (CUR_SPEND)
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
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3904', 'item@40431', 'item@40432', 'item@40433', 'item@40434') THEN '主题召唤'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3789') THEN '魂匣'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40294') THEN '圣域宝箱'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40404') THEN '圣衣制作台'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40426') THEN '黄金魂转盘'
            WHEN a_typ = 'activity_buy' AND obj2 NOT IN ('item@3789', 'item@40185', 'item@3787', 'item@40294', 'item@3904', 'item@40404', 'item@40426', 'item@40431', 'item@40432', 'item@40433', 'item@40434') THEN '其他活动'
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
        WHERE obj IN ('item@3904', 'item@40431', 'item@40432', 'item@40433', 'item@40434', 'dmp:money', 'dmp:paidmoney')
            AND diff < 0
            AND day >= 20201127
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
        WHERE day >= 20201227
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
            WHERE day >= 20201227
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
        SELECT DISTINCT
            mbga_uid AS user_id
        FROM g10000001.user_blacklist
    ) p5 ON p1.user_id = p5.user_id
    WHERE DATEDIFF(p1.loginday, p4.openday) >= 7
        AND p5.user_id IS NULL
    GROUP BY
        p1.day,
        CASE
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3787') THEN '转盘'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40185') THEN '跨服原力'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3904', 'item@40431', 'item@40432', 'item@40433', 'item@40434') THEN '主题召唤'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@3789') THEN '魂匣'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40294') THEN '圣域宝箱'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40404') THEN '圣衣制作台'
            WHEN a_typ = 'activity_buy' AND obj2 IN ('item@40426') THEN '黄金魂转盘'
            WHEN a_typ = 'activity_buy' AND obj2 NOT IN ('item@3789', 'item@40185', 'item@3787', 'item@40294', 'item@3904', 'item@40404', 'item@40426', 'item@40431', 'item@40432', 'item@40433', 'item@40434') THEN '其他活动'
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
        WHERE day >= 20201227
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
            WHERE day >= 20201227
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
        SELECT DISTINCT
            mbga_uid AS user_id
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
-- Section: Daily Currency Stock (CUR_STOCK)
--------------------------------------------------------------------------------
SET odps.sql.hive.compatible = TRUE;
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
    -- Data extraction for last 7 days active users
    SELECT
        s1.day,
        s1.user_id,
        s1.diamond
    FROM (
        SELECT
            u1.day,
            u1.user_id,
            u2.diamond,
            ROW_NUMBER() OVER (PARTITION BY u1.day, u1.user_id ORDER BY u2.day DESC) AS rank
        FROM (
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
                WHERE day BETWEEN 20201127 AND 20201227
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
                WHERE day BETWEEN 20201127 AND 20201227
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
                    ROW_NUMBER() OVER (PARTITION BY day, user_id ORDER BY record_time DESC) AS rank
                FROM g10000001.bi_money_list
                WHERE day BETWEEN 20201127 AND 20201227
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
    SELECT
        day,
        user_id,
        CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT) AS zone,
        MAX(level) AS level,
        MAX(vip) AS vip
    FROM g10000001.daily_user_snapshot
    WHERE day >= 20200403
        AND zone <> ''
    GROUP BY
        day,
        user_id,
        CAST(REGEXP_REPLACE(zone, '[\\{\\[\\}\\]\\_a-zA-Z]', '') AS INT)
) p2 ON p1.user_id = p2.user_id AND p1.day = p2.day
GROUP BY p1.day
ORDER BY day;
