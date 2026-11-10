WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
gacha_logs AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE 
            WHEN v."$part_event" = 'skill_get' THEN '技能抽卡'
            WHEN v."$part_event" = 'Companion_get' THEN '伙伴抽卡'
            WHEN v."$part_event" = 'movie_get' THEN '影像抽卡'
        END AS gacha_type,
        SUM(v.len) AS total_gacha_times,
        COUNT(DISTINCT v."#account_id") AS gacha_user_count,
        CAST(SUM(v.len) AS DOUBLE) / NULLIF(COUNT(DISTINCT v."#account_id"), 0) AS avg_gacha_times_per_user
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" IN ('skill_get','Companion_get') -- ,'movie_get')
    AND v.${PartDate:date1}
    AND ub."#user_id" IS NULL
    GROUP BY 1, 2
),
active_users AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        COUNT(DISTINCT v."#account_id") AS active_user_count
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" = 'login'
    AND v.login_type IN (2, 3)
    AND v.${PartDate:date1}
    AND ub."#user_id" IS NULL
    GROUP BY 1
)
SELECT 
    g.time_dimension AS "时间维度",
    g.gacha_type AS "抽卡类型",
    g.total_gacha_times AS "总抽卡次数",
    g.gacha_user_count AS "抽卡人数",
    ROUND(g.avg_gacha_times_per_user,2) AS "人均抽卡次数",
    a.active_user_count AS "活跃人数",
    ROUND(CAST(g.gacha_user_count AS DOUBLE) / NULLIF(a.active_user_count, 0),4) AS "抽卡渗透率"
FROM gacha_logs g
LEFT JOIN active_users a ON g.time_dimension = a.time_dimension
ORDER BY g.time_dimension DESC, g.gacha_type;
