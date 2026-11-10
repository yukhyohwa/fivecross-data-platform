WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

DimStage AS (
    SELECT * FROM (VALUES
        (1001,'主线副本'),
        (1002,'挑战玩具小偷'),
        (1003,'挑战怪物扭蛋人'),
        (1005,'守护古老城市'),
        (1004,'竞技场'),
        (1018,'挑战邪恶的兔兔玩偶'),
        (1019,'挑战邪恶喵巴士'),
        (1006,'守护海滩'),
        (1007,'恐龙拳手大挑战'),
        (1022,'花圃内pvp副本'),
        (1008,'影像副本'),
        (1023,'切磋'),
        (1009,'穿越魔法之门'),
        (1021,'积木大乱斗'),
        (1024,'跨服竞技场'),
        (1010,'宝物预览副本'),
        (1011,'忍道・甜酸试炼'),
        (1012,'冒险试炼'),
        (1013,'宠物旅行'),
        (1014,'动感超人试炼—钻地土拨鼠'),
        (1015,'动感超人试炼—挖铲土拨鼠'),
        (1016,'动感超人试炼—挖矿土拨鼠'),
        (1017,'动感超人比赛'),
        (1020,'社团大评比')
    ) AS t(stage_type, stage_name)
),

ActiveUsers AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        COUNT(DISTINCT v."#account_id") AS active_user_count
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."$part_event" = 'login'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1
),

StageAttempts AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        v."#account_id",
        CAST(v.a_rst[1].key AS INT) AS stage_type,
        v.a_rst[1].id AS stage_id,
        CAST(v.role_lev AS BIGINT) AS role_level,
        ROW_NUMBER() OVER(PARTITION BY v."#account_id", v.a_rst[1].id ORDER BY v."#event_time" ASC) AS attempt_num,
        COUNT(1) OVER(PARTITION BY v."#account_id", v.a_rst[1].id) AS total_attempts
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE v."#event_name" = 'stage_fight'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
),

StageLogs AS (
    SELECT 
        time_dimension,
        stage_type,
        stage_id,
        COUNT(1) AS fight_times,
        COUNT(DISTINCT "#account_id") AS fight_users,
        AVG(CASE WHEN total_attempts >= 2 AND attempt_num = 1 THEN CAST(role_level AS DOUBLE) END) AS first_fail_avg_level,
        APPROX_PERCENTILE(CASE WHEN total_attempts >= 2 AND attempt_num = 1 THEN role_level END, 0.5) AS first_fail_median_level,
        COUNT(DISTINCT CASE WHEN total_attempts >= 2 AND attempt_num = 1 THEN "#account_id" END) AS fail_users_count
    FROM StageAttempts
    GROUP BY 1, 2, 3
)

SELECT 
    s.time_dimension AS "时间维度",
    "stage_id@stage_name_show" AS "关卡名称",
    MAX(stage_id) stage_id,
    MAX(s.fight_users) AS "该关卡挑战人数",
    MAX(s.fail_users_count) AS "卡关(首次失败)人数",
    MAX(CAST(s.fail_users_count AS DOUBLE)) / NULLIF(MAX(s.fight_users), 0) AS "首次挑战失败率",
    MAX(CASE WHEN SPLIT("stage_id@stage_name_real",'-')[3] = '5' THEN CAST(s.fail_users_count AS DOUBLE) END)/ NULLIF(MAX(CAST(s.fail_users_count AS DOUBLE)) ,0)  "二次挑战BOSS率",
    MIN(s.first_fail_avg_level) AS "首次失败平均等级",
    MIN(s.first_fail_median_level) AS "首次失败等级中位数"
FROM StageLogs s
LEFT JOIN DimStage ds ON s.stage_type = ds.stage_type
LEFT JOIN ta_dim.dim_13_0_18203 ds ON s.stage_id = ds."stage_id@stage_id"
WHERE s.stage_type = 1001 
 GROUP BY 1,2
-- 按照卡关人数降序排列，直接找出最难（失败人数最多）的关卡
ORDER BY 1 DESC, 6 DESC;
