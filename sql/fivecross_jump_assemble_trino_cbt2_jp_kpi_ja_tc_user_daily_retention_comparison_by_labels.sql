WITH
-- 1. 分别锁定两个时段的注册日边界
Period1Range AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
),
Period2Range AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS p_start,
        MAX(CAST("$part_date" AS DATE)) AS p_end
    FROM ta.v_event_16
    WHERE ${PartDate:date2}
),

-- 2. 黑名单过滤
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 3. 用户标签数据表
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate')
    GROUP BY 1
),

-- 4. 两个时段各自的 Cohort 用户集 (UNION ALL, 避免跨时段合并)
CohortUsers AS (
    SELECT u."#account_id", u.fixed_regdate AS reg_date, u.fixed_os AS ostype, '事件时间' AS period, p.p_start
    FROM UserProfileDetail u
    LEFT JOIN UserBlacklist b ON u."#account_id" = b."#account_id"
    CROSS JOIN Period1Range p
    WHERE b."#account_id" IS NULL
      AND u.fixed_regdate IS NOT NULL
      AND CAST(u.fixed_regdate AS DATE) BETWEEN p.p_start AND p.p_end

    UNION ALL

    SELECT u."#account_id", u.fixed_regdate AS reg_date, u.fixed_os AS ostype, '对比时间' AS period, p.p_start
    FROM UserProfileDetail u
    LEFT JOIN UserBlacklist b ON u."#account_id" = b."#account_id"
    CROSS JOIN Period2Range p
    WHERE b."#account_id" IS NULL
      AND u.fixed_regdate IS NOT NULL
      AND CAST(u.fixed_regdate AS DATE) BETWEEN p.p_start AND p.p_end
),

-- 5. 回访行为明细 (两个窗口各自扫描，互不干扰)
UserActivity AS (
    -- 事件时间窗口: p1_start ~ p1_end+7
    SELECT 
        s1."#account_id",
        s2.period,
        s2.p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers s2 ON s1."#account_id" = s2."#account_id" AND s2.period = '事件时间'
    CROSS JOIN Period1Range p
    WHERE s1."$part_date" BETWEEN CAST(p.p_start AS VARCHAR) AND CAST(DATE_ADD('day', 7, p.p_end) AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')

    UNION ALL

    -- 对比时间窗口: p2_start ~ p2_end+7
    SELECT 
        s1."#account_id",
        s2.period,
        s2.p_start,
        s2.reg_date,
        DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)) AS diff_day,
        HOUR(s1."#event_time") AS event_hour
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers s2 ON s1."#account_id" = s2."#account_id" AND s2.period = '对比时间'
    CROSS JOIN Period2Range p
    WHERE s1."$part_date" BETWEEN CAST(p.p_start AS VARCHAR) AND CAST(DATE_ADD('day', 7, p.p_end) AS VARCHAR)
      AND s1."$part_event" IN ('LOGIN_SUCCESS', 'NUU')
),

-- 6. 定义基准用户数 (不分小时)
BaseUsers AS (
    SELECT 
        period, 
        p_start,
        COUNT(DISTINCT "#account_id") AS new_account
    FROM CohortUsers
    GROUP BY 1, 2
),

-- 7. 交叉并展平 0-23 个小时，计算每个时刻的累计回访数
HourlyStats AS (
    SELECT 
        a.period,
        a.p_start,
        h.hr AS hour,
        COUNT(DISTINCT CASE WHEN a.diff_day = ${Selector:retention} AND a.event_hour <= h.hr THEN a."#account_id" END) AS retained_users
    FROM UserActivity a
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
    GROUP BY 1, 2, 3
)

-- 8. 最终输出
SELECT 
    s.period,
    s.p_start,
    CAST(s.hour AS VARCHAR) AS "hour",
    CAST(s.retained_users AS DOUBLE) / NULLIF(b.new_account, 0) AS "retention rate"
FROM HourlyStats s
JOIN BaseUsers b ON s.period = b.period AND s.p_start = b.p_start
ORDER BY 
    s.period DESC, 
    s.p_start ASC, 
    s.hour ASC
