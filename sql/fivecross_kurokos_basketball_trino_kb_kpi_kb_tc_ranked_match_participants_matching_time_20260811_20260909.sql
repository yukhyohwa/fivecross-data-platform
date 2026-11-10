/*
Game: Kuroko's Basketball TC
Source: ThinkingData / Trino, ta.v_event_10
Window: 2026-08-11 through 2026-09-09 (30 completed calendar days)

Definition:
- Ranked matches: battle_result with pvp_type = 502.
- ranklevel > 0 removes bot matches.
- Participant count: distinct #user_id within each observed ranklevel.
- Average matching time: arithmetic event-level average of matching_time.
- A user can appear in multiple segments if ranklevel changed in the window.
*/
WITH ranked_match_base AS (
    SELECT
        CAST("#user_id" AS VARCHAR) AS participant_id,
        TRY_CAST(ranklevel AS BIGINT) AS rank_level,
        TRY_CAST(matching_time AS DOUBLE) AS matching_time_raw
    FROM ta.v_event_10
    WHERE "$part_date" BETWEEN '2026-08-11' AND '2026-09-09'
      AND "$part_event" = 'battle_result'
      AND TRY_CAST(pvp_type AS BIGINT) = 502
      AND TRY_CAST(ranklevel AS BIGINT) > 0
)
SELECT
    CAST(rank_level AS VARCHAR) AS "段位",
    COUNT(DISTINCT participant_id) AS "参与人数（去重）",
    COUNT(*) AS "对局事件数",
    COUNT(matching_time_raw) AS "有效匹配时长事件数",
    ROUND(AVG(matching_time_raw), 2) AS "平均匹配时长（原始字段单位）"
FROM ranked_match_base
GROUP BY 1, rank_level
ORDER BY rank_level;
