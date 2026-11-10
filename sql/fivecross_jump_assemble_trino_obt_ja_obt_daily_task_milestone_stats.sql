/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 每日任务完成进度 (Daily Task Milestone) 分布分析
Cohort  : 选定时间范围内的全部活跃用户 (DAU)
Window  : 动态参数 ${PartDate:date1}
Event   : 
  - 活跃基数：LOGIN_SUCCESS (#account_id 作为用户标识)
  - 任务进度：activitytask_reward (活跃度奖励领取)
Metrics : 
  - 分析指定期间每日活跃用户在当天的任务完成分布。
  - 占比分母为【当日活跃用户数 (DAU)】。
================================================================================
*/

WITH
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

ActiveUsers AS (
    SELECT 
        v."$part_date" AS log_date,
        v."#account_id" AS lcx_id
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub.lcx_id
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'LOGIN_SUCCESS'
      AND ub.lcx_id IS NULL
    GROUP BY 1, 2
),

CohortDAU AS (
    SELECT 
        log_date,
        COUNT(DISTINCT lcx_id) AS dau
    FROM ActiveUsers
    GROUP BY 1
),

TaskLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) AS lcx_id,
        MAX(CAST(v.indexid AS INTEGER)) AS max_index
    FROM ta.v_event_23 v
    INNER JOIN ActiveUsers au 
        ON v."$part_date" = au.log_date 
        AND COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id) = au.lcx_id
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'activitytask_reward'
    GROUP BY 1, 2
),

UserMilestones AS (
    SELECT
        log_date,
        lcx_id,
        CASE 
            WHEN max_index >= 200 THEN '200'
            WHEN max_index >= 150 THEN '150'
            WHEN max_index >= 100 THEN '100'
            WHEN max_index >= 50  THEN '50'
            WHEN max_index >= 10  THEN '10'
            ELSE '0-9 (未达首档)'
        END AS daily_milestone
    FROM TaskLogs
)

SELECT
    um.log_date AS "日期",
    '全部活跃用户' AS "用户群体",
    MAX(dau.dau) AS "当日活跃人数 (DAU)",
    um.daily_milestone AS "每日任务最高档位",
    COUNT(DISTINCT um.lcx_id) AS "达成人数",
    ROUND(CAST(COUNT(DISTINCT um.lcx_id) AS DOUBLE) / NULLIF(MAX(dau.dau), 0) * 100, 2) AS "活跃完成率(%)"
FROM UserMilestones um
LEFT JOIN CohortDAU dau ON um.log_date = dau.log_date
GROUP BY 1, 2, 4
ORDER BY 1 ASC, 
    CASE 
        WHEN daily_milestone = '200' THEN 1
        WHEN daily_milestone = '150' THEN 2
        WHEN daily_milestone = '100' THEN 3
        WHEN daily_milestone = '50' THEN 4
        WHEN daily_milestone = '10' THEN 5
        ELSE 6 
    END ASC;
