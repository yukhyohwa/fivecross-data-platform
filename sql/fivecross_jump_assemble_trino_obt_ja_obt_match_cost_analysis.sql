/*
================================================================================
Game    : Jump Assemble - OBT
Report  : 各类比赛匹配时长分析 (Match Duration & Cost Analysis)
Description:
          - match_cost 来自 battle_process
          - 通过 battle_id 关联 arena_fight 获取模式 / 玩法维度
          - 统计：平均匹配时长、匹配时长中位数、2分钟以上占比
          - arena_fight 先压成 battle 粒度，避免一场比赛多玩家记录导致重复计算
================================================================================
*/

WITH
BattleBase AS (
    SELECT
        ${Selector:timetype} AS date_dimension,
        battle_id,
        MAX(game_type) AS game_type,
        MAX(model_type) AS model_type,

        CASE
            WHEN MAX(model_type) = 1 THEN '休闲赛'
            WHEN MAX(model_type) = 2 THEN '排位赛'
            WHEN MAX(model_type) = 5 THEN '漫斗赛'
            WHEN MAX(model_type) = 3 THEN '自选赛'
            ELSE CAST(MAX(model_type) AS VARCHAR)
        END AS model_type_name

    FROM ta.v_event_23
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2, 5)
      AND battle_id IS NOT NULL
      AND ${Selector:selector2}
    GROUP BY 1, 2
),

MatchCostBase AS (
    SELECT
        battle_id,
        MAX(TRY_CAST(match_cost AS DOUBLE)) AS match_cost
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
      AND "$part_event" = 'battle_process'
      AND model_type IN (1, 2, 3, 5)
      AND battle_id IS NOT NULL
      AND match_cost IS NOT NULL
      AND TRY_CAST(match_cost AS DOUBLE) >= 0
    GROUP BY 1
),

FinalBattle AS (
    SELECT
        b.date_dimension,
        b.battle_id,
        b.game_type,
        b.model_type,
        b.model_type_name,
        m.match_cost,
        m.match_cost AS match_cost_sec
    FROM BattleBase b
    INNER JOIN MatchCostBase m
        ON b.battle_id = m.battle_id
)

SELECT
    date_dimension AS "时间维度",
    ${Selector:model_type} AS "模式类型",
    ${Selector:gamename} AS "玩法名称",

    COUNT(DISTINCT battle_id) AS "比赛场次",

    AVG(match_cost_sec) AS "平均匹配时长_秒",
    AVG(match_cost_sec) / 60.0 AS "平均匹配时长_分钟",

    approx_percentile(match_cost_sec, 0.5) AS "匹配时长中位数_秒",
    approx_percentile(match_cost_sec, 0.5) / 60.0 AS "匹配时长中位数_分钟",

    COUNT_IF(match_cost_sec >= 120) AS "2分钟以上场次",
    CAST(COUNT_IF(match_cost_sec >= 120) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT battle_id), 0) AS "2分钟以上占比",

    COUNT_IF(match_cost_sec >= 180) AS "3分钟以上场次",
    CAST(COUNT_IF(match_cost_sec >= 180) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT battle_id), 0) AS "3分钟以上占比",

    MAX(match_cost_sec) AS "最大匹配时长_秒"

FROM FinalBattle fb

LEFT JOIN ta_dim.dim_16_0_24160 dim_gt
    ON fb.game_type = dim_gt."game_type@game_type"

GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
