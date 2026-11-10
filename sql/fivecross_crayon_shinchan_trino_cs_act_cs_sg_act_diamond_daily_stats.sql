/*
================================================================================
项目：蜡笔小新 - 红钻 (10009) 每日产出与消耗统计
时间：自适应 ${PartDate:date1}
指标：产出量/人数/人均、消耗量/人数/人均
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

RawData AS (
    SELECT 
        v."$part_date" AS part_date,
        v."#account_id" AS user_id,
        CAST(t.diff AS BIGINT) AS amount,
        -- 根据 before 和 after 的大小关系判断类型
        CASE 
            WHEN CAST(t.before AS BIGINT) > CAST(t.after AS BIGINT) THEN '消耗' 
            ELSE '产出' 
        END AS type
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    CROSS JOIN UNNEST(v.a_rst) AS t
    WHERE v.${PartDate:date1} 
      AND CAST(t.id AS BIGINT) = 10009
      AND ub."#user_id" IS NULL
)

SELECT 
    part_date AS "日期",
    
    -- 产出统计
    SUM(CASE WHEN type = '产出' THEN amount ELSE 0 END) AS "产出量",
    COUNT(DISTINCT CASE WHEN type = '产出' THEN user_id END) AS "产出人数",
    ROUND(CAST(SUM(CASE WHEN type = '产出' THEN amount ELSE 0 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT CASE WHEN type = '产出' THEN user_id END), 0),0) AS "人均产出",
    
    -- 消耗统计
    SUM(CASE WHEN type = '消耗' THEN amount ELSE 0 END) AS "消耗量",
    COUNT(DISTINCT CASE WHEN type = '消耗' THEN user_id END) AS "消耗人数",
    ROUND(CAST(SUM(CASE WHEN type = '消耗' THEN amount ELSE 0 END) AS DOUBLE) / NULLIF(COUNT(DISTINCT CASE WHEN type = '消耗' THEN user_id END), 0),0) AS "人均消耗"

FROM RawData
GROUP BY 1
ORDER BY 1 DESC;
