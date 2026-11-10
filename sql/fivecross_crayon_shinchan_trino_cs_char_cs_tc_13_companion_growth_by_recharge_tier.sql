/* 伙伴拥有与等级矩阵：累计有效充值按 USD 划档；快照按业务归属日期（快照日-1）输出。 */
WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),
AccountToUser AS (
    SELECT "#account_id" AS account_id, MAX("#user_id") AS user_id
    FROM ta.v_event_18
    WHERE "$part_event" IN ('login', 'new_role') AND "#account_id" IS NOT NULL AND "#user_id" IS NOT NULL
    GROUP BY 1
),
ValidAccounts AS (
    SELECT a.account_id
    FROM AccountToUser a
    LEFT JOIN UserBlacklist ub ON a.user_id = ub.user_id
    WHERE ub.user_id IS NULL
),
AccountRevenue AS (
    SELECT v."#account_id" AS account_id,
           SUM(CAST(v.pay_amount AS DOUBLE) / COALESCE(x.exchange, 1)) AS total_revenue_usd
    FROM ta.v_event_18 v
    INNER JOIN ValidAccounts va ON v."#account_id" = va.account_id
    LEFT JOIN ta_dim.ta_exchange x ON v."$part_date" = x.ex_date AND v.pay_currency = x.currency
    WHERE v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
    GROUP BY 1
),
AccountsWithTier AS (
    SELECT va.account_id,
        CASE WHEN COALESCE(r.total_revenue_usd, 0) = 0 THEN '0.免费用户'
             WHEN r.total_revenue_usd <= 10 THEN 'a.(0,10]'
             WHEN r.total_revenue_usd <= 50 THEN 'b.(10,50]'
             WHEN r.total_revenue_usd <= 100 THEN 'c.(50,100]'
             WHEN r.total_revenue_usd <= 300 THEN 'd.(100,300]'
             ELSE 'e.(300,∞]' END AS recharge_tier
    FROM ValidAccounts va LEFT JOIN AccountRevenue r ON va.account_id = r.account_id
),
SnapshotCompanions AS (
    SELECT v."$part_date" AS snapshot_date, v.lid AS role_id, v."#event_time" AS event_time,
           a.recharge_tier, t.pet_id AS companion_id, TRY_CAST(t.level AS BIGINT) AS companion_level
    FROM ta.v_event_18 v
    INNER JOIN AccountsWithTier a ON v.lid = a.account_id
    CROSS JOIN UNNEST(v.friend) AS t
    WHERE v."$part_date" BETWEEN '{{SNAPSHOT_START_DATE}}' AND '{{SNAPSHOT_END_DATE}}'
      AND v."$part_event" = 'daily_role_snapshot'
),
LatestState AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY snapshot_date, role_id, companion_id ORDER BY event_time DESC) AS rn
    FROM SnapshotCompanions
),
QualityRows AS (
    SELECT
        s.snapshot_date,
        s.recharge_tier,
        s.role_id,
        s.companion_id,
        s.companion_level,
        COALESCE(d."friend.role_id@quality_name", '未知品质') AS quality_name
    FROM LatestState s
    LEFT JOIN ta_dim.dim_18_0_53443 d
      ON CAST(s.companion_id AS INTEGER) = CAST(d."friend.role_id@friend_id" AS INTEGER)
    WHERE s.rn = 1
      AND s.companion_level IS NOT NULL
)
SELECT
    CAST(DATE_ADD('day', -1, CAST(snapshot_date AS DATE)) AS VARCHAR) AS "业务归属日期",
    recharge_tier AS "付费档位",
    quality_name AS "伙伴品质",
    COUNT(DISTINCT role_id) AS "拥有人数",
    COUNT(DISTINCT companion_id) AS "伙伴种类数",
    ROUND(CAST(COUNT(*) AS DOUBLE) / NULLIF(COUNT(DISTINCT role_id), 0), 2) AS "人均持有数",
    ROUND(AVG(CAST(companion_level AS DOUBLE)), 2) AS "平均等级",
    APPROX_PERCENTILE(companion_level, 0.5) AS "等级中位数",
    MAX(companion_level) AS "最高等级"
FROM QualityRows
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 2, 3;
