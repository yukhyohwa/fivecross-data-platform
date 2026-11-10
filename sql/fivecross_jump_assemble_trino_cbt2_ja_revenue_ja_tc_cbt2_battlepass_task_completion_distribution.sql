/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 通行证任务 (Battlepass Task) 完成率分析
Cohort  : 4/15 注册新用户 (2026-04-15 注册)
Window  : 2026-04-15 ~ 2026-04-20
Event   : 
  - 活跃基数：LOGIN_SUCCESS (#account_id 作为用户标识)
  - 任务行为：battlepass_task (taskType=4)
Metrics : 
  - 统计每日活跃的 4/15 用户中，各个 taskId 的完成人数、完成次数及其活跃完成率。
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 4/15 注册的新用户
--------------------------------------------------------------------------------
NewUsers_0415 AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND t1.tag_value    = '2026-04-15'
      AND ub.lcx_id IS NULL
),

--------------------------------------------------------------------------------
-- 3. 计算 4/15 用户的每日活跃基数 (DAU)
--    使用 LOGIN_SUCCESS 事件，ID 为 #account_id
--------------------------------------------------------------------------------
CohortDAU AS (
    SELECT 
        v."$part_date" AS log_date,
        COUNT(DISTINCT v."#account_id") AS dau
    FROM ta.v_event_16 v
    INNER JOIN NewUsers_0415 nu ON v."#account_id" = nu.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-20'
      AND v."$part_event" = 'LOGIN_SUCCESS'
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 4. 通行证任务日志 (taskType=4)
--------------------------------------------------------------------------------
BPTaskLogs AS (
    SELECT
        v."$part_date" AS log_date,
        v.taskId,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id
    FROM ta.v_event_16 v
    INNER JOIN NewUsers_0415 nu 
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-20'
      AND v."$part_event" = 'battlepass_task'
      AND v.taskType IN (4)
),

--------------------------------------------------------------------------------
-- 5. 汇总完成人数与完成率
--------------------------------------------------------------------------------
TaskStats AS (
    SELECT
        log_date,
        taskId,
        COUNT(DISTINCT lcx_id) AS complete_users,
        COUNT(*)               AS total_completions
    FROM BPTaskLogs
    GROUP BY 1, 2
)

--------------------------------------------------------------------------------
-- 6. 最终输出
--------------------------------------------------------------------------------
SELECT
    ts.log_date                                             AS "日期",
    ts.taskId                                               AS "任务ID (taskId)",
    ts.complete_users                                       AS "完成人数",
    ts.total_completions                                    AS "完成次数",
    dau.dau                                                 AS "当日活跃基数(DAU)",
    ROUND(CAST(ts.complete_users AS DOUBLE) 
        / NULLIF(dau.dau, 0) * 100, 2)                     AS "活跃完成率(%)"
FROM TaskStats ts
LEFT JOIN CohortDAU dau ON ts.log_date = dau.log_date
ORDER BY 1 ASC, 6 DESC;
