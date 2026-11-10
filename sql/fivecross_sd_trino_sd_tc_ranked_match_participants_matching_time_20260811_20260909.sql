/*
Game: Slam Dunk TC
Source: ThinkingData / Trino, ta.v_event_20
Window: 2026-08-11 through 2026-09-09 (30 completed calendar days)

Definition:
- Ranked-match source: match_fight with team_array[1] IS NOT NULL.
- TC's current match_fight.star_str is empty. Extract the pre-match star value
  from the migrated a_rst JSON entry where obj = 'comm#star'.
- Participant count: distinct #user_id within each observed pre-match tier.
- Average matching time: arithmetic event-level average of matching_time_str.
- A user can appear in multiple tiers if their stars changed in the window.
*/
WITH match_base AS (
    SELECT
        CAST(m."#user_id" AS VARCHAR) AS participant_id,
        TRY_CAST(json_extract_scalar(json_parse(t.item_str), '$.before') AS BIGINT) AS star_before,
        TRY_CAST(m.matching_time_str AS DOUBLE) AS matching_time_raw
    FROM ta.v_event_20 m
    CROSS JOIN UNNEST(
        filter(m.a_rst, x -> x IS NOT NULL AND x <> '')
    ) AS t(item_str)
    WHERE m."$part_date" BETWEEN '2026-08-11' AND '2026-09-09'
      AND m."$part_event" = 'match_fight'
      AND m."team_array"[1] IS NOT NULL
      AND m."#user_id" IS NOT NULL
      AND json_extract_scalar(json_parse(t.item_str), '$.obj') = 'comm#star'
),
ranked_match_base AS (
    SELECT
        participant_id,
        matching_time_raw,
        CASE
            WHEN star_before < 16 THEN '入部新秀 (0-15)'
            WHEN star_before < 32 THEN '强力替补 (16-31)'
            WHEN star_before < 52 THEN '最佳正选 (32-51)'
            WHEN star_before < 72 THEN '绝对主力 (52-71)'
            WHEN star_before < 96 THEN '超级明星 (72-95)'
            WHEN star_before < 120 THEN '最强王牌 (96-119)'
            WHEN star_before < 150 THEN '传奇巨星 (120-149)'
            WHEN star_before < 170 THEN '殿堂王者 (150-169)'
            ELSE '灌篮高手 (170+)'
        END AS rank_segment,
        CASE
            WHEN star_before < 16 THEN 1
            WHEN star_before < 32 THEN 2
            WHEN star_before < 52 THEN 3
            WHEN star_before < 72 THEN 4
            WHEN star_before < 96 THEN 5
            WHEN star_before < 120 THEN 6
            WHEN star_before < 150 THEN 7
            WHEN star_before < 170 THEN 8
            ELSE 9
        END AS rank_sort
    FROM match_base
    WHERE star_before IS NOT NULL
)
SELECT
    rank_segment AS "段位",
    COUNT(DISTINCT participant_id) AS "参与人数（去重）",
    COUNT(*) AS "对局事件数",
    COUNT(matching_time_raw) AS "有效匹配时长事件数",
    ROUND(AVG(matching_time_raw), 2) AS "平均匹配时长（原始字段单位）"
FROM ranked_match_base
GROUP BY 1, rank_sort
ORDER BY rank_sort;
