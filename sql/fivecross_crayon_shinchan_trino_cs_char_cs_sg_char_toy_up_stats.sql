WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
flattened_data AS (
    SELECT 
        v."#account_id",
        v."#event_time",
        v.unique_id AS toy_id,   
        v.name AS toy_name, 
        CAST(v.quality AS BIGINT) AS toy_quality,
        CAST(v.level_after AS BIGINT) AS toy_level
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'toy_up'
      AND ub."#user_id" IS NULL
),
latest_state AS (
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY "#account_id", toy_id ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
)
SELECT 
    toy_id AS "玩具ID",
    toy_name AS "玩具名称",
    COUNT(DISTINCT "#account_id") AS "拥有人数",
    AVG(CAST(toy_quality AS DOUBLE)) AS "平均品质",
    AVG(CAST(toy_level AS DOUBLE)) AS "平均等级"
FROM latest_state
WHERE rn = 1
GROUP BY 1, 2
ORDER BY 1;
