WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
EquipLogs AS (
    SELECT 
        "#account_id",
        equip_location AS equip_type,
        CAST(equip_lv AS BIGINT) AS equip_lv, 
        equip_id
    FROM (
        SELECT 
            v."#account_id",
            v.type,
            v.equip[1].config_id,
            v.equip[1].equip_id AS equip_id,
            v.equip[1].role_id,
            v.equip[1].equip_lv AS equip_lv,
            v.equip[1].location AS equip_location,
            ROW_NUMBER() OVER(PARTITION BY v."#account_id", v.equip[1].location ORDER BY v."#event_time" DESC) AS rank
        FROM ta.v_event_13 v
        LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
        WHERE v.${PartDate:date1} 
          AND v."$part_event" = 'equip_dress'
          AND ub."#user_id" IS NULL
    )
    WHERE rank = 1
)
SELECT 
    equip_type AS "道具部位(1-10)",
    AVG(CAST(equip_lv AS DOUBLE)) AS "平均等级",
    APPROX_PERCENTILE(equip_lv, 0.5) AS "等级中位数",
    MAX(equip_lv) AS "最高等级",
    MIN(equip_lv) AS "最低等级",
    SUM(CASE WHEN equip_lv BETWEEN 1 AND 30 THEN 1 ELSE 0 END) AS "1-30级人数",
    SUM(CASE WHEN equip_lv BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS "31-60级人数",
    SUM(CASE WHEN equip_lv BETWEEN 61 AND 90 THEN 1 ELSE 0 END) AS "61-90级人数",
    SUM(CASE WHEN equip_lv >= 91 THEN 1 ELSE 0 END) AS "91级以上人数"
FROM EquipLogs
GROUP BY 1
ORDER BY 1;
