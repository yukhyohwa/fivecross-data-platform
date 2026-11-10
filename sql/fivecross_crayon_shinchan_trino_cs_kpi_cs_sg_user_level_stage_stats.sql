/*
================================================================================
项目：蜡笔小新 - 每日用户最终等级、关卡与留存时间统计
描述：统计用户在指定日期内的最终等级、最终关卡（取当期最大值），并计算达到该等级时的平均距离创角时间。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),

-- 1. 获取用户的创角时间
UserNewRole AS (
    SELECT 
        "#user_id",
        MIN("#event_time") AS new_role_time
    FROM ta.v_event_13
    WHERE "$part_event" = 'new_role'
    GROUP BY 1
),

-- 2. 提取用户在指定时间范围内的最终状态
-- （正如您所说，等级和关卡都是只增不降的，直接对所有事件取 MAX 即可，无需局限于特定的卡牌升级事件）
UserState AS (
    SELECT 
        v."#user_id",
        MAX(CAST(v.role_lev AS BIGINT)) AS role_level,
        MAX(CASE WHEN v."#event_name" = 'stage_fight' AND v.a_rst[1].key = '1001' THEN CAST(v.stage_id AS INTEGER) END) AS max_stage_id,
        MAX(v."#event_time") AS last_event_time
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v.${PartDate:date1} 
      AND ub."#user_id" IS NULL
    GROUP BY 1
),

-- 3. 按等级分组，计算各项指标
LevelStats AS (
    SELECT 
        s.role_level,
        COUNT(DISTINCT s."#user_id") AS au,
        FLOOR(AVG(CAST(s.max_stage_id AS DOUBLE))) AS avg_max_stage_id,
        ROUND(AVG(DATE_DIFF('minute', CAST(nr.new_role_time AS TIMESTAMP), CAST(s.last_event_time AS TIMESTAMP)) / 60.0), 2) AS avg_hours_from_new_role
    FROM UserState s
    LEFT JOIN UserNewRole nr ON s."#user_id" = nr."#user_id"
    WHERE s.role_level IS NOT NULL
    GROUP BY 1
)

-- 4. 关联关卡维度表，输出最终结果
SELECT 
    ls.role_level AS "等级",
    ls.au AS "人数(AU)",
    CAST(ls.avg_max_stage_id AS BIGINT) AS "平均最高关卡ID",
    ds."stage_id@stage_name_real" AS "平均最高关卡名称",
    ls.avg_hours_from_new_role AS "平均距离创角时间(小时)"
FROM LevelStats ls
LEFT JOIN ta_dim.dim_13_0_18203 ds ON ls.avg_max_stage_id = ds."stage_id@stage_id"
ORDER BY 1 ASC;
