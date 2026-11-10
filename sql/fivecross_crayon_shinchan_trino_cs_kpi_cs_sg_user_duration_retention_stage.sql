/*
================================================================================
项目：蜡笔小新 - 新用户首日活跃时长与进度关系
描述：提取在指定日期有 new_role 事件的新用户，区分操作系统 (OS)，
      使用心跳法改进版计算用户首日活跃时长，分段后展示各区间的平均等级与平均最高主线关卡。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows', 'internal_users')
),

-- 0. 获取新用户及对应的 OS (使用指定的排重逻辑)
UserOSType AS (
    SELECT "#user_id", ostype
    FROM (
        SELECT "#user_id", event_os AS ostype,
        ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time") AS rank
        FROM ta.v_event_13
        WHERE "$part_date" >= '2026-01-01'
          AND "$part_event" = 'new_role'
          AND event_os NOT IN ('5x') 
          AND event_os IS NOT NULL
    )
    WHERE rank = 1
),

-- 1. 定义目标人群及活跃日期：今天的新用户
TargetUsers AS (
    SELECT 
        DISTINCT v."#user_id",
        v."$part_date" AS target_date,
        u.ostype
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN UserOSType u ON v."#user_id" = u."#user_id"
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'new_role'
      AND ub."#user_id" IS NULL
),

-- 2. 提取这些用户当日的事件，用于计算在线时长和进度 (去除 app 层级事件)
UserLogs AS (
    SELECT 
        v."#user_id",
        v."$part_date" AS target_date,
        tu.ostype,
        to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) AS t,
        LEAD(to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))) OVER (
            PARTITION BY v."#user_id", v."$part_date"
            ORDER BY v."#event_time"
        ) 
        - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) AS gap,
        CAST(v.role_lev AS BIGINT) AS role_level,
        CASE WHEN v."#event_name" = 'stage_fight' AND v.a_rst[1].key = '1001' THEN CAST(v.stage_id AS INTEGER) END AS stage_id
    FROM ta.v_event_13 v
    INNER JOIN TargetUsers tu ON v."#user_id" = tu."#user_id" AND v."$part_date" = tu.target_date
    WHERE v."#event_name" NOT LIKE '%app%'
),

-- 3. 汇总每人每天的总时长、最高等级、最高主线关卡
UserStats AS (
    SELECT 
        "#user_id",
        target_date,
        ostype,
        SUM(CASE WHEN gap < 120 THEN gap ELSE 0 END) AS total_seconds,
        MAX(role_level) AS max_role_level,
        MAX(stage_id) AS max_stage_id
    FROM UserLogs
    GROUP BY 1, 2, 3
),

-- 4. 时长分段
UserGroupStats AS (
    SELECT 
        "#user_id",
        target_date,
        ostype,
        max_role_level,
        max_stage_id,
        CASE 
            WHEN total_seconds < 120 THEN '00_0-2min'
            WHEN total_seconds >= 120 AND total_seconds < 300 THEN '01_2-5min'
            WHEN total_seconds >= 300 AND total_seconds < 600 THEN '02_5-10min'
            WHEN total_seconds >= 600 AND total_seconds < 900 THEN '03_10-15min'
            WHEN total_seconds >= 900 AND total_seconds < 1800 THEN '04_15-30min'
            WHEN total_seconds >= 1800 AND total_seconds < 3600 THEN '05_30-60min'
            WHEN total_seconds >= 3600 AND total_seconds < 7200 THEN '06_60-120min'
            WHEN total_seconds >= 7200 THEN '07_120min以上'
            ELSE '08_未知(可能为0)'
        END AS duration_group
    FROM UserStats
),

-- 5. 计算次日活跃用户
NextDayActive AS (
    SELECT DISTINCT "#user_id"
    FROM ta.v_event_13
    WHERE "$part_date" = CAST(DATE_ADD('day', 1, CAST((SELECT MIN(target_date) FROM TargetUsers) AS DATE)) AS VARCHAR)
),

-- 6. 分组计算各项指标 (按 OS 和 时长分段)
DurationAgg AS (
    SELECT 
        dg.ostype,
        dg.duration_group,
        COUNT(DISTINCT dg."#user_id") AS au,
        COUNT(DISTINCT nda."#user_id") AS ret_1_au,
        ROUND(AVG(CAST(dg.max_role_level AS DOUBLE)), 2) AS avg_role_level,
        FLOOR(AVG(CAST(dg.max_stage_id AS DOUBLE))) AS avg_max_stage_id
    FROM UserGroupStats dg
    LEFT JOIN NextDayActive nda ON dg."#user_id" = nda."#user_id"
    GROUP BY 1, 2
)

-- 7. 关联关卡表输出最终结果
SELECT 
    da.ostype AS "操作系统",
    da.duration_group AS "在线时长区间",
    da.au AS "首日活跃人数",
    da.avg_role_level AS "平均等级",
    CAST(da.avg_max_stage_id AS BIGINT) AS "平均最高关卡ID",
    ds."stage_id@stage_name_real" AS "平均最高关卡名称",
    da.ret_1_au AS "次日留存人数",
    CONCAT(CAST(ROUND((CAST(da.ret_1_au AS DOUBLE) / NULLIF(da.au, 0)) * 100, 2) AS VARCHAR), '%') AS "次日留存率"
FROM DurationAgg da
LEFT JOIN ta_dim.dim_13_0_18203 ds ON da.avg_max_stage_id = ds."stage_id@stage_id"
ORDER BY 1 ASC, 2 ASC;
