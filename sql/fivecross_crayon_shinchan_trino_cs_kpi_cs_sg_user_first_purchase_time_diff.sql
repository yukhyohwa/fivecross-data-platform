/*
================================================================================
项目：蜡笔小新 - 用户首充距离创角时间分布
描述：统计目标在查询周期内完成首次充值的用户，其首次充值距离创角 (new_role) 的时间分布。
时间区间：0-10min, 10-30min, 30-60min, 60-120min, 120-180min, 180-240min, 240min以上
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 提取目标用户的首次充值时间 (锁定在目标查询周期内首充的用户)
TargetFirstCharge AS (
    SELECT 
        fc."#user_id",
        fc.first_charge_time
    FROM (
        SELECT 
            "#user_id",
            "#event_time" AS first_charge_time,
            "$part_date",
            ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time" ASC) as charge_rank
        FROM ta.v_event_13
        WHERE "$part_event" = 'charge'
          AND (sandbox IS NULL OR sandbox = FALSE)
          AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    ) fc
    LEFT JOIN UserBlacklist ub ON fc."#user_id" = ub."#user_id"
    WHERE fc.charge_rank = 1 
      AND ub."#user_id" IS NULL
      AND ${PartDate:date1} -- 过滤首充日期在目标范围内的用户
),

-- 2. 获取这些用户的创角时间
UserNewRole AS (
    SELECT 
        "#user_id",
        MIN("#event_time") AS new_role_time
    FROM ta.v_event_13
    WHERE "$part_event" = 'new_role'
    GROUP BY 1
),

-- 3. 计算时间差 (分钟)
TimeDiffStats AS (
    SELECT 
        fc."#user_id",
        DATE_DIFF('minute', CAST(nr.new_role_time AS TIMESTAMP), CAST(fc.first_charge_time AS TIMESTAMP)) AS diff_minutes
    FROM TargetFirstCharge fc
    INNER JOIN UserNewRole nr ON fc."#user_id" = nr."#user_id"
)

-- 4. 汇总各个时间区间的人数
SELECT 
    CASE 
        WHEN diff_minutes >= 0 AND diff_minutes <= 10 THEN '01_0-10min'
        WHEN diff_minutes > 10 AND diff_minutes <= 30 THEN '02_10-30min'
        WHEN diff_minutes > 30 AND diff_minutes <= 60 THEN '03_30-60min'
        WHEN diff_minutes > 60 AND diff_minutes <= 120 THEN '04_60-120min'
        WHEN diff_minutes > 120 AND diff_minutes <= 180 THEN '05_120-180min'
        WHEN diff_minutes > 180 AND diff_minutes <= 240 THEN '06_180-240min'
        WHEN diff_minutes > 240 THEN '07_240min以上'
        ELSE '08_异常数据(如时间错乱)'
    END AS "时间区间",
    COUNT(DISTINCT "#user_id") AS "人数"
FROM TimeDiffStats
GROUP BY 1
ORDER BY 1 ASC;
