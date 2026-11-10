/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 战斗内 Ping 性能统计 — 按地区与服务器划分
Tag     : ja_tc  cbt2
Note    : 使用 user_result_cluster_16 中的 fixed_country 标签进行地区划分
Environment: Trino (TA) — v_event_16  表编号 16
================================================================================
*/

WITH UserProfile AS (
    SELECT
        "#varchar_id"                                                            AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END)        AS fixed_country
    FROM user_result_cluster_16
    WHERE cluster_name = 'fixed_country'
    GROUP BY 1
),

ArenaPingRaw AS (
    SELECT 
        *,
        COALESCE(json_extract_scalar(fc_sdk_common, '$.lcx_id'), sdkcommon.lcx_id) AS lcx_id clean_lcxid
    FROM ta.v_event_16
    WHERE "$part_event" = 'arena_ping'
      AND ${PartDate:date1}
)

SELECT
    CASE
        WHEN up.fixed_country IN ('香港', '台湾') THEN up.fixed_country
        WHEN up.fixed_country = '中国' THEN '中国大陆'
        ELSE '其他地区'
    END AS "地区"   ,                                                      AS "地区",
    
    CASE 
        WHEN s1.server_id IN (4001, 4002) THEN '香港战斗服'
        WHEN s1.server_id IN (4003, 4004) THEN '台湾战斗服'
        ELSE '其他服务器'
    END AS "战斗服",
    
    COUNT(s1."#uuid") AS "总次数",
    
    ROUND(AVG(CAST(s1.ping AS DOUBLE)), 2) AS "ping均值",
    
    -- 次数均值
    ROUND(AVG(CAST(s1.ping_count30 AS DOUBLE)), 2) AS "ping0-30次数均值",
    ROUND(AVG(CAST(s1.ping_count60 AS DOUBLE)), 2) AS "ping30-60次数均值",
    ROUND(AVG(CAST(s1.ping_count90 AS DOUBLE)), 2) AS "ping60-90次数均值",
    ROUND(AVG(CAST(s1.ping_count120 AS DOUBLE)), 2) AS "ping90-120次数均值",
    ROUND(AVG(CAST(s1.ping_count460 AS DOUBLE)), 2) AS "ping120-460次数均值",
    
    -- 占比均值（基于累加后的百分比）
    ROUND(SUM(CAST(s1.ping_count30 AS DOUBLE)) / NULLIF(SUM(CAST(s1.ping_count AS DOUBLE)), 0), 4) AS "ping0-30占比均值",
    ROUND(SUM(CAST(s1.ping_count60 AS DOUBLE)) / NULLIF(SUM(CAST(s1.ping_count AS DOUBLE)), 0), 4) AS "ping30-60占比均值",
    ROUND(SUM(CAST(s1.ping_count90 AS DOUBLE)) / NULLIF(SUM(CAST(s1.ping_count AS DOUBLE)), 0), 4) AS "ping60-90占比均值",
    ROUND(SUM(CAST(s1.ping_count120 AS DOUBLE)) / NULLIF(SUM(CAST(s1.ping_count AS DOUBLE)), 0), 4) AS "ping90-120占比均值",
    ROUND(SUM(CAST(s1.ping_count460 AS DOUBLE)) / NULLIF(SUM(CAST(s1.ping_count AS DOUBLE)), 0), 4) AS "ping120-460占比均值"

FROM ArenaPingRaw s1
LEFT JOIN UserProfile up ON s1.clean_lcxid = up.lcx_id
GROUP BY 1, 2
ORDER BY 1, 2;
