/* 
================================================================================
项目：蜡笔小新 - 两个时段的新增用户分时留存对比
描述：参考 Jump 的分小时留存对比脚本，改为使用小新的表和标识。
      使用 new_role 事件定义新用户的注册时间和操作系统。
================================================================================
*/
WITH
-- 1. 分别锁定两个时段的注册日边界
Period1Range AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_13
    WHERE ${PartDate:date1}
),
Period2Range AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_13
    WHERE ${PartDate:date2}
),

-- 2. 黑名单过滤
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 3. 获取新用户注册日期和OS (基于 new_role 事件)
UserProfileDetail AS (
    SELECT 
        "#user_id", 
        event_os AS fixed_os,
        "$part_date" AS fixed_regdate,
        ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time") AS rank
    FROM ta.v_event_13
    WHERE "$part_date" >= '2026-01-01'
      AND "$part_event" = 'new_role'
      AND event_os NOT IN ('5x')
      AND event_os IS NOT NULL
),

-- 4. 两个时段各自的 Cohort 用户集 (UNION ALL, 避免跨时段合并)
CohortUsers AS (
    SELECT u."#user_id", u.fixed_regdate AS reg_date, u.fixed_os AS ostype, '事件时间' AS period, p.p_start
    FROM UserProfileDetail u
    LEFT JOIN UserBlacklist b ON u."#user_id" = b."#user_id"
    CROSS JOIN Period1Range p
    WHERE u.rank = 1
      AND b."#user_id" IS NULL
      AND CAST(u.fixed_regdate AS DATE) BETWEEN p.p_start AND p.p_end

    UNION ALL

    SELECT u."#user_id", u.fixed_regdate AS reg_date, u.fixed_os AS ostype, '对比时间' AS period, p.p_start
    FROM UserProfileDetail u
    LEFT JOIN UserBlacklist b ON u."#user_id" = b."#user_id"
    CROSS JOIN Period2Range p
    WHERE u.rank = 1
      AND b."#user_id" IS NULL
      AND CAST(u.fixed_regdate AS DATE) BETWEEN p.p_start AND p.p_end
),

-- 5. 回访行为明细 (两个窗口各自扫描，互不干扰)
UserActivity AS (
    -- 事件时间窗口: p1_start ~ p1_end+7
    SELECT 
        s1."#user_id",
        s2.period, s2.p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(CAST(s1."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_13 s1
    INNER JOIN CohortUsers s2 ON s1."#user_id" = s2."#user_id" AND s2.period = '事件时间'
    CROSS JOIN Period1Range p
    WHERE s1."$part_date" BETWEEN CAST(p.p_start AS VARCHAR) AND CAST(DATE_ADD('day', 7, p.p_end) AS VARCHAR)
      AND s1."$part_event" = 'ta_app_start'  -- 定义留存的活跃事件，默认使用 ta_app_start

    UNION ALL

    -- 对比时间窗口: p2_start ~ p2_end+7
    SELECT 
        s1."#user_id",
        s2.period, s2.p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(CAST(s1."#event_time" AS TIMESTAMP)) AS event_hour
    FROM ta.v_event_13 s1
    INNER JOIN CohortUsers s2 ON s1."#user_id" = s2."#user_id" AND s2.period = '对比时间'
    CROSS JOIN Period2Range p
    WHERE s1."$part_date" BETWEEN CAST(p.p_start AS VARCHAR) AND CAST(DATE_ADD('day', 7, p.p_end) AS VARCHAR)
      AND s1."$part_event" = 'ta_app_start'
),

-- 6. 定义基准用户数 (不分小时)
BaseUsers AS (
    SELECT 
        period, 
        COUNT(DISTINCT "#user_id") AS new_account
    FROM CohortUsers
    GROUP BY 1
),

-- 7. 交叉并展平 0-23 个小时，计算每个时刻的累计回访数
HourlyStats AS (
    SELECT 
        a.period, a.p_start,
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN a.diff_day = ${Selector:retention} AND a.event_hour <= h.hr THEN a."#user_id" END) AS retained_users
    FROM UserActivity a
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1, 2, 3
)

-- 8. 最终输出
SELECT 
    s.period AS "对比阶段", 
    CAST(s.p_start AS VARCHAR) AS "阶段起始日期",
    CAST(s.hour AS VARCHAR) AS "hour",
    s.retained_users AS "累计分时留存人数",
    b.new_account AS "新增基准用户",
    CAST(s.retained_users AS DOUBLE) / NULLIF(b.new_account, 0) AS "留存率 (retention rate)"
FROM HourlyStats s
JOIN BaseUsers b ON s.period = b.period
ORDER BY 
    s.period DESC, 
    s.hour ASC;
