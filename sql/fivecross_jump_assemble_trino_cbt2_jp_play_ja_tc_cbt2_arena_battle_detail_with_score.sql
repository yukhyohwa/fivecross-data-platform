WITH PlayerDetails AS (
    -- 1. 从玩家战斗表提取每个 battle_id 下的玩家明细
    SELECT
        battle_id,
        CASE
            WHEN model_type = 1 THEN '休闲赛'
            WHEN model_type = 2 THEN '排位赛'
            WHEN model_type = 3 THEN '自定义'
            WHEN model_type = 5 THEN '漫斗赛'
            ELSE '其他'
        END AS model_type_name,
        CAST(COALESCE(robot_num, 0) AS INTEGER) AS robot_num,
        rank, -- 1 是胜，2 是输
        TRY_CAST(kill_num[1] AS INTEGER) AS kill_num,
        TRY_CAST(dead_num[1] AS INTEGER) AS dead_num,
        TRY_CAST(score AS DOUBLE) AS score,
        player_ladder_level,

        -- 按胜负分组，同组人按评分倒序排列分配玩家 1/2/3
        ROW_NUMBER() OVER (
            PARTITION BY battle_id, rank
            ORDER BY TRY_CAST(score AS DOUBLE) DESC
        ) AS player_idx
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-22'
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2, 3, 5)
      AND game_type IN (5)
),

BattleExtra AS (
    -- 2. 从 client_customs_pass 补局级信息；按 battle_id 去重，避免 JOIN 扇出
    SELECT
        battle_id,
        MAX("#event_time") AS customs_pass_time,
        MAX(CAST(basic.round_time AS DOUBLE)) AS round_time,
        MAX(CAST(ji_fen.has_extra_time AS VARCHAR)) AS has_extra_time,
        MAX(CAST(ji_fen.fail_camp_score AS INTEGER)) AS fail_camp_score,
        MAX(avg_trophy_list) AS avg_trophy_list
    FROM (
        SELECT
            battle_id,
            "#event_time",
            basic,
            ji_fen,

            -- 解析 player_trophy_list，计算本局平均奖杯
            reduce(
                filter(transform(player_trophy_list, x -> TRY_CAST(x AS BIGINT)), x -> x > 0),
                CAST(0 AS BIGINT),
                (s, x) -> s + x,
                s -> s
            ) * 1.0
            / NULLIF(
                cardinality(filter(transform(player_trophy_list, x -> TRY_CAST(x AS BIGINT)), x -> x > 0)),
                0
            ) AS avg_trophy_list
        FROM ta.v_event_16
        WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-22'
          AND "$part_event" = 'client_customs_pass'
          AND model_type IN (1, 2, 3, 5)
          AND game_type IN (5)
    ) s
    GROUP BY battle_id
),

SidePerspective AS (
    -- 3. 每个 battle_id 拆成胜方视角、败方视角；这样才能计算“我方/对方”积分
    SELECT DISTINCT
        battle_id,
        rank AS my_rank,
        CASE WHEN rank = 1 THEN 2 ELSE 1 END AS opponent_rank
    FROM PlayerDetails
)

-- 4. 通过 battle_id + 我方胜负视角聚合，将玩家明细行转列
SELECT
    sp.battle_id AS "battle_id",
    CASE
        WHEN sp.my_rank = 1 THEN '胜方视角'
        ELSE '败方视角'
    END AS "视角",
    MAX(my_side.model_type_name) AS "模式",
    CASE
        WHEN MAX(my_side.robot_num) >= 1 THEN '机器人对手'
        ELSE '真实对手'
    END AS "AI匹配真人",
    MAX(my_side.robot_num) AS "机器人数",
    CASE
        WHEN LOWER(MAX(be.has_extra_time)) IN ('true', '1') THEN '是'
        WHEN LOWER(MAX(be.has_extra_time)) IN ('false', '0') THEN '否'
        ELSE MAX(be.has_extra_time)
    END AS "是否加时",
    MAX(be.round_time) AS "回合时长",
    MAX(be.customs_pass_time) AS "结算时间",
    ROUND(AVG(CAST(my_side.player_ladder_level AS DOUBLE)), 0) AS "段位",
    ROUND(MAX(be.avg_trophy_list), 0) AS "平均奖杯",

    CASE WHEN sp.my_rank = 1 THEN 10 ELSE MAX(be.fail_camp_score) END AS "我方积分",
    CASE WHEN sp.my_rank = 1 THEN MAX(be.fail_camp_score) ELSE 10 END AS "对方积分",

    -- 我方玩家数据
    MAX(CASE WHEN my_side.player_idx = 1 THEN my_side.kill_num END) AS "我方玩家1击杀",
    MAX(CASE WHEN my_side.player_idx = 1 THEN my_side.dead_num END) AS "我方玩家1死亡",
    MAX(CASE WHEN my_side.player_idx = 1 THEN my_side.score END) AS "我方玩家1评分",

    MAX(CASE WHEN my_side.player_idx = 2 THEN my_side.kill_num END) AS "我方玩家2击杀",
    MAX(CASE WHEN my_side.player_idx = 2 THEN my_side.dead_num END) AS "我方玩家2死亡",
    MAX(CASE WHEN my_side.player_idx = 2 THEN my_side.score END) AS "我方玩家2评分",

    MAX(CASE WHEN my_side.player_idx = 3 THEN my_side.kill_num END) AS "我方玩家3击杀",
    MAX(CASE WHEN my_side.player_idx = 3 THEN my_side.dead_num END) AS "我方玩家3死亡",
    MAX(CASE WHEN my_side.player_idx = 3 THEN my_side.score END) AS "我方玩家3评分",

    -- 对方玩家数据
    MAX(CASE WHEN opponent_side.player_idx = 1 THEN opponent_side.kill_num END) AS "对方玩家1击杀",
    MAX(CASE WHEN opponent_side.player_idx = 1 THEN opponent_side.dead_num END) AS "对方玩家1死亡",
    MAX(CASE WHEN opponent_side.player_idx = 1 THEN opponent_side.score END) AS "对方玩家1评分",

    MAX(CASE WHEN opponent_side.player_idx = 2 THEN opponent_side.kill_num END) AS "对方玩家2击杀",
    MAX(CASE WHEN opponent_side.player_idx = 2 THEN opponent_side.dead_num END) AS "对方玩家2死亡",
    MAX(CASE WHEN opponent_side.player_idx = 2 THEN opponent_side.score END) AS "对方玩家2评分",

    MAX(CASE WHEN opponent_side.player_idx = 3 THEN opponent_side.kill_num END) AS "对方玩家3击杀",
    MAX(CASE WHEN opponent_side.player_idx = 3 THEN opponent_side.dead_num END) AS "对方玩家3死亡",
    MAX(CASE WHEN opponent_side.player_idx = 3 THEN opponent_side.score END) AS "对方玩家3评分"
FROM SidePerspective sp
LEFT JOIN PlayerDetails my_side
    ON sp.battle_id = my_side.battle_id
   AND sp.my_rank = my_side.rank
LEFT JOIN PlayerDetails opponent_side
    ON sp.battle_id = opponent_side.battle_id
   AND sp.opponent_rank = opponent_side.rank
LEFT JOIN BattleExtra be
    ON sp.battle_id = be.battle_id
GROUP BY
    sp.battle_id,
    sp.my_rank
ORDER BY
    sp.battle_id,
    sp.my_rank;
