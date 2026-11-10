/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 4月15日新用户偏好分析 (漫斗赛 vs 排位赛) 与留存 (按战斗次数分桶 - 3场一组)
Cohort  : 2026-04-15 注册 of iOS 新用户
Filter  : 无
Metrics : 次留, 2留, 3留, 4留, 5留
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 4/15 注册的 iOS 新用户
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND t1.tag_value    = '2026-04-15'
      AND ub.lcx_id IS NULL
      AND EXISTS (
          SELECT 1 FROM user_result_cluster_16 t2
          WHERE t2."#varchar_id" = t1."#varchar_id"
            AND t2.cluster_name  = 'fixed_os'
            AND t2.tag_value     = 'iOS'
      )
),

--------------------------------------------------------------------------------
-- 3. 首日(4/15) 战斗详情与偏好定义
--    Ranked (排位赛) : model_type = 2
--    Mandou (漫斗赛) : model_type = 5
--------------------------------------------------------------------------------
FirstDayFights AS (
    SELECT
        nu.lcx_id,
        COUNT(*) AS total_fights,
        COUNT(CASE WHEN v.model_type = 2 THEN 1 END) AS ranked_fights,
        COUNT(CASE WHEN v.model_type = 5 THEN 1 END) AS mandou_fights
    FROM NewUsers nu
    INNER JOIN ta.v_event_16 v
        ON nu.lcx_id = COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id)
    WHERE v."$part_date" = '2026-04-15'
      AND v."$part_event" = 'arena_fight'
      -- 仅限真人参与的模式
      AND v.model_type IN (1, 2, 3, 5)
    GROUP BY nu.lcx_id
),

UserPreference AS (
    SELECT
        lcx_id,
        total_fights,
        CASE
            WHEN ranked_fights >= mandou_fights THEN '偏好排位赛'
            ELSE '偏好漫斗赛'
        END AS preference
    FROM FirstDayFights
),

--------------------------------------------------------------------------------
-- 4. 留存数据 (4/16 ~ 4/20)
--------------------------------------------------------------------------------
RetentionLogs AS (
    SELECT
        v."$part_date" AS log_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id
    FROM ta.v_event_16 v
    INNER JOIN UserPreference up ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = up.lcx_id
    WHERE v."$part_date" BETWEEN '2026-04-16' AND '2026-04-20'
)

--------------------------------------------------------------------------------
-- 5. 汇总展示
--------------------------------------------------------------------------------
SELECT
    up.preference                                          AS "用户偏好类型",
    CASE 
        WHEN up.total_fights BETWEEN 1 AND 3   THEN '01-03 场'
        WHEN up.total_fights BETWEEN 4 AND 6   THEN '04-06 场'
        WHEN up.total_fights BETWEEN 7 AND 9   THEN '07-09 场'
        WHEN up.total_fights BETWEEN 10 AND 12 THEN '10-12 场'
        WHEN up.total_fights BETWEEN 13 AND 15 THEN '13-15 场'
        WHEN up.total_fights BETWEEN 16 AND 18 THEN '16-18 场'
        WHEN up.total_fights BETWEEN 19 AND 21 THEN '19-21 场'
        WHEN up.total_fights BETWEEN 22 AND 24 THEN '22-24 场'
        WHEN up.total_fights BETWEEN 25 AND 27 THEN '25-27 场'
        WHEN up.total_fights BETWEEN 28 AND 30 THEN '28-30 场'
        WHEN up.total_fights BETWEEN 31 AND 33 THEN '31-33 场'
        WHEN up.total_fights BETWEEN 34 AND 36 THEN '34-36 场'
        WHEN up.total_fights BETWEEN 37 AND 39 THEN '37-39 场'
        WHEN up.total_fights >= 40 THEN '40 场及以上'
    END                                                    AS "首日战斗场次分组",
    COUNT(DISTINCT up.lcx_id)                              AS "符合条件总人数",
    
    -- 次留 (4/16)
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-16' THEN rl.lcx_id END) AS DOUBLE) 
        / COUNT(DISTINCT up.lcx_id) * 100, 2)              AS "次留率(%)",
    
    -- 2留 (4/17)
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-17' THEN rl.lcx_id END) AS DOUBLE) 
        / COUNT(DISTINCT up.lcx_id) * 100, 2)              AS "2留率(%)",
    
    -- 3留 (4/18)
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-18' THEN rl.lcx_id END) AS DOUBLE) 
        / COUNT(DISTINCT up.lcx_id) * 100, 2)              AS "3留率(%)",
    
    -- 4留 (4/19)
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-19' THEN rl.lcx_id END) AS DOUBLE) 
        / COUNT(DISTINCT up.lcx_id) * 100, 2)              AS "4留率(%)",
    
    -- 5留 (4/20)
    ROUND(CAST(COUNT(DISTINCT CASE WHEN rl.log_date = '2026-04-20' THEN rl.lcx_id END) AS DOUBLE) 
        / COUNT(DISTINCT up.lcx_id) * 100, 2)              AS "5留率(%)"

FROM UserPreference up
LEFT JOIN RetentionLogs rl ON up.lcx_id = rl.lcx_id
GROUP BY 1, 2
ORDER BY 1 DESC;
