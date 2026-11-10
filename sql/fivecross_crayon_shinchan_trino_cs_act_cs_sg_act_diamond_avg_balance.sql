/*
================================================================================
项目：蜡笔小新 - 红钻 (10009) 每日平均持仓统计
时间：自适应 ${PartDate:date1}
逻辑：取每日每个用户最后一次变动后的余额 (after)，计算全服平均值
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),

FlattenedData AS (
    SELECT 
        v."$part_date" AS part_date,
        v."#account_id" AS user_id,
        v."#event_time" AS event_time,
        CAST(t.after AS BIGINT) AS balance
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v. "#user_id" = ub. "#user_id"
    CROSS JOIN UNNEST(v.a_rst) AS t
    WHERE ${PartDate:date1} 
      AND CAST(t.id AS BIGINT) = 10009 -- 红钻 ID
      AND ub. "#user_id" IS NULL
),

LatestState AS (
    -- 取每个账号在每日的最后状态
    SELECT 
        part_date,
        user_id,
        balance,
        ROW_NUMBER() OVER(PARTITION BY part_date, user_id ORDER BY event_time DESC) AS rn
    FROM FlattenedData
)

SELECT 
    part_date AS "日期",
    AVG(balance) AS "平均红钻持仓"
FROM LatestState
WHERE rn = 1
GROUP BY 1
ORDER BY 1 DESC;
