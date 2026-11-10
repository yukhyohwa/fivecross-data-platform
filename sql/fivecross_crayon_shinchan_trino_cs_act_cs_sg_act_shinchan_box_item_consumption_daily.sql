WITH
-- 如需仅统计新加坡用户，取消此段及下面两处 INNER JOIN 的注释
-- SingaporeUsers AS (
--     SELECT DISTINCT "#user_id"
--     FROM user_result_cluster_18
--     WHERE cluster_name = 'fixed_country'
--       AND tag_value = '新加坡'
-- ),

UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_windows', 'internal_users')
),

-- 1. 每日活跃人数（AU）
DailyAU AS (
    SELECT
        v."$part_date" AS time_dimension,
        COUNT(DISTINCT v."#account_id") AS active_users
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub
        ON v."#user_id" = ub."#user_id"
--  INNER JOIN SingaporeUsers su
--      ON v."#user_id" = su."#user_id"
    WHERE v."$part_event" = 'login'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
    GROUP BY 1
),

-- 2. 按“日期 + 用户”汇总道具 10238 的消耗量
DailyUserConsume AS (
    SELECT
        v."$part_date" AS time_dimension,
        v."#account_id",
        SUM(
            REDUCE(
                v.a_rst,
                CAST(0 AS BIGINT),
                (s, x) -> s + CASE
                    WHEN CAST(x.id AS BIGINT) = 10238
                     AND CAST(x.before AS BIGINT) > CAST(x.after AS BIGINT)
                    THEN ABS(CAST(x.diff AS BIGINT))
                    ELSE 0
                END,
                s -> s
            )
        ) AS user_daily_consume
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub
        ON v."#user_id" = ub."#user_id"
--  INNER JOIN SingaporeUsers su
--      ON v."#user_id" = su."#user_id"
    WHERE v."$part_event" = 'item_change'
      AND v.${PartDate:date1}
      AND ub."#user_id" IS NULL
      AND ANY_MATCH(
          v.a_rst,
          x -> CAST(x.id AS BIGINT) = 10238
      )
    GROUP BY 1, 2
),

-- 3. 按日汇总消耗数据
ConsumeLogs AS (
    SELECT
        time_dimension,
        SUM(user_daily_consume) AS total_consume,
        COUNT(*) AS consume_users,
        MAX_BY("#account_id", user_daily_consume) AS max_consume_user_id,
        MAX(user_daily_consume) AS max_single_user_daily_consume
    FROM DailyUserConsume
    WHERE user_daily_consume > 0
    GROUP BY 1
)

-- 4. 合并每日消耗、AU、渗透率及人均消耗
SELECT
    c.time_dimension AS "日期",
    c.consume_users AS "参与人数(消耗人数)",
    c.total_consume AS "活动道具消耗总数",
    c.max_consume_user_id AS "单日消耗最多用户ID",
    c.max_single_user_daily_consume AS "该用户单日累计消耗次数",
    a.active_users AS "全服活跃人数(AU)",
    ROUND(
        CAST(c.consume_users AS DOUBLE) / NULLIF(a.active_users, 0),
        4
    ) AS "参与渗透率",
    ROUND(
        CAST(c.total_consume AS DOUBLE) / NULLIF(c.consume_users, 0),
        2
    ) AS "人均消耗数"
FROM ConsumeLogs c
LEFT JOIN DailyAU a
    ON c.time_dimension = a.time_dimension
ORDER BY c.time_dimension DESC;
