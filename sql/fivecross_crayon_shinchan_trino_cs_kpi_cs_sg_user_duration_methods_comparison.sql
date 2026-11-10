/*
================================================================================
项目：蜡笔小新 - 在线时长两方法对比
描述：选定日期活跃用户队列（排除内部黑名单，限定新加坡），观察其 D+0 ~ D+7 的在线时长。
      对比两种时长计算方法：
      1. 心跳法       — 相邻事件间隔 < 120s 累加，末尾事件不补偿
                        用户标识: "#user_id"
      2. 数数SDK法    — 直接读取 ta_app_end 事件的 "#duration" 字段
                        用户标识: "#user_id"
================================================================================
*/

WITH
-- 1. 黑名单
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- [新增] 提取用户属性：国家
UserProfileDetail AS (
    SELECT 
        "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country
    FROM user_result_cluster_13
    WHERE cluster_name = 'fixed_country'
    GROUP BY 1
),

-- 2. 解析起始日，生成 D+0 ~ D+7 日期序列
StartDate AS (
    SELECT MIN(CAST("$part_date" AS DATE)) AS d0
    FROM ta.v_event_13
    WHERE ${PartDate:date1}
),

DateRange AS (
    SELECT
        DATE_ADD('day', n, d0) AS dt,
        n                      AS day_offset
    FROM StartDate
    CROSS JOIN UNNEST(SEQUENCE(0, 7)) AS t(n)
),

-- 3. 目标用户队列 (限定新加坡用户)
Cohort AS (
    SELECT DISTINCT v."#user_id"
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    INNER JOIN UserProfileDetail up ON v."#user_id" = up."#user_id"
    WHERE v.${PartDate:date1}
      AND ub."#user_id" IS NULL
      AND up.fixed_country = '新加坡'
),

-- 4. 方法1：修正心跳法 (Heartbeat)
M1_Gaps AS (
    SELECT
        v."#user_id",
        v."$part_date" AS report_date,
        LEAD(
            to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
        ) OVER (
            PARTITION BY v."#user_id", v."$part_date"
            ORDER BY v."#event_time"
        )
        - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
        AS gap
    FROM ta.v_event_13 v
    INNER JOIN Cohort c ON v."#user_id" = c."#user_id"
    WHERE v."$part_date" BETWEEN CAST((SELECT d0 FROM StartDate) AS VARCHAR)
                               AND CAST(DATE_ADD('day', 7, (SELECT d0 FROM StartDate)) AS VARCHAR)
      AND v."#event_name" NOT LIKE '%app%'
),

M1_Daily AS (
    SELECT
        report_date,
        COUNT(DISTINCT "#user_id") AS dau,
        SUM(CASE WHEN gap IS NOT NULL AND gap < 120 THEN gap ELSE 0 END)
            / NULLIF(COUNT(DISTINCT "#user_id"), 0) / 60.0 AS avg_min
    FROM M1_Gaps
    GROUP BY report_date
),

-- 5. 方法2：数数SDK法 (ta_app_end)
M2_Daily AS (
    SELECT
        v."$part_date" AS report_date,
        COUNT(DISTINCT v."#user_id") AS dau,
        SUM(v."#duration")
            / NULLIF(COUNT(DISTINCT v."#user_id"), 0) / 60.0 AS avg_min
    FROM ta.v_event_13 v
    INNER JOIN Cohort c ON v."#user_id" = c."#user_id"
    WHERE v."$part_date" BETWEEN CAST((SELECT d0 FROM StartDate) AS VARCHAR)
                               AND CAST(DATE_ADD('day', 7, (SELECT d0 FROM StartDate)) AS VARCHAR)
      AND v."$part_event" = 'ta_app_end'
    GROUP BY v."$part_date"
)

-- 6. 最终输出
SELECT
    CAST(dr.dt AS VARCHAR) AS "日期",
    CONCAT('D+', CAST(dr.day_offset AS VARCHAR)) AS "天数",
    
    -- 方法2：数数SDK法
    COALESCE(m2.dau, 0) AS "活跃人数(SDK法)",
    ROUND(COALESCE(m2.avg_min, 0), 2) AS "日均在线_分钟(SDK法)",
    
    -- 方法1：修正心跳法
    COALESCE(m1.dau, 0) AS "活跃人数(心跳法)",
    ROUND(COALESCE(m1.avg_min, 0), 2) AS "日均在线_分钟(心跳法)"

FROM DateRange dr
LEFT JOIN M1_Daily m1 ON CAST(dr.dt AS VARCHAR) = m1.report_date
LEFT JOIN M2_Daily m2 ON CAST(dr.dt AS VARCHAR) = m2.report_date
ORDER BY dr.day_offset ASC;
