/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 「偏向漫斗赛」用户 D+0段位 × D+2流失 × D+1战斗表现（滚动5日 Cohort）

分析逻辑 (D+0 / D+1 / D+2):
  D+0  注册日：确定用户群体、取漫斗赛段位、判断玩法偏好
  D+1  行为日：漫斗赛 / 积分赛战斗数据
  D+2  流失日：当天有无任何事件日志

覆盖的5个 Cohort:
  D+0        D+1(数据)   D+2(流失判断)
  2026-04-15  2026-04-16  2026-04-17
  2026-04-16  2026-04-17  2026-04-18
  2026-04-17  2026-04-18  2026-04-19
  2026-04-18  2026-04-19  2026-04-20
  2026-04-19  2026-04-20  2026-04-21

筛选逻辑:
  - 4/15 注册新用户（已剔除内部与灌水黑名单）
  - D+0 当天有 arena_fight 记录
  - 偏好判定：D+0 漫斗赛最终段位 > 排位赛最终段位

维度分组:
  1. 注册日 (reg_date)
  2. D+0 漫斗赛段位
  3. D+2 流失状态

指标 (D+1 当天):
  - 漫斗赛：总场次、人均场次、AI场次、AI场占比(%)、胜率(%)
  - 积分赛 (model_type=5, game_type=5)：总场次、人均场次
  - 积分赛大比分领先AI胜局（赢 & robot_num>=1 & 对方<=4分即领先>=6分）：总数、人均
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 0. 日期参数表：定义5个 Cohort 的 D+0 / D+1 / D+2
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
-- 2. 各日期注册的新用户（去除黑名单），携带 D+0/D+1/D+2 日期
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
-- 3. 取 D+0 每个用户在两种模式下最后一次段位（用于判断偏好 & 段位维度）
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
            CAST(v.model_type AS INTEGER)          AS model_type,
            CAST(v.player_ladder_level AS INTEGER) AS player_ladder_level,
            ROW_NUMBER() OVER (
                PARTITION BY nu.lcx_id, nu.reg_date, v.model_type
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM NewUsers nu
        INNER JOIN ta.v_event_16 v
            ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = nu.lcx_id
        WHERE v."$part_date" = nu.reg_date
          AND v."$part_event" = 'arena_fight'
          AND v.player_ladder_level IS NOT NULL
          AND CAST(v.model_type AS INTEGER) IN (2, 5)
    ) sub
    WHERE rn = 1
    GROUP BY sub.reg_date, sub.fight_date, sub.churn_date, sub.lcx_id
),

--------------------------------------------------------------------------------
-- 4. 筛选「偏向漫斗赛」用户，携带 D+0 段位 & 日期信息
--------------------------------------------------------------------------------
MandouUsers AS (
    SELECT
        reg_date,
        fight_date,
        churn_date,
        lcx_id,
        mandou_ladder AS ladder_d0   -- D+0 漫斗赛最终段位
    FROM FightUsers_Raw
    WHERE mandou_ladder > ranked_ladder
),

--------------------------------------------------------------------------------
-- 5. 读取积分赛输家得分（D+1，按 fight_date & battle_id 去重防扇出）
--------------------------------------------------------------------------------
LoserScore AS (
    SELECT
        v."$part_date"  AS fight_date,
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
-- 6. D+1 漫斗赛战斗明细，关联 LoserScore 取分数
--------------------------------------------------------------------------------
FightDetail AS (
    SELECT
        mu.reg_date,
        mu.lcx_id,
        CASE WHEN CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1 THEN 1 ELSE 0 END   AS is_robot,
        CASE WHEN CAST(COALESCE(v.game_type, 0) AS INTEGER) = 5 THEN 1 ELSE 0 END    AS is_arena,
        CASE WHEN CAST(v.rank AS INTEGER) = 1 THEN 1 ELSE 0 END                       AS is_win,
        -- 大比分领先AI胜局：赢 + AI + 积分赛 + 对方<=4分（领先>=6分）
        CASE
            WHEN CAST(v.rank AS INTEGER) = 1
             AND CAST(COALESCE(v.robot_num, 0) AS INTEGER) >= 1
             AND CAST(COALESCE(v.game_type, 0) AS INTEGER) = 5
             AND COALESCE(ls.fail_camp_score, 10) <= 4
            THEN 1 ELSE 0
        END AS is_blowout_ai_win
    FROM MandouUsers mu
    INNER JOIN ta.v_event_16 v
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = mu.lcx_id
    LEFT JOIN LoserScore ls
        ON v."$part_date" = ls.fight_date
       AND v.battle_id    = ls.battle_id
    WHERE v."$part_date"  = mu.fight_date
      AND v."$part_event" = 'arena_fight'
      AND CAST(v.model_type AS INTEGER) = 5
),

--------------------------------------------------------------------------------
-- 7. 按用户 & 注册日汇总 D+1 战斗指标
--------------------------------------------------------------------------------
UserFight AS (
    SELECT
        reg_date,
        lcx_id,
        COUNT(*)               AS mandou_total_fights,
        SUM(is_robot)          AS mandou_robot_fights,
        SUM(is_win)            AS mandou_wins,
        SUM(is_arena)          AS arena_fights,
        SUM(is_blowout_ai_win) AS blowout_ai_wins
    FROM FightDetail
    GROUP BY reg_date, lcx_id
),

--------------------------------------------------------------------------------
-- 8. D+2 留存记录（D+2 有任何日志 = 未流失）
--------------------------------------------------------------------------------
Retention AS (
    SELECT DISTINCT
        mu.reg_date,
        COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) AS lcx_id
    FROM MandouUsers mu
    INNER JOIN ta.v_event_16 v
        ON COALESCE(json_extract_scalar(v.fc_sdk_common, '$.lcx_id'), v.sdkcommon.lcx_id) = mu.lcx_id
    WHERE v."$part_date" = mu.churn_date
)

--------------------------------------------------------------------------------
-- 9. 最终聚合：按「D+0段位 × D+2流失状态」汇总（5个 cohort 合并）
--------------------------------------------------------------------------------
SELECT
    mu.ladder_d0                                                              AS "D+0 漫斗赛段位",
    CASE WHEN r.lcx_id IS NOT NULL THEN '未流失(D+2有活跃)'
         ELSE '已流失(D+2无活跃)' END                                         AS "D+2 流失状态",

    COUNT(DISTINCT mu.lcx_id)                                                 AS "用户数",

    -- D+1 漫斗赛整体
    SUM(COALESCE(uf.mandou_total_fights, 0))                                  AS "漫斗赛总场次",
    ROUND(CAST(SUM(COALESCE(uf.mandou_total_fights, 0)) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT mu.lcx_id), 0), 2)                            AS "漫斗赛人均场次",
    SUM(COALESCE(uf.mandou_robot_fights, 0))                                  AS "漫斗赛AI场次",
    ROUND(CAST(SUM(COALESCE(uf.mandou_robot_fights, 0)) AS DOUBLE)
        / NULLIF(SUM(COALESCE(uf.mandou_total_fights, 0)), 0) * 100, 2)       AS "AI场占比(%)",
    ROUND(CAST(SUM(COALESCE(uf.mandou_wins, 0)) AS DOUBLE)
        / NULLIF(SUM(COALESCE(uf.mandou_total_fights, 0)), 0) * 100, 2)       AS "漫斗赛胜率(%)",

    -- D+1 积分赛
    SUM(COALESCE(uf.arena_fights, 0))                                         AS "积分赛总场次",
    ROUND(CAST(SUM(COALESCE(uf.arena_fights, 0)) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT mu.lcx_id), 0), 2)                            AS "人均积分赛场次",

    -- D+1 积分赛大比分领先AI胜局
    SUM(COALESCE(uf.blowout_ai_wins, 0))                                      AS "积分赛大比分领先AI胜局数",
    ROUND(CAST(SUM(COALESCE(uf.blowout_ai_wins, 0)) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT mu.lcx_id), 0), 2)                            AS "人均大比分领先AI胜局"

FROM MandouUsers mu
LEFT JOIN Retention r  ON mu.reg_date = r.reg_date AND mu.lcx_id = r.lcx_id
LEFT JOIN UserFight uf ON mu.reg_date = uf.reg_date AND mu.lcx_id = uf.lcx_id
GROUP BY 1, 2
ORDER BY 1 ASC, 2 DESC;

