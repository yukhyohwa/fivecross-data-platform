/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 4/15 注册新用户在 4/16 留存分析 (按最高段位与玩法偏好分组)
Cohort  : 2026-04-15 注册的新用户 (已剔除内部与灌水黑名单)
          在 2026-04-16 有 arena_fight (排位或漫斗) 战斗记录
Grouping: 
  1. 玩法偏好 (user_preference): 比较当天排位赛最后段位与漫斗赛最后段位，高者为偏好
  2. 最高段位 (player_ladder_level): 当天不论什么模式达到的最终最高段位
Metrics : 
  - 4/16 该偏好与段位下的战斗人数
  - 4/17 留存人数与留存率
  - 4/18 留存人数与留存率
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
-- 3. 取出每个用户在 4/16 两种模式 ( 排位=2, 漫斗=5 ) 下最后一次战斗段位
--------------------------------------------------------------------------------
FightUsers416_Raw AS (
    SELECT 
        lcx_id,
        MAX(CASE WHEN model_type = 2 THEN player_ladder_level ELSE 0 END) AS ranked_ladder,
        MAX(CASE WHEN model_type = 5 THEN player_ladder_level ELSE 0 END) AS mandou_ladder,
        MAX(player_ladder_level) AS max_ladder_level
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
-- 4. 判断用户玩法偏好
--------------------------------------------------------------------------------
FightUserGroups AS (
    SELECT 
        lcx_id,
        max_ladder_level AS player_ladder_level,
        CASE
            WHEN ranked_ladder > mandou_ladder THEN '偏向排位赛'
            WHEN mandou_ladder > ranked_ladder THEN '偏向漫斗赛'
            ELSE '段位相同(均衡)'
        END AS user_preference
    FROM FightUsers416_Raw
),

--------------------------------------------------------------------------------
-- 5. 4/17 和 4/18 的留存记录 (只要当天有任意日志记录即算作留存)
--------------------------------------------------------------------------------
RetentionLogs AS (
    SELECT 
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id
    FROM ta.v_event_16 v
    INNER JOIN FightUserGroups fu 
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = fu.lcx_id
    WHERE v."$part_date" IN ('2026-04-17', '2026-04-18')
    GROUP BY 1, 2
)

--------------------------------------------------------------------------------
-- 6. 按偏好和段位聚合输出留存指标
--------------------------------------------------------------------------------
SELECT 
    fu.user_preference                                     AS "玩法偏好",
    fu.player_ladder_level                                 AS "4/16 最终最高段位",
    COUNT(DISTINCT fu.lcx_id)                              AS "4/16 战斗总人数",
    
    -- 4/17 留存
    COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-17' THEN rl.lcx_id END) AS "4/17 留存人数",
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-17' THEN rl.lcx_id END) AS DOUBLE) 
        / NULLIF(COUNT(DISTINCT fu.lcx_id), 0) * 100, 2)   AS "4/17 留存率(%)",
        
    -- 4/18 留存
    COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-18' THEN rl.lcx_id END) AS "4/18 留存人数",
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-18' THEN rl.lcx_id END) AS DOUBLE) 
        / NULLIF(COUNT(DISTINCT fu.lcx_id), 0) * 100, 2)   AS "4/18 留存率(%)"

FROM FightUserGroups fu
LEFT JOIN RetentionLogs rl ON fu.lcx_id = rl.lcx_id
GROUP BY 1, 2
ORDER BY 1 ASC, 2 ASC;
