/*
================================================================================
Game    : Jump Assemble (众星之聚)
Region  : TC (Traditional Chinese - TW/HK/MO)
Report  : CBT1 首日 vs CBT2 首日 — 各玩法参与热度对比
Tag     : ja_tc  cbt1  cbt2

对比日期：
  · CBT1 首日：2025-11-25
  · CBT2 首日：2026-04-15（仅 iOS 用户）
  · CBT2 次日：2026-04-16（针对 4/15 留存用户, 仅 iOS 用户）

OS 过滤逻辑：
  · CBT1（2025-11-25）：不限 OS
  · CBT2（2026-04-15/16）：fixed_os = 'iOS'

统计维度：
  · 汇总行（全部玩法）：各日参与次数 & 参与人数
  · 分玩法行：各 game_type 的参与次数 & 参与人数
  · 不区分机器人 / 真人对手
  · model_type IN (1, 2, 3)

Environment: Trino (TA) — v_event_16  表编号 16
================================================================================
*/

WITH

-- ──────────────────────────────────────────────────────────────
-- 1. 黑名单用户（排除内部 / 水军）
-- ──────────────────────────────────────────────────────────────
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- ──────────────────────────────────────────────────────────────
-- 2. 用户 OS 标签（通过 lcxsdkcommon.lcx_id 关联）
-- ──────────────────────────────────────────────────────────────
UserProfile AS (
    SELECT
        "#varchar_id"                                                               AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END)           AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END)           AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END)           AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END)           AS fixed_store
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store')
    GROUP BY "#varchar_id"
),

-- ──────────────────────────────────────────────────────────────
-- 3. 提取 2026-04-15 的用户群 (用于 4/16 的对比)
-- ──────────────────────────────────────────────────────────────
CBT2_Day1_Users AS (
    SELECT DISTINCT "#account_id"
    FROM ta.v_event_16
    WHERE "$part_date" = '2026-04-15'
      AND "$part_event" = 'arena_fight'
),

-- ──────────────────────────────────────────────────────────────
-- 4. 提取各时段日志
--    · CBT1（2025-11-25）：全量
--    · CBT2（2026-04-15）：全量 (iOS)
--    · CBT2（2026-04-16）：仅限 4/15 已活跃的用户 (iOS)
-- ──────────────────────────────────────────────────────────────
FightLogs AS (
    SELECT
        v."$part_date"                                                              AS log_date,
        v."#account_id"                                                             AS account_id,
        v."#event_time"                                                             AS event_time,
        v.game_type                                                                 AS game_type_id,
        CASE
            WHEN v.game_type = 1  THEN '卷轴争夺'
            WHEN v.game_type = 2  THEN '单人乱斗'
            WHEN v.game_type = 3  THEN '双人乱斗'
            WHEN v.game_type = 4  THEN '武道会'
            WHEN v.game_type = 5  THEN '积分争夺'
            WHEN v.game_type = 7  THEN '咒术高专'
            WHEN v.game_type = 9  THEN '顶上战争'
            WHEN v.game_type = 10 THEN '无限列车'
            WHEN v.game_type = 11 THEN '淘汰赛'
            WHEN v.game_type = 12 THEN '忍界大战'
            WHEN v.game_type = 15 THEN '龙珠之争'
            ELSE                       '其他'
        END                                                                         AS game_type_name,
        up.fixed_os
    FROM ta.v_event_16 v
    -- 关联 OS 标签
    LEFT JOIN UserProfile up ON COALESCE(v.lcxsdkcommon.lcx_id, v.sdkcommon.lcx_id) = up.lcx_id
    LEFT JOIN UserBlacklist bl ON v."#account_id" = bl."#account_id"
    -- 4/16 需要关联 Day1 用户池
    LEFT JOIN CBT2_Day1_Users d1 ON v."#account_id" = d1."#account_id"
    
    WHERE bl."#account_id" IS NULL
      AND v."$part_event" = 'arena_fight'
      AND v."$part_date" IN ('2025-11-25', '2026-04-15', '2026-04-16')
      AND v.model_type IN (1, 2, 3)
      AND v.game_type IN (1, 2, 3, 4, 5, 7, 9, 10, 11, 12, 13)
      AND (
          (v."$part_date" = '2025-11-25') -- CBT1 首日，不限 OS
          OR
          (v."$part_date" = '2026-04-15' AND up.fixed_os = 'iOS') -- CBT2 首日
          OR
          (v."$part_date" = '2026-04-16' AND up.fixed_os = 'iOS' AND d1."#account_id" IS NOT NULL) -- 4/15 用户在 4/16 的表现
      )
)

-- ══════════════════════════════════════════════════════════════
-- 输出：按玩法横向对比，两个日期的指标并排展示
-- ══════════════════════════════════════════════════════════════

-- 汇总行（全部玩法合计） UNION 分玩法明细，再做横向 PIVOT
SELECT
    game_type_name                                                                          AS "玩法",

    -- CBT1（2025-11-25 Android）
    COUNT(DISTINCT CASE WHEN log_date = '2025-11-25'
        THEN CAST(account_id AS VARCHAR) || CAST(event_time AS VARCHAR) END)                AS "参与次数（2025-11-25）",
    COUNT(DISTINCT CASE WHEN log_date = '2025-11-25' THEN account_id END)                   AS "参与人数（2025-11-25）",
    ROUND(
        CAST(COUNT(DISTINCT CASE WHEN log_date = '2025-11-25'
            THEN CAST(account_id AS VARCHAR) || CAST(event_time AS VARCHAR) END) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT CASE WHEN log_date = '2025-11-25' THEN account_id END), 0)
    , 2)                                                                                    AS "人均参与次数（2025-11-25）",

    -- CBT2 Day 1（2026-04-15 iOS）
    COUNT(DISTINCT CASE WHEN log_date = '2026-04-15'
        THEN CAST(account_id AS VARCHAR) || CAST(event_time AS VARCHAR) END)                AS "参与次数（04-15）",
    COUNT(DISTINCT CASE WHEN log_date = '2026-04-15' THEN account_id END)                   AS "人数（04-15）",

    -- CBT2 Day 2（2026-04-16 iOS, 仅限 04-15 留存用户）
    COUNT(DISTINCT CASE WHEN log_date = '2026-04-16'
        THEN CAST(account_id AS VARCHAR) || CAST(event_time AS VARCHAR) END)                AS "参与次数（04-16）",
    COUNT(DISTINCT CASE WHEN log_date = '2026-04-16' THEN account_id END)                   AS "人数（04-16）",

    -- 人均对比 (04-15 vs 04-16)
    ROUND(
        CAST(COUNT(DISTINCT CASE WHEN log_date = '2026-04-15'
            THEN CAST(account_id AS VARCHAR) || CAST(event_time AS VARCHAR) END) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT CASE WHEN log_date = '2026-04-15' THEN account_id END), 0)
    , 2)                                                                                    AS "04-15人均",
    ROUND(
        CAST(COUNT(DISTINCT CASE WHEN log_date = '2026-04-16'
            THEN CAST(account_id AS VARCHAR) || CAST(event_time AS VARCHAR) END) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT CASE WHEN log_date = '2026-04-16' THEN account_id END), 0)
    , 2)                                                                                    AS "04-16人均"

FROM (
    -- 分玩法行
    SELECT log_date, account_id, event_time, game_type_name FROM FightLogs

    UNION ALL

    -- 汇总行（全部玩法合计）
    SELECT log_date, account_id, event_time, '【全部玩法汇总】' AS game_type_name FROM FightLogs
)
GROUP BY 1
ORDER BY
    CASE game_type_name WHEN '【全部玩法汇总】' THEN 0 ELSE 1 END,
    game_type_name ASC;
