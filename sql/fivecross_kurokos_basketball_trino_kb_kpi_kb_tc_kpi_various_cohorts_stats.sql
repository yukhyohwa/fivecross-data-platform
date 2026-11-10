/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese / TW)
Description: 
    1. 各時間段的排位賽比賽的總場次，以及人均场次，周期内活跃人数
    2. 各時間段，各段位的等待時間均值、參與人數及玩家組成比例 (回歸、大課、活躍)
================================================================================
*/

/*
================================================================================
Query 1: 各時間段的排位賽比賽的總場次，以及人均场次，周期内活跃人数
================================================================================
*/
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" 
    FROM user_result_cluster_10 
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),
BattleData AS (
    SELECT 
        CASE 
            WHEN "$part_date" BETWEEN '2026-02-05' AND '2026-02-11' THEN '0205_0211'
            WHEN "$part_date" BETWEEN '2026-02-12' AND '2026-02-18' THEN '0212_0218'
            WHEN "$part_date" BETWEEN '2026-02-19' AND '2026-02-25' THEN '0219_0225'
            WHEN "$part_date" BETWEEN '2026-04-15' AND '2026-04-21' THEN '0415_0421'
            WHEN "$part_date" BETWEEN '2026-04-22' AND '2026-04-28' THEN '0422_0428'
            WHEN "$part_date" BETWEEN '2026-04-29' AND '2026-05-05' THEN '0429_0505'
            WHEN "$part_date" BETWEEN '2026-05-06' AND '2026-05-12' THEN '0506_0512'
        END AS period_name,
        "#user_id",
        pvp_session AS battle_id
    FROM ta.v_event_10 
    WHERE "$part_event" = 'battle_result' AND pvp_type = 502
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
      AND (
          "$part_date" BETWEEN '2026-02-05' AND '2026-02-25'
          OR "$part_date" BETWEEN '2026-04-15' AND '2026-05-12'
      )
)
SELECT 
    period_name AS "時間段",
    COUNT(DISTINCT battle_id) AS "總場次",
    COUNT(DISTINCT "#user_id") AS "活躍人數",
    CAST(COUNT(1) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#user_id"), 0) AS "人均場次"
FROM BattleData
GROUP BY 1
ORDER BY 1;


/*
================================================================================
Query 2: 各時間段，各段位的等待時間均值、參與人數及玩家組成比例
================================================================================
*/
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" 
    FROM user_result_cluster_10 
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),
PeriodMapping AS (
    SELECT '0205_0211' AS period_name, '2026-02-05' AS start_date UNION ALL
    SELECT '0212_0218', '2026-02-12' UNION ALL
    SELECT '0219_0225', '2026-02-19' UNION ALL
    SELECT '0415_0421', '2026-04-15' UNION ALL
    SELECT '0422_0428', '2026-04-22' UNION ALL
    SELECT '0429_0505', '2026-04-29' UNION ALL
    SELECT '0506_0512', '2026-05-06'
),
BattleData AS (
    SELECT 
        CASE 
            WHEN "$part_date" BETWEEN '2026-02-05' AND '2026-02-11' THEN '0205_0211'
            WHEN "$part_date" BETWEEN '2026-02-12' AND '2026-02-18' THEN '0212_0218'
            WHEN "$part_date" BETWEEN '2026-02-19' AND '2026-02-25' THEN '0219_0225'
            WHEN "$part_date" BETWEEN '2026-04-15' AND '2026-04-21' THEN '0415_0421'
            WHEN "$part_date" BETWEEN '2026-04-22' AND '2026-04-28' THEN '0422_0428'
            WHEN "$part_date" BETWEEN '2026-04-29' AND '2026-05-05' THEN '0429_0505'
            WHEN "$part_date" BETWEEN '2026-05-06' AND '2026-05-12' THEN '0506_0512'
        END AS period_name,
        "#user_id",
        pvp_session AS battle_id,
        CAST(matching_time AS DOUBLE) AS matching_time,
        rankbefore
    FROM ta.v_event_10 
    WHERE "$part_event" = 'battle_result' AND pvp_type = 502
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
      AND (
          "$part_date" BETWEEN '2026-02-05' AND '2026-02-25'
          OR "$part_date" BETWEEN '2026-04-15' AND '2026-05-12'
      )
),
UserPay AS (
    SELECT 
        c."#user_id",
        SUM(c.pay_amount / COALESCE(ex.exchange, 1)) AS lifetime_usd
    FROM ta.v_event_10 c
    LEFT JOIN ta_dim.ta_exchange ex ON c."$part_date" = ex.ex_date AND c.pay_currency = ex.currency
    WHERE c."$part_event" = 'charge'
      AND (c.sandbox = false OR c.sandbox IS NULL)
      AND (c.order_id NOT IN ('11') OR c.order_id IS NULL)
    GROUP BY 1
),
Login30D AS (
    SELECT 
        u.period_name,
        u."#user_id",
        COUNT(DISTINCT l."$part_date") AS login_days_30d_prior
    FROM (SELECT DISTINCT "#user_id", period_name FROM BattleData) u
    JOIN PeriodMapping p ON u.period_name = p.period_name
    LEFT JOIN ta.v_event_10 l ON l."#user_id" = u."#user_id" 
        AND l."$part_event" = 'login' 
        AND CAST(l."$part_date" AS DATE) BETWEEN DATE_ADD('day', -30, CAST(p.start_date AS DATE)) AND DATE_ADD('day', -1, CAST(p.start_date AS DATE))
    GROUP BY 1, 2
),
PeriodRankAgg AS (
    SELECT 
        b.period_name,
        b.rankbefore,
        AVG(b.matching_time) AS avg_wait_time,
        COUNT(DISTINCT b."#user_id") AS total_participants,
        
        -- Returning players (0 days of login in the 30 days prior)
        COUNT(DISTINCT CASE WHEN COALESCE(upl.login_days_30d_prior, 0) = 0 THEN b."#user_id" END) AS returning_players,
        
        -- High active players (30 days of login in the 30 days prior)
        COUNT(DISTINCT CASE WHEN upl.login_days_30d_prior = 30 THEN b."#user_id" END) AS high_active_players,
        
        -- Whale players (> 5000 USD cumulative charge)
        COUNT(DISTINCT CASE WHEN up.lifetime_usd > 5000 THEN b."#user_id" END) AS whale_players
        
    FROM BattleData b
    LEFT JOIN Login30D upl ON b.period_name = upl.period_name AND b."#user_id" = upl."#user_id"
    LEFT JOIN UserPay up ON b."#user_id" = up."#user_id"
    GROUP BY 1, 2
)
SELECT 
    period_name AS "時間段",
    CAST(rankbefore AS VARCHAR) AS "段位",
    total_participants AS "總參與人數",
    ROUND(avg_wait_time, 2) AS "等待時間均值",
    CAST(ROUND(CAST(returning_players AS DOUBLE) / NULLIF(total_participants, 0) * 100, 2) AS VARCHAR) || '%' AS "回歸玩家比例",
    CAST(ROUND(CAST(whale_players AS DOUBLE) / NULLIF(total_participants, 0) * 100, 2) AS VARCHAR) || '%' AS "大課玩家比例",
    CAST(ROUND(CAST(high_active_players AS DOUBLE) / NULLIF(total_participants, 0) * 100, 2) AS VARCHAR) || '%' AS "十分活躍玩家比例"
FROM PeriodRankAgg
ORDER BY period_name, rankbefore;
