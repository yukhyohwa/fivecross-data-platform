/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 排位赛对局平衡与机器人审计
Description:
  以 battle_id 还原排位赛两边队伍，量化：
  1. 对手平均段位/全员段位高于我方的比例；
  2. 含机器人的对局占比、机器人局胜率；
  3. 各段位玩家接触机器人的差异。

  说明：arena_fight 目前没有检索到“预组队人数/队伍 ID”字段，因此本报表不能
  可靠判定单排、双排或三排。请在取得组队/房间事件及 party_id 后，将其按
  battle_id + lcx_id 关联到 PlayerFight，再按 party_size 分组即可验证该问题。
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- 每位真实玩家在每局中的一条排位结算记录
PlayerFight AS (
    SELECT
        v."$part_date" AS fight_date,
        v.battle_id,
        CAST(v.game_type AS INTEGER) AS game_type,
        COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id) AS lcx_id,
        CAST(v.rank AS INTEGER) AS side_rank, -- 1 胜方；2 负方
        CAST(v.player_ladder_level AS INTEGER) AS ladder_level,
        CAST(COALESCE(v.robot_num, 0) AS INTEGER) AS robot_num
    FROM ta.v_event_23 v
    LEFT JOIN UserBlacklist ub
      ON COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id) = ub.lcx_id
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'arena_fight'
      AND CAST(v.model_type AS INTEGER) = 2
      -- 排位赛玩法清单；这些玩法 rank=1 为胜方、rank=2 为负方。
      AND CAST(v.game_type AS INTEGER) IN (1, 5, 7, 8, 9, 11, 15)
      AND v.battle_id IS NOT NULL
      AND CAST(v.rank AS INTEGER) IN (1, 2)
      AND v.player_ladder_level IS NOT NULL
      AND ub.lcx_id IS NULL
),

-- 以胜负阵营聚合；而非按单个玩家比较，避免把队友段位误算成对手。
SideSummary AS (
    SELECT
        fight_date,
        battle_id,
        game_type,
        side_rank,
        COUNT(DISTINCT lcx_id) AS real_player_cnt,
        AVG(CAST(ladder_level AS DOUBLE)) AS side_avg_ladder,
        MIN(ladder_level) AS side_min_ladder,
        MAX(ladder_level) AS side_max_ladder,
        MAX(robot_num) AS robot_num
    FROM PlayerFight
    GROUP BY 1, 2, 3, 4
),

-- 同一 battle_id 的另一胜负阵营即为对手。
-- 必须保留对方全为机器人的局：这类局没有对方真人的 arena_fight，因此 o 方为空。
SideVsOpponent AS (
    SELECT
        s.fight_date,
        s.battle_id,
        s.game_type,
        s.side_rank,
        s.real_player_cnt,
        s.side_avg_ladder,
        s.side_min_ladder,
        s.side_max_ladder,
        s.robot_num,
        o.side_avg_ladder AS opponent_avg_ladder,
        o.side_min_ladder AS opponent_min_ladder,
        o.side_max_ladder AS opponent_max_ladder,
        CASE WHEN o.battle_id IS NOT NULL THEN 1 ELSE 0 END AS has_opponent_side,
        CASE WHEN s.side_rank = 1 THEN 1 ELSE 0 END AS is_win
    FROM SideSummary s
    LEFT JOIN SideSummary o
     ON s.fight_date = o.fight_date
     AND s.battle_id = o.battle_id
     AND s.game_type = o.game_type
     AND s.side_rank <> o.side_rank
),

-- 用我方平均段位分层；机器人数量取该局事件的最大值以应对同局玩家重复上报。
LabeledSides AS (
    SELECT
        *,
        CASE
            WHEN side_avg_ladder < 10 THEN '01-09'
            WHEN side_avg_ladder < 20 THEN '10-19'
            WHEN side_avg_ladder < 30 THEN '20-29'
            WHEN side_avg_ladder < 40 THEN '30-39'
            ELSE '40+'
        END AS own_ladder_bucket,
        CASE WHEN robot_num > 0 THEN 1 ELSE 0 END AS is_bot_match,
        -- 对方全 Bot 时没有对方真人段位，以下两个段位公平性指标置空而非当作 0%。
        CASE WHEN has_opponent_side = 1 AND opponent_avg_ladder > side_avg_ladder THEN 1
             WHEN has_opponent_side = 1 THEN 0 END AS opponent_avg_higher,
        -- 严格口径：对方最低段位仍高于我方最高段位，才算“对面全员高于我方”。
        CASE WHEN has_opponent_side = 1 AND opponent_min_ladder > side_max_ladder THEN 1
             WHEN has_opponent_side = 1 THEN 0 END AS opponent_all_higher
    FROM SideVsOpponent
)

SELECT
    fight_date AS "日期",
    game_type AS "玩法ID",
    own_ladder_bucket AS "我方平均段位分层",
    COUNT(*) AS "阵营样本数",
    COUNT(DISTINCT battle_id) AS "对局数",
    SUM(has_opponent_side) AS "有对方真人阵营样本数",
    ROUND(AVG(side_avg_ladder), 2) AS "我方平均段位",
    ROUND(AVG(opponent_avg_ladder), 2) AS "对方平均段位",
    ROUND(AVG(opponent_avg_ladder - side_avg_ladder), 2) AS "对方减我方平均段位差",
    ROUND(100.0 * AVG(opponent_avg_higher), 2) AS "对手平均段位更高占比(%)",
    ROUND(100.0 * AVG(opponent_all_higher), 2) AS "对手全员段位更高占比(%)",
    ROUND(100.0 * AVG(is_bot_match), 2) AS "含机器人对局占比(%)",
    ROUND(100.0 * AVG(CASE WHEN is_bot_match = 1 THEN is_win END), 2) AS "含机器人局胜率(%)",
    ROUND(100.0 * AVG(CASE WHEN is_bot_match = 0 AND has_opponent_side = 1 THEN is_win END), 2) AS "全真人局胜率(%)",
    ROUND(AVG(CASE WHEN is_bot_match = 1 THEN robot_num END), 2) AS "含机器人局平均机器人数量"
FROM LabeledSides
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
