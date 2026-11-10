/*
================================================================================
Game: Jump Assemble (众星之聚) - OBT
Description: 玩家常用英雄及战绩交叉统计 (行列转换 - 指定卡牌 ID 展开 - 无 LBS 分数)
             - 格式：玩家ID | 段位 | [卡牌ID]_英雄名 | [卡牌ID]_场次 | [卡牌ID]_胜率(%) | [卡牌ID]_平均伤害 | [卡牌ID]_平均承伤 | [卡牌ID]_平均护盾承伤 ...
             - 段位取值：该玩家在统计周期内的最大段位
             - 指定卡牌顺序：160, 140, 122, 156, 142, 148, 153, 143, 150, 113, 118, 109, 125, 130, 138, 123, 149, 124, 134, 127, 110, 159, 158, 145
             - 维表关联：ta_dim.dim_16_0_24863 (英雄ID映射名称)
================================================================================
*/

WITH ExplodedFightData AS (
    SELECT 
        rolecommon.role_id role_id,
        CAST(player_ladder_level AS INTEGER) player_ladder_level,
        battle_id,
        game_type,
        rank,
        t.h_id AS hero_id,
        CAST(t.dmg AS DOUBLE) AS b_damage,
        CAST(t.tk AS DOUBLE) AS b_takedamage,
        CAST(t.sd AS DOUBLE) AS b_shielddamage,
        COALESCE(CAST(t.level AS INTEGER), 0) AS level,
        COALESCE(cardinality(filter(split(t.raw_talent, ','), x -> x <> '0' AND x <> '')), 0) AS talent_count,
        COALESCE(cardinality(filter(split(t.raw_awake, ','), x -> x <> '0' AND x <> '')), 0) AS awaken_count
    FROM ta.v_event_23 st
    CROSS JOIN UNNEST(
        hero_id_list, damage, takedamage, ShieldDamage, hero_level, card_awake, card_super_slot
    ) AS t(h_id, dmg, tk, sd, level, raw_awake, raw_talent)
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2, 3, 5)
      AND ${Selector:selector2}
),

-- 过滤参数与判定胜负
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
      AND level ${Number:level}
      AND talent_count ${Number:talent_count}
      AND awaken_count ${Number:awaken_count}
      AND player_ladder_level ${Number:player_ladder}
),

-- 取玩家最大段位
UserMaxLadder AS (
    SELECT 
        role_id,
        MAX(player_ladder_level) AS max_ladder
    FROM CalculatedData
    GROUP BY 1
),

-- 统计每个玩家各英雄的数据
UserHeroAgg AS (
    SELECT 
        st.role_id,
        st.hero_id,
        COALESCE(dim_cn."hero_id_list@card_name", CAST(st.hero_id AS VARCHAR)) AS hero_name,
        COUNT(*) AS play_count,
        CAST(SUM(st.is_win) AS DOUBLE) / COUNT(*) AS win_rate,
        AVG(st.b_damage) AS avg_damage,
        AVG(st.b_takedamage) AS avg_takedamage,
        AVG(st.b_shielddamage) AS avg_shielddamage
    FROM CalculatedData st
    LEFT JOIN ta_dim.dim_16_0_24863 dim_cn ON CAST(st.hero_id AS INTEGER) = CAST(dim_cn."hero_id_list@card_id" AS INTEGER)
    GROUP BY 1, 2, 3
)

-- 行转列输出常用英雄及数据
SELECT 
    r.role_id AS "玩家ID",
    l.max_ladder AS "段位",
    
    -- Card 160
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 160 THEN r.hero_name END) AS "卡牌160_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 160 THEN r.play_count END) AS "卡牌160_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 160 THEN r.win_rate END) * 100.0, 2) AS "卡牌160_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 160 THEN r.avg_damage END), 2) AS "卡牌160_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 160 THEN r.avg_takedamage END), 2) AS "卡牌160_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 160 THEN r.avg_shielddamage END), 2) AS "卡牌160_平均护盾承伤",
    
    -- Card 140
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 140 THEN r.hero_name END) AS "卡牌140_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 140 THEN r.play_count END) AS "卡牌140_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 140 THEN r.win_rate END) * 100.0, 2) AS "卡牌140_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 140 THEN r.avg_damage END), 2) AS "卡牌140_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 140 THEN r.avg_takedamage END), 2) AS "卡牌140_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 140 THEN r.avg_shielddamage END), 2) AS "卡牌140_平均护盾承伤",
    
    -- Card 122
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 122 THEN r.hero_name END) AS "卡牌122_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 122 THEN r.play_count END) AS "卡牌122_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 122 THEN r.win_rate END) * 100.0, 2) AS "卡牌122_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 122 THEN r.avg_damage END), 2) AS "卡牌122_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 122 THEN r.avg_takedamage END), 2) AS "卡牌122_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 122 THEN r.avg_shielddamage END), 2) AS "卡牌122_平均护盾承伤",
    
    -- Card 156
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 156 THEN r.hero_name END) AS "卡牌156_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 156 THEN r.play_count END) AS "卡牌156_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 156 THEN r.win_rate END) * 100.0, 2) AS "卡牌156_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 156 THEN r.avg_damage END), 2) AS "卡牌156_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 156 THEN r.avg_takedamage END), 2) AS "卡牌156_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 156 THEN r.avg_shielddamage END), 2) AS "卡牌156_平均护盾承伤",
    
    -- Card 142
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 142 THEN r.hero_name END) AS "卡牌142_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 142 THEN r.play_count END) AS "卡牌142_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 142 THEN r.win_rate END) * 100.0, 2) AS "卡牌142_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 142 THEN r.avg_damage END), 2) AS "卡牌142_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 142 THEN r.avg_takedamage END), 2) AS "卡牌142_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 142 THEN r.avg_shielddamage END), 2) AS "卡牌142_平均护盾承伤",
    
    -- Card 148
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 148 THEN r.hero_name END) AS "卡牌148_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 148 THEN r.play_count END) AS "卡牌148_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 148 THEN r.win_rate END) * 100.0, 2) AS "卡牌148_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 148 THEN r.avg_damage END), 2) AS "卡牌148_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 148 THEN r.avg_takedamage END), 2) AS "卡牌148_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 148 THEN r.avg_shielddamage END), 2) AS "卡牌148_平均护盾承伤",
    
    -- Card 153
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 153 THEN r.hero_name END) AS "卡牌153_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 153 THEN r.play_count END) AS "卡牌153_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 153 THEN r.win_rate END) * 100.0, 2) AS "卡牌153_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 153 THEN r.avg_damage END), 2) AS "卡牌153_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 153 THEN r.avg_takedamage END), 2) AS "卡牌153_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 153 THEN r.avg_shielddamage END), 2) AS "卡牌153_平均护盾承伤",
    
    -- Card 143
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 143 THEN r.hero_name END) AS "卡牌143_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 143 THEN r.play_count END) AS "卡牌143_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 143 THEN r.win_rate END) * 100.0, 2) AS "卡牌143_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 143 THEN r.avg_damage END), 2) AS "卡牌143_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 143 THEN r.avg_takedamage END), 2) AS "卡牌143_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 143 THEN r.avg_shielddamage END), 2) AS "卡牌143_平均护盾承伤",
    
    -- Card 150
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 150 THEN r.hero_name END) AS "卡牌150_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 150 THEN r.play_count END) AS "卡牌150_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 150 THEN r.win_rate END) * 100.0, 2) AS "卡牌150_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 150 THEN r.avg_damage END), 2) AS "卡牌150_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 150 THEN r.avg_takedamage END), 2) AS "卡牌150_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 150 THEN r.avg_shielddamage END), 2) AS "卡牌150_平均护盾承伤",
    
    -- Card 113
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 113 THEN r.hero_name END) AS "卡牌113_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 113 THEN r.play_count END) AS "卡牌113_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 113 THEN r.win_rate END) * 100.0, 2) AS "卡牌113_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 113 THEN r.avg_damage END), 2) AS "卡牌113_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 113 THEN r.avg_takedamage END), 2) AS "卡牌113_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 113 THEN r.avg_shielddamage END), 2) AS "卡牌113_平均护盾承伤",
    
    -- Card 118
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 118 THEN r.hero_name END) AS "卡牌118_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 118 THEN r.play_count END) AS "卡牌118_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 118 THEN r.win_rate END) * 100.0, 2) AS "卡牌118_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 118 THEN r.avg_damage END), 2) AS "卡牌118_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 118 THEN r.avg_takedamage END), 2) AS "卡牌118_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 118 THEN r.avg_shielddamage END), 2) AS "卡牌118_平均护盾承伤",
    
    -- Card 109
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 109 THEN r.hero_name END) AS "卡牌109_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 109 THEN r.play_count END) AS "卡牌109_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 109 THEN r.win_rate END) * 100.0, 2) AS "卡牌109_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 109 THEN r.avg_damage END), 2) AS "卡牌109_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 109 THEN r.avg_takedamage END), 2) AS "卡牌109_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 109 THEN r.avg_shielddamage END), 2) AS "卡牌109_平均护盾承伤",
    
    -- Card 125
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 125 THEN r.hero_name END) AS "卡牌125_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 125 THEN r.play_count END) AS "卡牌125_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 125 THEN r.win_rate END) * 100.0, 2) AS "卡牌125_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 125 THEN r.avg_damage END), 2) AS "卡牌125_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 125 THEN r.avg_takedamage END), 2) AS "卡牌125_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 125 THEN r.avg_shielddamage END), 2) AS "卡牌125_平均护盾承伤",
    
    -- Card 130
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 130 THEN r.hero_name END) AS "卡牌130_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 130 THEN r.play_count END) AS "卡牌130_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 130 THEN r.win_rate END) * 100.0, 2) AS "卡牌130_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 130 THEN r.avg_damage END), 2) AS "卡牌130_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 130 THEN r.avg_takedamage END), 2) AS "卡牌130_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 130 THEN r.avg_shielddamage END), 2) AS "卡牌130_平均护盾承伤",
    
    -- Card 138
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 138 THEN r.hero_name END) AS "卡牌138_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 138 THEN r.play_count END) AS "卡牌138_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 138 THEN r.win_rate END) * 100.0, 2) AS "卡牌138_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 138 THEN r.avg_damage END), 2) AS "卡牌138_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 138 THEN r.avg_takedamage END), 2) AS "卡牌138_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 138 THEN r.avg_shielddamage END), 2) AS "卡牌138_平均护盾承伤",
    
    -- Card 123
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 123 THEN r.hero_name END) AS "卡牌123_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 123 THEN r.play_count END) AS "卡牌123_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 123 THEN r.win_rate END) * 100.0, 2) AS "卡牌123_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 123 THEN r.avg_damage END), 2) AS "卡牌123_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 123 THEN r.avg_takedamage END), 2) AS "卡牌123_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 123 THEN r.avg_shielddamage END), 2) AS "卡牌123_平均护盾承伤",
    
    -- Card 149
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 149 THEN r.hero_name END) AS "卡牌149_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 149 THEN r.play_count END) AS "卡牌149_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 149 THEN r.win_rate END) * 100.0, 2) AS "卡牌149_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 149 THEN r.avg_damage END), 2) AS "卡牌149_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 149 THEN r.avg_takedamage END), 2) AS "卡牌149_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 149 THEN r.avg_shielddamage END), 2) AS "卡牌149_平均护盾承伤",
    
    -- Card 124
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 124 THEN r.hero_name END) AS "卡牌124_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 124 THEN r.play_count END) AS "卡牌124_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 124 THEN r.win_rate END) * 100.0, 2) AS "卡牌124_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 124 THEN r.avg_damage END), 2) AS "卡牌124_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 124 THEN r.avg_takedamage END), 2) AS "卡牌124_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 124 THEN r.avg_shielddamage END), 2) AS "卡牌124_平均护盾承伤",
    
    -- Card 134
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 134 THEN r.hero_name END) AS "卡牌134_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 134 THEN r.play_count END) AS "卡牌134_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 134 THEN r.win_rate END) * 100.0, 2) AS "卡牌134_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 134 THEN r.avg_damage END), 2) AS "卡牌134_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 134 THEN r.avg_takedamage END), 2) AS "卡牌134_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 134 THEN r.avg_shielddamage END), 2) AS "卡牌134_平均护盾承伤",
    
    -- Card 127
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 127 THEN r.hero_name END) AS "卡牌127_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 127 THEN r.play_count END) AS "卡牌127_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 127 THEN r.win_rate END) * 100.0, 2) AS "卡牌127_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 127 THEN r.avg_damage END), 2) AS "卡牌127_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 127 THEN r.avg_takedamage END), 2) AS "卡牌127_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 127 THEN r.avg_shielddamage END), 2) AS "卡牌127_平均护盾承伤",
    
    -- Card 110
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 110 THEN r.hero_name END) AS "卡牌110_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 110 THEN r.play_count END) AS "卡牌110_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 110 THEN r.win_rate END) * 100.0, 2) AS "卡牌110_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 110 THEN r.avg_damage END), 2) AS "卡牌110_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 110 THEN r.avg_takedamage END), 2) AS "卡牌110_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 110 THEN r.avg_shielddamage END), 2) AS "卡牌110_平均护盾承伤",
    
    -- Card 159
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 159 THEN r.hero_name END) AS "卡牌159_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 159 THEN r.play_count END) AS "卡牌159_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 159 THEN r.win_rate END) * 100.0, 2) AS "卡牌159_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 159 THEN r.avg_damage END), 2) AS "卡牌159_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 159 THEN r.avg_takedamage END), 2) AS "卡牌159_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 159 THEN r.avg_shielddamage END), 2) AS "卡牌159_平均护盾承伤",
    
    -- Card 158
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 158 THEN r.hero_name END) AS "卡牌158_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 158 THEN r.play_count END) AS "卡牌158_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 158 THEN r.win_rate END) * 100.0, 2) AS "卡牌158_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 158 THEN r.avg_damage END), 2) AS "卡牌158_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 158 THEN r.avg_takedamage END), 2) AS "卡牌158_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 158 THEN r.avg_shielddamage END), 2) AS "卡牌158_平均护盾承伤",
    
    -- Card 145
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 145 THEN r.hero_name END) AS "卡牌145_英雄名",
    MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 145 THEN r.play_count END) AS "卡牌145_场次",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 145 THEN r.win_rate END) * 100.0, 2) AS "卡牌145_胜率(%)",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 145 THEN r.avg_damage END), 2) AS "卡牌145_平均伤害",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 145 THEN r.avg_takedamage END), 2) AS "卡牌145_平均承伤",
    ROUND(MAX(CASE WHEN CAST(r.hero_id AS INTEGER) = 145 THEN r.avg_shielddamage END), 2) AS "卡牌145_平均护盾承伤"
FROM UserHeroAgg r
JOIN UserMaxLadder l ON r.role_id = l.role_id
GROUP BY 1, 2
ORDER BY 2 DESC, 1 ASC;
