/*
================================================================================
项目：蜡笔小新 - 转盘产出道具明细统计
描述：统计转盘活动 (prizewheel) 中产出的各类道具分布。
指标：日期、道具ID、道具名称、产出总量、获得人数
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
)

SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        ELSE '已合并'
    END AS "时间维度",
    t.id AS "道具ID",
    t.name AS "道具名称",
    SUM(CAST(t.diff AS BIGINT)) AS "产出总量",
    COUNT(DISTINCT v."#account_id") AS "获得人数"
FROM ta.v_event_13 v
LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
CROSS JOIN UNNEST(v.a_rst) AS t--(id, name, "before", diff, "after")
WHERE v."$part_event" = 'prizewheel'
  AND v.${PartDate:date1}
  AND ub."#user_id" IS NULL
  AND CAST(t.diff AS BIGINT) > 0 -- 仅统计产出的道具
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 4 DESC;
