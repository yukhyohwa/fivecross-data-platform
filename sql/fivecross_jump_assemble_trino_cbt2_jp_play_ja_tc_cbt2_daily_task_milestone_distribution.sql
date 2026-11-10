/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 每日任务完成进度 (Daily Task MileStone) 分布分析
Cohort  : 4/15 注册新用户 (2026-04-15 注册)
Window  : 2026-04-15 ~ 2026-04-20
Event   : 
  - 活跃基数：LOGIN_SUCCESS (#account_id 作为用户标识)
  - 任务进度：activitytask_reward (活跃度奖励领取)
Metrics : 
  - 分析 4/15 新用户在随后几天的任务完成分布。
  - 占比分母为【当日该群体活跃用户数 (DAU)】。
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
-- 4. 活跃度奖励日志 (4/15 - 4/20)
--------------------------------------------------------------------------------
TaskLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        MAX(CAST(v.indexid AS INTEGER)) AS max_index
    FROM ta.v_event_16 v
    INNER JOIN NewUsers_0415 nu 
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-15' AND '2026-04-20'
      AND v."$part_event" = 'activitytask_reward'
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 5. 档位划分
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- 6. 最终聚合输出
--------------------------------------------------------------------------------
SELECT
    um.log_date AS "日期",
    '4/15 注册新用户' AS "用户群体",
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
