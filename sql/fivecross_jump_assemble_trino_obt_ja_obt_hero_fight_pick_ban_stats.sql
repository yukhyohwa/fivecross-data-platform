/*
================================================================================
Game    : Jump Assemble - OBT
Report  : 英雄上场使用及 Pick/Ban 率表现分布 (Hero Fight Pick/Ban & Win Rate Stats)
Description:
          - 统计各英雄的上阵次数、Pick 率、Ban 率、胜率、MVP率及战术表现（伤害、承伤、击杀等）
================================================================================
*/

WITH 
GlobalTotals AS (
    SELECT 
        ${Selector:timetype} AS date_dimension,
        COUNT(DISTINCT battle_id) AS total_battles,
        COUNT(*) AS total_player_entries
    FROM ta.v_event_23 st
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2, 3, 5)
      AND ${Selector:selector2}  
    GROUP BY 1
),

BattleProcessBans AS (
    SELECT 
        ${Selector:timetype} AS date_dimension,
        battle_id,
        TRY_CAST(ban_hero_id AS INTEGER) AS ban_hero_id
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
      AND "$part_event" = 'battle_process'
      AND log_type = 7
      AND model_type IN (1, 2, 3, 5)
    GROUP BY 1, 2, 3
),

ExplodedFightData AS (
    SELECT 
        ${Selector:timetype} AS date_dimension,
        rolecommon.role_id AS role_id,
        TRY_CAST(player_ladder_level AS INTEGER) AS player_ladder_level,
        battle_id,
        game_type,
        CASE 
            WHEN model_type IN (1) THEN '休闲赛' 
            WHEN model_type IN (2) THEN '排位赛' 
            WHEN model_type IN (5) THEN '漫斗赛' 
            WHEN model_type IN (3) THEN '自选赛' 
        END AS model_type,
        rank,
        mvp,
        t.h_id AS hero_id,
        CAST(t.dmg AS DOUBLE) AS b_damage,
        CAST(t.kl AS DOUBLE) AS b_kill,
        CAST(t.dd AS DOUBLE) AS b_death,
        CAST(t.tk AS DOUBLE) AS b_takedamage,
        CAST(t.an AS DOUBLE) AS b_assist,
        CAST(t.sd AS DOUBLE) AS b_shielddamage,
        COALESCE(TRY_CAST(t.level AS INTEGER), 0) AS level,
        score,
        COALESCE(
            cardinality(
                filter(
                    split(regexp_replace(CAST(t.raw_talent AS VARCHAR), '[\[\]"\s]', ''), ','),
                    x -> TRY_CAST(x AS INTEGER) > 0
                )
            ),
            0
        ) AS talent_count,
        COALESCE(
            cardinality(
                filter(
                    split(regexp_replace(CAST(t.raw_awake AS VARCHAR), '[\[\]"\s]', ''), ','),
                    x -> TRY_CAST(x AS INTEGER) > 0
                )
            ),
            0
        ) AS awaken_count
    FROM ta.v_event_23 st
    CROSS JOIN UNNEST(
        hero_id_list, damage, kill_num, dead_num, takedamage, hero_level, card_awake, card_super_slot, assist_num, ShieldDamage
    ) AS t(h_id, dmg, kl, dd, tk, level, raw_awake, raw_talent, an, sd)
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2, 3, 5)
      AND ${Selector:selector2}  
),

CalculatedData AS (
    SELECT 
        *,
        CASE 
            WHEN (game_type IN (1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16) AND rank = 1)
              OR (game_type = 2 AND rank <= 4)
              OR (game_type = 3 AND rank <= 2)
            THEN 1 ELSE 0 
        END AS is_win
    FROM ExplodedFightData
    WHERE hero_id IS NOT NULL AND hero_id <> ''
),

HeroBans AS (
    SELECT
        st.date_dimension,
        b.ban_hero_id,
        COUNT(DISTINCT st.battle_id) AS ban_count
    FROM CalculatedData st
    INNER JOIN BattleProcessBans b
        ON st.date_dimension = b.date_dimension
        AND st.battle_id = b.battle_id
    WHERE st.level ${Number:level} 
      AND st.talent_count ${Number:talent_count}
      AND st.awaken_count ${Number:awaken_count}
      AND st.player_ladder_level ${Number:player_ladder}
    GROUP BY 1, 2
)

SELECT 
    st.date_dimension AS "时间维度",
    ${Selector:model_type} AS "模式类型",
    ${Selector:gamename}  AS "玩法名称",
    st.hero_id AS "英雄ID",
    "hero_id_list@card_name" AS "英雄名称",
    regexp_replace(regexp_replace('${Number:level}', '(?i)BETWEEN\s+', ''), '\s+(?i)AND\s+', ' - ') AS "英雄等级",
    regexp_replace(regexp_replace('${Number:talent_count}', '(?i)BETWEEN\s+', ''), '\s+(?i)AND\s+', ' - ') AS "天赋数",
    regexp_replace(regexp_replace('${Number:awaken_count}', '(?i)BETWEEN\s+', ''), '\s+(?i)AND\s+', ' - ') AS "觉醒数",
    regexp_replace(regexp_replace('${Number:player_ladder}', '(?i)BETWEEN\s+', ''), '\s+(?i)AND\s+', ' - ') AS "玩家段位",
     
    COUNT(*) AS "上阵次数", 
    COUNT(DISTINCT st.role_id) AS "上阵用户数",

    CAST(COUNT(DISTINCT st.battle_id) AS DOUBLE) / NULLIF(MAX(t2.total_battles), 0) AS "上阵率",
    CAST(COUNT(*) AS DOUBLE) / NULLIF(MAX(t2.total_player_entries), 0) AS "Pick率",
    
    MAX(COALESCE(hb.ban_count, 0)) AS "Ban次数",
    CAST(MAX(COALESCE(hb.ban_count, 0)) AS DOUBLE) / NULLIF(MAX(t2.total_battles), 0) AS "Ban率",
    
    CAST(SUM(st.is_win) AS DOUBLE) / NULLIF(COUNT(*), 0) AS "胜率",

    COUNT_IF(st.mvp = true) AS "MVP次数",
    CAST(COUNT_IF(st.mvp = true) AS DOUBLE) / NULLIF(COUNT(*), 0) AS "MVP率",

    AVG(st.b_damage) AS "平均伤害",
    AVG(st.b_kill) AS "平均击杀",
    SUM(st.b_damage) / NULLIF(SUM(st.b_kill), 0) AS "平均伤害/击杀", 
    AVG(st.b_takedamage) AS "平均承伤",
    AVG(st.b_death) AS "平均死亡",
    SUM(st.b_takedamage) / NULLIF(SUM(st.b_death), 0) AS "平均承伤/死亡", 
    AVG(st.b_assist) AS "平均助攻",
    AVG(st.b_shielddamage) AS "平均护盾承伤",

    AVG(st.rank) AS "平均排名",
    AVG(st.score)/1000 AS "平均评分"

FROM CalculatedData st
JOIN GlobalTotals t2 ON st.date_dimension = t2.date_dimension 
LEFT JOIN HeroBans hb ON st.date_dimension = hb.date_dimension 
                     AND CAST(st.hero_id AS INTEGER) = CAST(hb.ban_hero_id AS INTEGER)
                     
LEFT JOIN ta_dim.dim_16_0_24160 dim_gt ON st.game_type = dim_gt."game_type@game_type"
LEFT JOIN ta_dim.dim_16_0_24863 dim_cn ON CAST(st.hero_id AS INTEGER) = CAST(dim_cn."hero_id_list@card_id" AS INTEGER) 

WHERE st.level ${Number:level} 
  AND st.talent_count ${Number:talent_count}
  AND st.awaken_count ${Number:awaken_count}
  AND player_ladder_level ${Number:player_ladder}

GROUP BY 1, 2, 3, 4, 5;
