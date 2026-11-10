/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 4/15 注册新用户在 4/16 分偏好及 4/17 流失状态的战斗胜率分析
Cohort  : 2026-04-15 注册的新用户 (已剔除内部与灌水黑名单)
          在 2026-04-16 有 arena_fight (排位或漫斗) 战斗记录
Grouping: 
  1. 玩法偏好 (user_preference): 比较 4/16 当天排位赛最后段位与漫斗赛最后段位，高者为偏好
  2. 4/17 流失状态: 4/17 无任何事件日志则为 流失，反之为 未流失
Metrics : 
  - 该区组下的总人数
  - 排位赛胜率 (%)
  - 漫斗赛总场次、胜率 (%)
  - 漫斗赛中「大比分领先AI获胜局」次数（积分赛 model_type=5,game_type=5，赢且领先≥6分）
  - 核心关注：他们在各自偏好模式下的真实胜率
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 1. 黑名单提取
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 4/15 注册的新用户 (去除黑名单)
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND t1.tag_value    = '2026-04-15'
      AND ub.lcx_id IS NULL
),

--------------------------------------------------------------------------------
-- 3. 读取积分赛（漫斗赛子类，model_type=5, game_type=5）输家得分
--    赢家固定得10分，输家得分来自 ji_fen.fail_camp_score
--    大比分判定：赢局中对方得分<=4 => 领先>=6分
--------------------------------------------------------------------------------
LoserScore AS (
    -- 按 battle_id 去重，防止同一场多次触发 client_customs_pass 导致 JOIN 扇出
    SELECT
        battle_id,
        MAX(CAST(ji_fen.fail_camp_score AS INTEGER)) AS fail_camp_score
    FROM ta.v_event_16
    WHERE "$part_date"  = '2026-04-16'
      AND "$part_event" = 'client_customs_pass'
      AND model_type    = 5
      AND game_type     = 5
    GROUP BY battle_id
),

--------------------------------------------------------------------------------
-- 4. 取出每个用户在 4/16 两种模式 ( 排位=2, 漫斗=5 ) 下最后一次战斗段位
--------------------------------------------------------------------------------
FightUsers416_Raw AS (
    SELECT 
        lcx_id,
        MAX(CASE WHEN model_type = 2 THEN player_ladder_level ELSE 0 END) AS ranked_ladder,
        MAX(CASE WHEN model_type = 5 THEN player_ladder_level ELSE 0 END) AS mandou_ladder
    FROM (
        SELECT 
            COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
            CAST(v.model_type AS INTEGER) AS model_type,
            CAST(v.player_ladder_level AS INTEGER) AS player_ladder_level,
            ROW_NUMBER() OVER(
                PARTITION BY COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id), v.model_type
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_16 v
        INNER JOIN NewUsers nu 
            ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
        WHERE v."$part_date" = '2026-04-16'
          AND v."$part_event" = 'arena_fight'
          AND v.player_ladder_level IS NOT NULL
          AND CAST(v.model_type AS INTEGER) IN (2, 5)
    )
    WHERE rn = 1
    GROUP BY lcx_id
),

--------------------------------------------------------------------------------
-- 5. 统计每个用户在 4/16 各模式的战斗胜场与总场次 ( rank = 1 为胜 )
--    新增：漫斗赛中积分赛大比分领先AI胜局数
--      条件：model_type=5 & rank=1 & robot_num>=1 & fail_camp_score<=4（对方<=4分，领先>=6分）
--------------------------------------------------------------------------------
FightAgg416 AS (
    SELECT 
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 THEN 1 ELSE 0 END) AS ranked_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 AND v.rank = 1 THEN 1 ELSE 0 END) AS ranked_wins,
        -- 机器人场 vs 真实场
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1 THEN 1 ELSE 0 END) AS ranked_robot_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 2 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) = 0  THEN 1 ELSE 0 END) AS ranked_real_fights,

        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 THEN 1 ELSE 0 END) AS mandou_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND v.rank = 1 THEN 1 ELSE 0 END) AS mandou_wins,
        -- 机器人场 vs 真实场
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1 THEN 1 ELSE 0 END) AS mandou_robot_fights,
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) = 0  THEN 1 ELSE 0 END) AS mandou_real_fights,
        -- 积分赛场次 (漫斗赛子类 game_type=5)
        SUM(CASE WHEN CAST(v.model_type AS INTEGER) = 5 AND CAST(COALESCE(v.game_type, 0) AS INTEGER) = 5 THEN 1 ELSE 0 END) AS arena_fights,

        -- 漫斗赛：大比分领先AI获胜局（积分赛子类，赢且对方<=4分即领先>=6分）
        SUM(CASE 
            WHEN CAST(v.model_type AS INTEGER) = 5
             AND CAST(v.rank AS INTEGER) = 1
             AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1
             AND COALESCE(ls.fail_camp_score, 10) <= 4
            THEN 1 ELSE 0
        END) AS mandou_blowout_ai_wins
    FROM ta.v_event_16 v
    INNER JOIN NewUsers nu 
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
    LEFT JOIN LoserScore ls
        ON v.battle_id = ls.battle_id
    WHERE v."$part_date" = '2026-04-16'
      AND v."$part_event" = 'arena_fight'
      AND CAST(v.model_type AS INTEGER) IN (2, 5)
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 5. 合并并判断玩法偏好
--------------------------------------------------------------------------------
UserMerged AS (
    SELECT
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
    FROM FightUsers416_Raw a
    INNER JOIN FightAgg416 b ON a.lcx_id = b.lcx_id
),

--------------------------------------------------------------------------------
-- 6. 4/17 的留存记录 (用于判断是否流失)
--------------------------------------------------------------------------------
Retention417 AS (
    SELECT DISTINCT
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id
    FROM ta.v_event_16 v
    INNER JOIN UserMerged um 
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = um.lcx_id
    WHERE v."$part_date" = '2026-04-17'
)

--------------------------------------------------------------------------------
-- 7. 最终聚合输出
--------------------------------------------------------------------------------
SELECT 
    um.user_preference                                     AS "4/16 玩法偏好",
    CASE WHEN r.lcx_id IS NOT NULL THEN '未流失(留存)' 
         ELSE '已流失(未活跃)' END                          AS "4/17 活跃/流失状态",
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

    -- 漫斗赛：大比分领先AI获胜局（积分赛，领先>=6分）
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
LEFT JOIN Retention417 r ON um.lcx_id = r.lcx_id
GROUP BY 1, 2
ORDER BY 1 ASC, 2 DESC;
