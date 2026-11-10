/*
角色等级分布。daily_role_snapshot 在次日凌晨落库，业务归属日期按快照日期减 1 天输出。
请在数数后台选择“快照落库日期”；若要看 7/29 的状态，通常需包含 7/30 快照。
*/
WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),
SnapshotRows AS (
    SELECT
        v.lid AS account_id,
        v."#event_time" AS event_time,
        v."$part_date" AS snapshot_date,
        TRY_CAST(v.role_lev AS BIGINT) AS role_level
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub.user_id
    WHERE v."$part_date" BETWEEN '{{SNAPSHOT_START_DATE}}' AND '{{SNAPSHOT_END_DATE}}'
      AND v."$part_event" = 'daily_role_snapshot'
      AND ub.user_id IS NULL
      AND v.lid IS NOT NULL
),
LatestSnapshot AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY account_id, snapshot_date ORDER BY event_time DESC) AS rn
    FROM SnapshotRows
)
SELECT
    CAST(DATE_ADD('day', -1, CAST(snapshot_date AS DATE)) AS VARCHAR) AS "业务归属日期",
    snapshot_date AS "快照日期",
    ROUND(AVG(CAST(role_level AS DOUBLE)), 0) AS "平均等级",
    APPROX_PERCENTILE(role_level, 0.5) AS "等级中位数",
    MAX(role_level) AS "最高等级",
    MIN(role_level) AS "最低等级",
    SUM(CASE WHEN role_level BETWEEN 1 AND 10 THEN 1 ELSE 0 END) AS "1-10级人数",
    SUM(CASE WHEN role_level BETWEEN 11 AND 20 THEN 1 ELSE 0 END) AS "11-20级人数",
    SUM(CASE WHEN role_level BETWEEN 21 AND 30 THEN 1 ELSE 0 END) AS "21-30级人数",
    SUM(CASE WHEN role_level BETWEEN 31 AND 40 THEN 1 ELSE 0 END) AS "31-40级人数",
    SUM(CASE WHEN role_level BETWEEN 41 AND 50 THEN 1 ELSE 0 END) AS "41-50级人数",
    SUM(CASE WHEN role_level BETWEEN 51 AND 60 THEN 1 ELSE 0 END) AS "51-60级人数",
    SUM(CASE WHEN role_level BETWEEN 61 AND 70 THEN 1 ELSE 0 END) AS "61-70级人数",
    SUM(CASE WHEN role_level BETWEEN 71 AND 80 THEN 1 ELSE 0 END) AS "71-80级人数",
    SUM(CASE WHEN role_level BETWEEN 81 AND 90 THEN 1 ELSE 0 END) AS "81-90级人数",
    SUM(CASE WHEN role_level >= 91 THEN 1 ELSE 0 END) AS "91级以上人数"
FROM LatestSnapshot
WHERE rn = 1 AND role_level IS NOT NULL
GROUP BY 1, 2
ORDER BY "业务归属日期";
