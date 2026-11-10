/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese)
Description: Analysis of Insignia Gacha (徽章扭蛋) usage and triggered player recharge.
Author: Antigravity
Created: 2026-02-09
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 1: Recharge Summary (Total Recharge USD per User in the period)
--------------------------------------------------------------------------------
UserRevenue AS (
    SELECT 
        gid,
        "#user_id" AS user_id,
        SUM(CASE 
            WHEN (
                (s1."$part_event" = 'charge' AND s1.pay_currency <> 'kuroko_pay' AND (s1.sandbox = false OR s1.sandbox IS NULL))
                OR (s1."$part_event" IN ('srcoin_buy', 'scroin_buy'))
            )
            THEN s1.pay_amount / COALESCE(ex.exchange, 1)
            ELSE 0 
        END) AS total_recharge_usd
    FROM ta.v_event_10 s1
    LEFT JOIN ta_dim.ta_exchange ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_date" BETWEEN '2026-02-05' AND '2026-02-09'
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- Section 2: Gacha Pull Events (Filtered by Insignia Ticket)
--------------------------------------------------------------------------------
GachaActivity AS (
    SELECT 
        "#user_id" AS user_id,
        "$part_date" AS part_date,
        "#event_time" AS event_time,
        CAST(id AS BIGINT) AS ticket_id,
        ABS(CAST(diff AS BIGINT)) AS consumption_count,
        -- Resulting items gained in the same event transaction
        ARRAY_AGG(CAST(id AS BIGINT)) FILTER (WHERE CAST(diff AS BIGINT) > 0) AS items_gained
    FROM ta.v_event_10
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE CAST(id AS BIGINT) = 30002704 -- 徽章扭蛋券
        AND CAST(diff AS BIGINT) < 0
        AND "$part_date" BETWEEN '2026-02-05' AND '2026-02-09'
    GROUP BY 
        1, 2, 3, 4, 5
),

--------------------------------------------------------------------------------
-- Section 3: Insignia Gacha Analysis Aggregation
--------------------------------------------------------------------------------
InsigniaStats AS (
    SELECT
        '徽章扭蛋' AS "活動",
        '2026-02-05 09:00 ~ 2026-02-08 23:59' AS "時間",
        COUNT(DISTINCT a.user_id) AS "觸發玩家數(不重複)",
        SUM(a.consumption_count) AS "扭蛋總抽取次數",
        SUM(CARDINALITY(a.items_gained)) AS "徽章產出總數"
    FROM GachaActivity a
    WHERE a.event_time BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-08 23:59:59'
),

--------------------------------------------------------------------------------
-- Section 4: VIP Tag Mapping
--------------------------------------------------------------------------------
VipTags AS (
    SELECT 
        "#user_id" AS user_id,
        ARBITRARY(IF(cluster_name = 'vip', tag_value, NULL)) AS vip_label
    FROM user_result_cluster_10 
    WHERE cluster_name = 'vip'
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- Section 5: Insignia Trigger User Detail (GID, VIP, & Recharge)
--------------------------------------------------------------------------------
InsigniaUserDetail AS (
    SELECT DISTINCT
        u.gid,
        v.vip_label,
        u.total_recharge_usd AS "至今為止的儲值金額(USD)"
    FROM GachaActivity a
    JOIN UserRevenue u ON a.user_id = u.user_id
    LEFT JOIN VipTags v ON u.user_id = v.user_id
    WHERE a.event_time BETWEEN TIMESTAMP '2026-02-05 09:00:00' AND TIMESTAMP '2026-02-08 23:59:59'
),

--------------------------------------------------------------------------------
-- Section 6: VIP Distribution Summary
--------------------------------------------------------------------------------
VipInsigniaStats AS (
    SELECT 
        COALESCE(vip_label, '非VIP/未知') AS "VIP標籤",
        COUNT(DISTINCT gid) AS "觸發人數"
    FROM InsigniaUserDetail
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- Final Outputs
--------------------------------------------------------------------------------

-- 1. 徽章扭蛋總體統計
SELECT * FROM InsigniaStats;

-- 2. 各 VIP 標籤觸發人數統計
SELECT * FROM VipInsigniaStats;

-- 3. 觸發玩家明細 (含 VIP 標籤 & 儲值金額)
SELECT * FROM InsigniaUserDetail;
