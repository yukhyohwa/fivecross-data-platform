/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 玩法偏好及流失状态的战斗胜率分析（滚动5日 Cohort 汇总）

分析逻辑 (D+0 / D+1 / D+2):
  D+0  注册日：提取新用户
  D+1  行为日：漫斗赛/排位赛战斗数据、段位结算，以此判断玩法偏好
  D+2  流失日：当天有无任何事件日志

覆盖的5个 Cohort:
  D+0(注册)    D+1(数据/偏好)  D+2(流失判断)
  2026-04-15  2026-04-16      2026-04-17
  2026-04-16  2026-04-17      2026-04-18
  2026-04-17  2026-04-18      2026-04-19
  2026-04-18  2026-04-19      2026-04-20
  2026-04-19  2026-04-20      2026-04-21

维度分组:
  1. 玩法偏好 (根据 D+1 的排位赛和漫斗赛最后段位比较)
  2. D+2 流失状态

数据呈现：将5个 Cohort 汇总在一起，不按日拆分。
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 0. 日期参数表
--------------------------------------------------------------------------------
DateParams AS (
    SELECT *
    FROM (VALUES
        ('2026-04-15', '2026-04-16', '2026-04-17'),
        ('2026-04-16', '2026-04-17', '2026-04-18'),
        ('2026-04-17', '2026-04-18', '2026-04-19'),
        ('2026-04-18', '2026-04-19', '2026-04-20'),
        ('2026-04-19', '2026-04-20', '2026-04-21')
    ) AS t(reg_date, fight_date, churn_date)
),

--------------------------------------------------------------------------------
-- 1. 黑名单提取
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 各日期注册的新用户（去除黑名单）
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT
        dp.reg_date,
        dp.fight_date,
        dp.churn_date,
        t1."#varchar_id" AS lcx_id
    FROM DateParams dp
    CROSS JOIN user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND t1.tag_value    = dp.reg_date
      AND ub.lcx_id IS NULL
),

--------------------------------------------------------------------------------
-- 3. 读取积分赛输家得分（按 fight_date 和 battle_id 去重）
--------------------------------------------------------------------------------
LoserScore AS (
    SELECT
        v."$part_date" AS fight_date,
        v.battle_id,
        MAX(CAST(ji_fen.fail_camp_score AS INTEGER)) AS fail_camp_score
    FROM ta.v_event_16 v
    WHERE v."$part_date" BETWEEN '2026-04-16' AND '2026-04-20'
      AND v."$part_event" = 'client_customs_pass'
      AND v.model_type    = 5
      AND v.game_type     = 5
    GROUP BY v."$part_date", v.battle_id
),

--------------------------------------------------------------------------------
-- 4. 取 D+1 每个用户两种模式下最后一次战斗段位
--------------------------------------------------------------------------------
FightUsers_Raw AS (
    SELECT 
        sub.reg_date,
        sub.fight_date,
        sub.churn_date,
        sub.lcx_id,
        MAX(CASE WHEN sub.model_type = 2 THEN sub.player_ladder_level ELSE 0 END) AS ranked_ladder,
        MAX(CASE WHEN sub.model_type = 5 THEN sub.player_ladder_level ELSE 0 END) AS mandou_ladder
    FROM (
        SELECT 
            nu.reg_date,
            nu.fight_date,
            nu.churn_date,
            nu.lcx_id,
            CAST(v.model_type AS INTEGER) AS model_type,
            CAST(v.player_ladder_level AS INTEGER) AS player_ladder_level,
            ROW_NUMBER() OVER(
                PARTITION BY nu.lcx_id, nu.reg_date, v.model_type
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM NewUsers nu 
        INNER JOIN ta.v_event_16 v
            ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
        WHERE v."$part_date" = nu.fight_date
          AND v."$part_event" = 'arena_fight'
          AND v.player_ladder_level IS NOT NULL
          AND CAST(v.model_type AS INTEGER) IN (2, 5)
    ) sub
    WHERE rn = 1
    GROUP BY sub.reg_date, sub.fight_date, sub.churn_date, sub.lcx_id
),

--------------------------------------------------------------------------------
-- 5. 统计 D+1 各模式的战斗胜场与总场次
--------------------------------------------------------------------------------
FightAgg AS (
    SELECT 
        nu.reg_date,
        nu.lcx_id,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 THEN 1 ELSE 0 END) AS ranked_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 AND CAST(v.rank AS INTEGER) = 1 THEN 1 ELSE 0 END) AS ranked_wins,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1 THEN 1 ELSE 0 END) AS ranked_robot_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) = 0  THEN 1 ELSE 0 END) AS ranked_real_fights,

        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 THEN 1 ELSE 0 END) AS mandou_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(v.rank AS INTEGER) = 1 THEN 1 ELSE 0 END) AS mandou_wins,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1 THEN 1 ELSE 0 END) AS mandou_robot_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) = 0  THEN 1 ELSE 0 END) AS mandou_real_fights,
        
        -- 积分赛场次
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(COALESCE(v.game_type, 0) AS INTEGER) = 5 THEN 1 ELSE 0 END) AS arena_fights,

        -- 大比分领先AI获胜局
        SUM(CASE 
            WHEN CAST(v.model_type AS INTEGER) = 5
             AND CAST(v.rank AS INTEGER) = 1
             AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1
             AND COALESCE(ls.fail_camp_score, 10) <= 4
            THEN 1 ELSE 0
        END) AS mandou_blowout_ai_wins
    FROM NewUsers nu 
    INNER JOIN ta.v_event_16 v
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
    LEFT JOIN LoserScore ls
        ON v."$part_date" = ls.fight_date
       AND v.battle_id    = ls.battle_id
    WHERE v."$part_date"  = nu.fight_date
      AND v."$part_event" = 'arena_fight'
      AND CAST(v.model_type AS INTEGER) IN (2, 5)
    GROUP BY nu.reg_date, nu.lcx_id
),

--------------------------------------------------------------------------------
-- 6. 合并并判断玩法偏好
--------------------------------------------------------------------------------
UserMerged AS (
    SELECT
        a.reg_date,
        a.churn_date,
        a.lcx_id,
        CASE
            WHEN a.ranked_ladder > a.mandou_ladder THEN '偏向排位赛'
            WHEN a.mandou_ladder > a.ranked_ladder THEN '偏向漫斗赛'
            ELSE '段位相同(均衡)'
        END AS user_preference,
        b.ranked_fights,
        b.ranked_wins,
        b.ranked_robot_fights,
        b.ranked_real_fights,
        b.mandou_fights,
        b.mandou_wins,
        b.mandou_robot_fights,
        b.mandou_real_fights,
        b.arena_fights,
        b.mandou_blowout_ai_wins
    FROM FightUsers_Raw a
    INNER JOIN FightAgg b ON a.reg_date = b.reg_date AND a.lcx_id = b.lcx_id
),

--------------------------------------------------------------------------------
-- 7. D+2 留存记录
--------------------------------------------------------------------------------
Retention AS (
    SELECT DISTINCT
        um.reg_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id
    FROM UserMerged um 
    INNER JOIN ta.v_event_16 v
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = um.lcx_id
    WHERE v."$part_date" = um.churn_date
)

--------------------------------------------------------------------------------
-- 8. 最终聚合输出 (5 个 Cohort 汇总)
--------------------------------------------------------------------------------
SELECT 
    um.user_preference                                     AS "玩法偏好",
    CASE WHEN r.lcx_id IS NOT NULL THEN '未流失(D+2有活跃)' 
         ELSE '已流失(D+2无活跃)' END                          AS "D+2 流失状态",
    COUNT(DISTINCT um.lcx_id)                              AS "用户总数",
    
    -- 排位赛综合表现
    SUM(um.ranked_fights)                                  AS "排位赛总场次",
    ROUND(CAST(SUM(um.ranked_robot_fights) AS DOUBLE) / COUNT(DISTINCT um.lcx_id), 2) AS "排位人均机器人场",
    ROUND(CAST(SUM(um.ranked_real_fights) AS DOUBLE) / COUNT(DISTINCT um.lcx_id), 2)  AS "排位人均真实场",
    ROUND(CAST(SUM(um.ranked_wins) AS DOUBLE) 
        / NULLIF(SUM(um.ranked_fights), 0) * 100, 2)       AS "排位赛整体胜率(%)",
        
    -- 漫斗赛综合表现
    SUM(um.mandou_fights)                                  AS "漫斗赛总场次",
    ROUND(CAST(SUM(um.arena_fights) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT um.lcx_id), 0), 2)         AS "人均积分赛场次",
    ROUND(CAST(SUM(um.mandou_robot_fights) AS DOUBLE) / COUNT(DISTINCT um.lcx_id), 2) AS "漫斗人均机器人场",
    ROUND(CAST(SUM(um.mandou_real_fights) AS DOUBLE) / COUNT(DISTINCT um.lcx_id), 2)  AS "漫斗人均真实场",
    ROUND(CAST(SUM(um.mandou_wins) AS DOUBLE) 
        / NULLIF(SUM(um.mandou_fights), 0) * 100, 2)       AS "漫斗赛整体胜率(%)",

    -- 大比分领先AI
    SUM(um.mandou_blowout_ai_wins)                         AS "积分赛大比分领先AI胜局总数",
    ROUND(CAST(SUM(um.mandou_blowout_ai_wins) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT um.lcx_id), 0), 2)         AS "人均大比分领先AI胜局数",
        
    -- 各自偏好模式的核心胜率
    CASE 
        WHEN um.user_preference = '偏向排位赛' 
            THEN ROUND(CAST(SUM(um.ranked_wins) AS DOUBLE) / NULLIF(SUM(um.ranked_fights), 0) * 100, 2)
        WHEN um.user_preference = '偏向漫斗赛' 
            THEN ROUND(CAST(SUM(um.mandou_wins) AS DOUBLE) / NULLIF(SUM(um.mandou_fights), 0) * 100, 2)
        ELSE 
             ROUND(CAST(SUM(um.ranked_wins + um.mandou_wins) AS DOUBLE) / NULLIF(SUM(um.ranked_fights + um.mandou_fights), 0) * 100, 2)
    END                                                    AS "该组偏好模式最终胜率(%)"

FROM UserMerged um
LEFT JOIN Retention r ON um.reg_date = r.reg_date AND um.lcx_id = r.lcx_id
GROUP BY 1, 2
ORDER BY 1 ASC, 2 DESC;
