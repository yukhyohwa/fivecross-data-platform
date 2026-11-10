WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
flattened_data AS (
    SELECT 
        v."#account_id",
        v."#event_time",
        v.mount_id,              
        CAST(v.mount_lev AS BIGINT) AS mount_level,
        CAST(v.star AS BIGINT) AS mount_star
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'mount_levup'
      AND ub."#user_id" IS NULL
),
latest_state AS (
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY "#account_id", mount_id ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
)
SELECT 
    mount_id AS "坐骑ID",
    COUNT(DISTINCT "#account_id") AS "拥有人数",
    AVG(CAST(mount_level AS DOUBLE)) AS "平均等级",
    AVG(CAST(mount_star AS DOUBLE)) AS "平均星级"
FROM latest_state
WHERE rn = 1
GROUP BY 1
ORDER BY 1;
