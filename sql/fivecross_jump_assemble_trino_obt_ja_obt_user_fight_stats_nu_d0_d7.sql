/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 指定日新用户 D+0~D+7 每日战斗行为统计
Cohort  : 由参数 ${PartDate:date1} 指定注册日的新用户（fixed_regdate 标签）
Window  : D+0 ~ D+7（注册日起共 8 天）
Metrics :
  - 每日活跃人数（有战斗记录）
  - 日人均总战斗次数
  - 日人均漫斗赛次数（model_type = 5）
  - 日人均排位赛次数（model_type = 2）
  - 漫斗赛各玩法日人均次数（game_type 细分）
Notes   :
  - 新用户定义: fixed_regdate = 参数指定日期，排除黑名单
  - 用户标识: lcx_id（sdkcommon.lcx_id 优先）
  - 漫斗赛 game_type 映射:
      1=卷轴争夺  2=单人乱斗  3=双人乱斗  4=武道会
      5=积分争夺  7=咒术高专  9=顶上战争  10=无限列车
      11=淘汰赛  12=忍界大战  15=龙珠之争  16=爆破对决
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 0. 从参数解析注册日（D+0），生成 D+0 ~ D+7 日期序列
--------------------------------------------------------------------------------
StartDate AS (
    SELECT MIN(CAST("$part_date" AS DATE)) AS d0
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
),

DateRange AS (
    SELECT
        DATE_ADD('day', n, d0)  AS dt,
        n                       AS day_offset
    FROM StartDate
    CROSS JOIN UNNEST(SEQUENCE(0, 7)) AS t(n)
),

--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 目标新用户队列
--    fixed_regdate = 参数指定日期，排除黑名单
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_23 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND CAST(t1.tag_value AS DATE) = (SELECT d0 FROM StartDate)
      AND ub.lcx_id IS NULL
),

--------------------------------------------------------------------------------
-- 3. 提取 D+0~D+7 内这批新用户的 arena_fight 事件
--------------------------------------------------------------------------------
FightLogs AS (
    SELECT
        COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id) AS lcx_id,
        v."$part_date"                                       AS fight_date,
        v.model_type,
        v.game_type
    FROM ta.v_event_23 v
    INNER JOIN NewUsers nu
        ON COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id) = nu.lcx_id
    WHERE v."$part_event" = 'arena_fight'
      AND v."$part_date" BETWEEN CAST((SELECT d0 FROM StartDate) AS VARCHAR)
                              AND CAST(DATE_ADD('day', 7, (SELECT d0 FROM StartDate)) AS VARCHAR)
),

--------------------------------------------------------------------------------
-- 4. 按日聚合战斗数据
--------------------------------------------------------------------------------
DailyFightStats AS (
    SELECT
        fight_date,
        COUNT(DISTINCT lcx_id)                                          AS active_users,

        -- 总战斗次数
        COUNT(*)                                                        AS total_fights,

        -- 漫斗赛（model_type = 5）
        COUNT(CASE WHEN model_type = 5 THEN 1 END)                     AS fights_casual,

        -- 排位赛（model_type = 2）
        COUNT(CASE WHEN model_type = 2 THEN 1 END)                     AS fights_ranked,

        -- 漫斗赛各玩法细分（model_type = 5 下的 game_type）
        COUNT(CASE WHEN model_type = 5 AND game_type = 1  THEN 1 END)  AS casual_gt1,
        COUNT(CASE WHEN model_type = 5 AND game_type = 2  THEN 1 END)  AS casual_gt2,
        COUNT(CASE WHEN model_type = 5 AND game_type = 3  THEN 1 END)  AS casual_gt3,
        COUNT(CASE WHEN model_type = 5 AND game_type = 4  THEN 1 END)  AS casual_gt4,
        COUNT(CASE WHEN model_type = 5 AND game_type = 5  THEN 1 END)  AS casual_gt5,
        COUNT(CASE WHEN model_type = 5 AND game_type = 7  THEN 1 END)  AS casual_gt7,
        COUNT(CASE WHEN model_type = 5 AND game_type = 9  THEN 1 END)  AS casual_gt9,
        COUNT(CASE WHEN model_type = 5 AND game_type = 10 THEN 1 END)  AS casual_gt10,
        COUNT(CASE WHEN model_type = 5 AND game_type = 11 THEN 1 END)  AS casual_gt11,
        COUNT(CASE WHEN model_type = 5 AND game_type = 12 THEN 1 END)  AS casual_gt12,
        COUNT(CASE WHEN model_type = 5 AND game_type = 15 THEN 1 END)  AS casual_gt15,
        COUNT(CASE WHEN model_type = 5 AND game_type = 16 THEN 1 END)  AS casual_gt16
    FROM FightLogs
    GROUP BY fight_date
)

--------------------------------------------------------------------------------
-- 5. 最终输出：以日期序列为主表，LEFT JOIN 战斗数据
--------------------------------------------------------------------------------
SELECT
    CAST(dr.dt AS VARCHAR)                                              AS "日期",
    CONCAT('D+', CAST(dr.day_offset AS VARCHAR))                       AS "天数",

    -- 活跃人数（当天有战斗记录的新用户数）
    COALESCE(s.active_users, 0)                                        AS "有战斗记录人数",

    -- 日人均次数（总次数 / 有战斗记录人数）
    ROUND(CAST(COALESCE(s.total_fights,   0) AS DOUBLE)
        / NULLIF(s.active_users, 0), 2)                                AS "日人均总战斗次数",

    ROUND(CAST(COALESCE(s.fights_casual,  0) AS DOUBLE)
        / NULLIF(s.active_users, 0), 2)                                AS "日人均漫斗赛次数",

    ROUND(CAST(COALESCE(s.fights_ranked,  0) AS DOUBLE)
        / NULLIF(s.active_users, 0), 2)                                AS "日人均排位赛次数",

    -- 漫斗赛各玩法日人均
    ROUND(CAST(COALESCE(s.casual_gt1,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-卷轴争夺",
    ROUND(CAST(COALESCE(s.casual_gt2,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-单人乱斗",
    ROUND(CAST(COALESCE(s.casual_gt3,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-双人乱斗",
    ROUND(CAST(COALESCE(s.casual_gt4,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-武道会",
    ROUND(CAST(COALESCE(s.casual_gt5,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-积分争夺",
    ROUND(CAST(COALESCE(s.casual_gt7,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-咒术高专",
    ROUND(CAST(COALESCE(s.casual_gt9,  0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-顶上战争",
    ROUND(CAST(COALESCE(s.casual_gt10, 0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-无限列车",
    ROUND(CAST(COALESCE(s.casual_gt11, 0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-淘汰赛",
    ROUND(CAST(COALESCE(s.casual_gt12, 0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-忍界大战",
    ROUND(CAST(COALESCE(s.casual_gt15, 0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-龙珠之争",
    ROUND(CAST(COALESCE(s.casual_gt16, 0) AS DOUBLE) / NULLIF(s.active_users, 0), 2)  AS "漫斗赛-爆破对决"

FROM DateRange dr
LEFT JOIN DailyFightStats s ON CAST(dr.dt AS VARCHAR) = s.fight_date
ORDER BY dr.day_offset ASC;
