-- ================================================================================
-- Report  : Slam Dunk TC — Card Talent vs Win Rate
-- Game    : Slam Dunk TC (g23002013)
-- Metrics : Per card × talent tier × rank — win, lose, total, win rate, holders
-- Mode    : RankH3V3 only
-- Engine  : MaxCompute (ODPS)
-- Date    : 20260423  (change as needed)
-- Notes   :
--   Talent tiers : 0~29% / 30~59% / 60~99% / 100%
--   Rank         : MAPJOIN(dim_rank) + WHERE range filter
--   Win rate     : win sessions / total sessions, min 50 sessions filter
-- ================================================================================

WITH

ActiveUsers AS (
    SELECT DISTINCT mbga_uid, user_id
    FROM g23002013.daily_user_snapshot
    WHERE day = 20260423
),

CardTalent AS (
    SELECT
        c.mbga_uid,
        c.user_id,
        c.card_id,
        COUNT(CASE WHEN LENGTH(skill1) BETWEEN 4 AND 6 THEN skill1 END) AS skill_nodes
    FROM g23002013.daily_user_card_snapshot c
    LATERAL VIEW EXPLODE(SPLIT(skill, ',|\\[|\\]')) a_tar AS skill1
    WHERE day    = 20260423
      AND status = 1
    GROUP BY c.mbga_uid, c.user_id, c.card_id
),

CardTalentTier AS (
    SELECT
        ct.mbga_uid,
        ct.user_id,
        ct.card_id,
        dc.name                                                         AS card_name,
        CASE
            WHEN t.talent IS NULL OR t.talent = 0       THEN '0~29%'
            WHEN ct.skill_nodes * 1.0 / t.talent < 0.3 THEN '0~29%'
            WHEN ct.skill_nodes * 1.0 / t.talent < 0.6 THEN '30~59%'
            WHEN ct.skill_nodes * 1.0 / t.talent < 1.0 THEN '60~99%'
            ELSE                                             '100%'
        END                                                             AS talent_tier
    FROM CardTalent ct
    INNER JOIN ActiveUsers au
        ON ct.mbga_uid = au.mbga_uid AND ct.user_id = au.user_id
    LEFT JOIN g23002013.tmp_card_talent t  ON ct.card_id = t.card_id
    LEFT JOIN g23002013.dim_card        dc ON ct.card_id = dc.id
),

MatchWithRank AS (
    SELECT /*+ MAPJOIN(d) */
        m.session,
        m.mbga_uid,
        m.user_id,
        GET_JSON_OBJECT(m.player, '$.player') AS card_id,
        m.result,
        CAST(SPLIT(m.star, '#')[0] AS INT)    AS star,
        d.rank_name
    FROM g23002013.daily_match_snapshot m
    JOIN g23002013.dim_rank d ON 1 = 1
    WHERE m.day  = 20260423
      AND m.type = 'RankH3V3'
      AND m.ai   = 'false'
      AND CAST(SPLIT(m.star, '#')[0] AS INT) >= d.min_star
      AND CAST(SPLIT(m.star, '#')[0] AS INT) <= d.max_star
)

SELECT
    mr.card_id                                                          AS "球员ID",
    ct.card_name                                                        AS "球员名称",
    ct.talent_tier                                                      AS "天赋进度",
    mr.rank_name                                                        AS "段位",
    COUNT(DISTINCT CASE WHEN mr.result = 'true'  THEN mr.session END)  AS "胜场",
    COUNT(DISTINCT CASE WHEN mr.result = 'false' THEN mr.session END)  AS "败场",
    COUNT(DISTINCT mr.session)                                          AS "总场次",
    ROUND(
        COUNT(DISTINCT CASE WHEN mr.result = 'true' THEN mr.session END) * 1.0
        / NULLIF(COUNT(DISTINCT mr.session), 0)
    , 4)                                                                AS "胜率",
    COUNT(DISTINCT CONCAT(CAST(mr.mbga_uid AS STRING), '_',
                          CAST(mr.user_id  AS STRING)))                 AS "持有人数"
FROM MatchWithRank mr
LEFT JOIN CardTalentTier ct
    ON mr.mbga_uid = ct.mbga_uid
   AND mr.user_id  = ct.user_id
   AND mr.card_id  = ct.card_id
WHERE ct.talent_tier IS NOT NULL
GROUP BY mr.card_id, ct.card_name, ct.talent_tier, mr.rank_name
HAVING COUNT(DISTINCT mr.session) >= 50
ORDER BY ct.card_name ASC, ct.talent_tier ASC, mr.rank_name ASC;
