WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
flattened_data AS (
    SELECT 
        v."#account_id",
        v."#event_time",
        v."$part_date",
        CAST(v.role_lev AS BIGINT) AS role_level
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'daily_role_snapshot'
      AND ub."#user_id" IS NULL
),
latest_state AS (
    -- 取每个账号下，当天的最后状态
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY "#account_id", "$part_date" ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
)
-- 计算平均值、中位数及各区间人数
SELECT 
    "$part_date" AS "日期",
    AVG(CAST(role_level AS DOUBLE)) AS "平均等级",
    APPROX_PERCENTILE(role_level, 0.5) AS "等级中位数",
    MAX(role_level) AS "最高等级",
    MIN(role_level) AS "最低等级",
    SUM(CASE WHEN role_level BETWEEN 1 AND 30 THEN 1 ELSE 0 END) AS "1-30级人数",
    SUM(CASE WHEN role_level BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS "31-60级人数",
    SUM(CASE WHEN role_level BETWEEN 61 AND 90 THEN 1 ELSE 0 END) AS "61-90级人数",
    SUM(CASE WHEN role_level >= 91 THEN 1 ELSE 0 END) AS "91级以上人数"
FROM latest_state
WHERE rn = 1
GROUP BY 1
ORDER BY 1;
