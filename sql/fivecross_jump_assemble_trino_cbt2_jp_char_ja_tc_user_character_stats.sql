WITH 
-------------------------------------------------------
-- 1. 生成日期维表
-------------------------------------------------------
SelectedDates AS (
    SELECT DISTINCT "$part_date" 
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
),

-------------------------------------------------------
-- 2. 全局分母计算 (基于时间维度的大盘总数)
-------------------------------------------------------
GLTotals AS (
    SELECT 
        ${Selector:timetype}        date_dimension,
        COUNT(DISTINCT battle_id)   AS total_battles,
        COUNT(*)                    AS total_player_entries
    FROM ta.v_event_16 st
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2)
    GROUP BY 1
),

-------------------------------------------------------
-- 3. Ban 数据统计
-------------------------------------------------------
BanStats AS (
    SELECT
        ${Selector:timetype}            date_dimension,
        CAST(ban_hero_id AS VARCHAR)    AS hero_id,
        COUNT(*)                        AS ban_count
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
      AND "$part_event" = 'battle_process'
      AND ban_hero_id IS NOT NULL
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 4. 英雄持有数统计（计算持有率的分母）
-------------------------------------------------------
HeroHolders AS (
    SELECT 
        ${Selector:timetype}            date_dimension,
        s.card_id,
        COALESCE(s.card_level,  0)      card_level,
        COALESCE(s.awaken_count,0)      awaken_count,
        COALESCE(s.talent_count,0)      talent_count,
        COUNT(DISTINCT s.role_id)       AS total_holders
    FROM SelectedDates st
    -- 核心逻辑：将日期表与快照表关联，条件是快照日期 <= 统计日期
    JOIN (
        SELECT 
            rolecommon.role_id,
            card_id,
            "$part_date"                AS snap_date,
            card_level,
            card_awake,
            cardinality(card_awake)     AS awaken_count,
            card_talent_slot,
            cardinality(filter(card_talent_slot, x -> x <> '0' AND x <> '')) AS talent_count,
            -- 标记每个用户每张卡的记录顺序
            ROW_NUMBER() OVER (
                PARTITION BY rolecommon.role_id, card_id, "$part_date"
                ORDER BY "#event_time" DESC
            ) AS internal_rn
        FROM ta.v_event_16
        WHERE "$part_event" = 'daily_role_card_snapshot'
          AND "$part_date" BETWEEN '2025-11-25' AND (SELECT MAX("$part_date") FROM SelectedDates)
    ) s ON s.snap_date <= st."$part_date" 
    -- 只取截至 report_date 为止，该用户该卡牌的最后一条记录
    WHERE s.internal_rn = 1 
    GROUP BY 1, 2, 3, 4, 5
),

-------------------------------------------------------
-- 5. 英雄多出场数据拆分
-------------------------------------------------------
ExplodedFightData AS (
    SELECT 
        ${Selector:timetype}    date_dimension,
        rolecommon.role_id      role_id,
        player_ladder_level,
        battle_id,
        game_type,
        model_type,
        rank,
        mvp,
        t.h_id                  AS hero_id,
        CAST(t.dmg  AS DOUBLE)  AS b_damage,
        CAST(t.kl   AS DOUBLE)  AS b_kill,
        CAST(t.dd   AS DOUBLE)  AS b_death,
        CAST(t.tk   AS DOUBLE)  AS b_takedamage,
        COALESCE(CAST(level AS INTEGER), 0) level,
        score,
        COALESCE(cardinality(filter(split(t.raw_talent, ','), x -> x <> '0' AND x <> '')), 0) AS talent_count,
        COALESCE(cardinality(filter(split(t.raw_awake,  ','), x -> x <> '0' AND x <> '')), 0) AS awaken_count
    FROM ta.v_event_16 st
    CROSS JOIN UNNEST(
        hero_id_list, damage, kill_num, dead_num, takedamage, hero_level, card_awake, card_super_slot
    ) AS t(h_id, dmg, kl, dd, tk, level, raw_awake, raw_talent)
    WHERE ${PartDate:date1}
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1, 2)
      AND (robot_num <> 0 OR robot_num IS NULL)
),

-------------------------------------------------------
-- 6. 胜负判定逻辑
-------------------------------------------------------
CalculatedData AS (
    SELECT 
        *,
        CASE 
            WHEN (game_type IN (1, 4, 5, 6, 7, 8, 9, 10, 11) AND rank = 1)
              OR (game_type = 2 AND rank <= 4)
              OR (game_type = 3 AND rank <= 2)
            THEN 1 ELSE 0 
        END AS is_win,
        CASE 
            WHEN (game_type IN (1, 4, 5, 6, 7, 8, 9, 10, 11) AND rank >= 2)
              OR (game_type = 2 AND rank >= 5)
              OR (game_type = 3 AND rank >= 3)
            THEN 1 ELSE 0 
        END AS is_loss
    FROM ExplodedFightData
    WHERE hero_id IS NOT NULL AND hero_id <> ''
)

-------------------------------------------------------
-- 7. 最终聚合与持有使用率计算
-------------------------------------------------------
SELECT 
    st.date_dimension                   AS "时间维度",
    st.game_type                        AS "玩法ID",
    st.hero_id                          AS "英雄ID",
    st.level                            AS "英雄等级",
    st.talent_count                     AS "天赋数",
    st.awaken_count                     AS "觉醒数",

    -- 1. 规模指标
    COUNT(*)                            AS "上阵次数", 
    COUNT(DISTINCT st.role_id)          AS "上阵用户数",
    MAX(h.total_holders)                AS "持有用户数",

    -- 2. 核心比率
    CAST(COUNT(DISTINCT st.role_id)   AS DOUBLE) / NULLIF(MAX(h.total_holders),    0) AS "持有使用率",
    CAST(COUNT(DISTINCT st.battle_id) AS DOUBLE) / NULLIF(MAX(t2.total_battles),   0) AS "上阵率",
    CAST(MAX(COALESCE(ban.ban_count, 0)) AS DOUBLE) / NULLIF(MAX(t2.total_battles), 0) AS "Ban率",
    CAST(SUM(st.is_win)               AS DOUBLE) / NULLIF(COUNT(*),                0) AS "胜率",

    -- 3. 表现评分 (MVP)
    COUNT_IF(st.mvp = true)             AS "MVP次数",
    CAST(COUNT_IF(st.mvp = true) AS DOUBLE) / NULLIF(COUNT(*), 0) AS "MVP率",

    -- 4. 均值表现（伤害/击杀/死亡）
    AVG(st.b_damage)                    AS "平均伤害",
    AVG(st.b_kill)                      AS "平均击杀",
    SUM(st.b_damage) / NULLIF(SUM(st.b_kill),  0) AS "平均伤害/击杀",  -- 击杀贡献度
    AVG(st.b_takedamage)                AS "平均承伤",
    AVG(st.b_death)                     AS "平均死亡",
    SUM(st.b_takedamage) / NULLIF(SUM(st.b_death), 0) AS "平均承伤/死亡", -- 坦度贡献度
    AVG(st.rank)                        AS "平均排名",
    AVG(st.score) / 1000                AS "平均评分"

FROM CalculatedData st
CROSS JOIN GLTotals t2
LEFT JOIN HeroHolders h
    ON  CAST(st.hero_id      AS INTEGER) = CAST(h.card_id      AS INTEGER)
    AND CAST(st.level        AS INTEGER) = CAST(h.card_level   AS INTEGER)
    AND CAST(st.talent_count AS INTEGER) = CAST(h.talent_count AS INTEGER)
    AND CAST(st.awaken_count AS INTEGER) = CAST(h.awaken_count AS INTEGER)
    AND st.date_dimension = h.date_dimension
LEFT JOIN BanStats ban
    ON  st.hero_id        = ban.hero_id
    AND st.date_dimension = ban.date_dimension
GROUP BY 1, 2, 3, 4, 5, 6;
