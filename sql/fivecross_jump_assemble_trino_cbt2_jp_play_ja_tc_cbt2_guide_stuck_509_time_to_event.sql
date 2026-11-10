/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 509 → 1100 事件耗时对比 (Time-to-Event Median)
Cohort  : 2026-04-15 注册的 iOS 新用户
Groups  : 
  - Group A: 已到达1100（正常跑完流程）
  - Group B: 未达成（卡在 509）
Logic   : 
  提取每一个目标事件，计算每位用户【首次】触发该事件的时间距离触发 509 节点经过了多少秒。
  分别计算 A 组和 B 组各个事件耗时秒数的中位数（Median），并横向对比。
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
          SELECT 1
          FROM user_result_cluster_16 t2
          WHERE t2."#varchar_id" = t1."#varchar_id"
            AND t2.cluster_name  = 'fixed_os'
            AND t2.tag_value     = 'iOS'
      )
),

--------------------------------------------------------------------------------
-- 3. 提取引导事件，统一 lcx_id
--------------------------------------------------------------------------------
GuideEvents AS (
    SELECT
        CASE
            WHEN v."$part_event" = 'NUU' THEN v."#account_id"
            ELSE COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id)
        END                     AS lcx_id,
        v."#event_time"         AS event_time,
        v.guide_id
    FROM ta.v_event_16 v
    INNER JOIN NewUsers nu
        ON CASE
               WHEN v."$part_event" = 'NUU' THEN v."#account_id"
               ELSE COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id)
           END = nu.lcx_id
    WHERE v."$part_date" = '2026-04-15'
      AND v."$part_event" IN ('NUU', 'role_guide_before', 'role_guide', 'force_guide')
),

--------------------------------------------------------------------------------
-- 4. 提取 509 锚点 与 1100 锚点
--------------------------------------------------------------------------------
Anchor509 AS (
    SELECT lcx_id, MIN(event_time) AS t_509
    FROM GuideEvents
    WHERE guide_id = 509
    GROUP BY 1
),

Anchor1100 AS (
    SELECT lcx_id, MAX(event_time) AS t_1100
    FROM GuideEvents
    WHERE guide_id IN (1100)
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 5. 合并并确定每个用户的时间窗口
--------------------------------------------------------------------------------
TimeWindow AS (
    SELECT
        a.lcx_id,
        a.t_509,
        COALESCE(
            b.t_1100,
            CAST(CONCAT(SUBSTRING(CAST(a.t_509 AS VARCHAR), 1, 10), ' 23:59:59') AS TIMESTAMP)
        )                       AS t_upper,
        CASE WHEN b.t_1100 IS NOT NULL THEN 'A组: 已到达1100' ELSE 'B组: 卡在509' END AS status
    FROM Anchor509 a
    LEFT JOIN Anchor1100 b ON a.lcx_id = b.lcx_id
),

--------------------------------------------------------------------------------
-- 6. 拉取该窗口期内目标事件的日志
--------------------------------------------------------------------------------
WindowLogs AS (
    SELECT
        tw.lcx_id,
        tw.status,
        tw.t_509,
        v."$part_event" AS event_name,
        v."#event_time" AS event_time
    FROM TimeWindow tw
    INNER JOIN ta.v_event_16 v
        ON CASE
               WHEN v."$part_event" = 'NUU' THEN v."#account_id"
               ELSE COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id)
           END = tw.lcx_id
        AND v."#event_time" BETWEEN tw.t_509 AND tw.t_upper
    WHERE v."$part_date" = '2026-04-15'
      AND v."$part_event" IN (
          'battle_process', 'active_finish', 'arena_ping', 'arena_fight', 
          'arena_reward', 'signin_reward', 'player_battle_udp', 'hall_into', 
          'active_shop', 'trialtask_reward', 'activitytask_reward', 'task_reward', 
          'season_reward', 'trophy_reward', 'dailywins_reward', 'email', 
          'active_gacha', 'card_levelup', 'card_talent', 'battlepass_task', 
          'battlepass_reward', 'zone_request', 'herotrial_reward', 'active_training', 
          'achieve_reward', 'heroprofic_reward', 'ladder_change', 'card_awake', 
          'battlepass_advance', 'battlepass_task_refresh', 'card_skin', 'arena_report'
      )
),

--------------------------------------------------------------------------------
-- 7. 每一个用户各自对各个事件的【首次】触发时间
--------------------------------------------------------------------------------
UserFirstEvent AS (
    SELECT
        lcx_id,
        status,
        t_509,
        event_name,
        MIN(event_time) AS first_event_time
    FROM WindowLogs
    GROUP BY 1, 2, 3, 4
),

--------------------------------------------------------------------------------
-- 8. 计算距离 509 的耗时（秒）
--------------------------------------------------------------------------------
UserTimeDiff AS (
    SELECT
        lcx_id,
        status,
        event_name,
        date_diff('second', t_509, first_event_time) AS diff_sec
    FROM UserFirstEvent
),

--------------------------------------------------------------------------------
-- 9. 各组事件的中位数聚合 (使用 APPROX_PERCENTILE)
--------------------------------------------------------------------------------
EventAgg AS (
    SELECT
        event_name,
        -- A组
        COUNT(DISTINCT CASE WHEN status = 'A组: 已到达1100' THEN lcx_id END) AS count_a,
        APPROX_PERCENTILE(CASE WHEN status = 'A组: 已到达1100' THEN diff_sec END, 0.5) AS median_sec_a,
        -- B组
        COUNT(DISTINCT CASE WHEN status = 'B组: 卡在509' THEN lcx_id END) AS count_b,
        APPROX_PERCENTILE(CASE WHEN status = 'B组: 卡在509' THEN diff_sec END, 0.5) AS median_sec_b
    FROM UserTimeDiff
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 10. 最终输出
--------------------------------------------------------------------------------
SELECT
    event_name AS "事件名",
    
    count_a AS "A组触发人数",
    COALESCE(median_sec_a, 0) AS "A组耗时中位数(秒)",
    
    count_b AS "B组触发人数",
    COALESCE(median_sec_b, 0) AS "B组耗时中位数(秒)",
    
    (COALESCE(median_sec_b, 0) - COALESCE(median_sec_a, 0)) AS "差值(B减A_秒)"
FROM EventAgg
ORDER BY count_a DESC;
