WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
flattened_data AS (
    SELECT 
        v."#account_id",
        v."#event_time",
        v.id AS collection_id,   
        v.name AS collection_name, 
        CAST(v.level_after AS BIGINT) AS collection_level
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'remain_mosaic_up'
      AND ub."#user_id" IS NULL
),
latest_state AS (
    SELECT 
        *,
        ROW_NUMBER() OVER(PARTITION BY "#account_id", collection_id ORDER BY "#event_time" DESC) AS rn
    FROM flattened_data
)
SELECT 
    collection_id AS "ID",
    collection_name AS "名称",
    COUNT(DISTINCT "#account_id") AS "拥有人数",
    AVG(CAST(collection_level AS DOUBLE)) AS "平均等级",
    APPROX_PERCENTILE(collection_level, 0.5) AS "等级中位数",
    MAX(collection_level) AS "最高等级",
    MIN(collection_level) AS "最低等级",
    SUM(CASE WHEN collection_level BETWEEN 1 AND 5 THEN 1 ELSE 0 END) AS "1-5级人数",
    SUM(CASE WHEN collection_level BETWEEN 6 AND 10 THEN 1 ELSE 0 END) AS "6-10级人数",
    SUM(CASE WHEN collection_level BETWEEN 11 AND 15 THEN 1 ELSE 0 END) AS "11-15级人数",
    SUM(CASE WHEN collection_level BETWEEN 16 AND 20 THEN 1 ELSE 0 END) AS "16-20级人数",
    SUM(CASE WHEN collection_level >= 21 THEN 1 ELSE 0 END) AS "21级以上人数"
FROM latest_state
WHERE rn = 1
GROUP BY 1, 2
ORDER BY 1;
