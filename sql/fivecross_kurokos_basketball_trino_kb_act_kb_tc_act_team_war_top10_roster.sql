/*
================================================================================
Game: Kuroko's Basketball
Region: TC (Traditional Chinese / Taiwan)
Description: Current team-war top 10 teams and their participating member roster.
URL: https://ss-web.5xgames.com/#/tga/ide/10_5111?fromPanel=10_722

Output grain: one row per member (uuid + gid) in each top-10 team.

Notes:
  - The score observation window starts on 2026-09-08 (inclusive).
  - The current match_id is inferred from the latest team_war_score event on or
    after that date.
  - Team score, team name, team membership, and individual score use the latest
    team_war_score value in the current match.
  - Nickname is looked up separately from the latest event containing new_name
    or role_name for the same uuid + gid.
  - Only members with a team_war_score event are included. Members who have not
    generated this event cannot be recovered from this event table alone.
================================================================================
*/

WITH recent_score_events AS (
    SELECT
        "#event_time" AS event_time,
        "$part_date" AS part_date,
        match_id,
        team_id,
        team_name,
        team_score,
        uuid,
        gid,
        single_score
    FROM ta.v_event_10
    WHERE "$part_event" = 'team_war_score'
      AND ${PartDate:date1}
      AND match_id IS NOT NULL
      AND team_id IS NOT NULL
),

-- Treat the match attached to the most recently reported score as the current match.
current_match AS (
    SELECT match_id
    FROM recent_score_events
    ORDER BY event_time DESC
    LIMIT 1
),

-- A team score is cumulative, so retain the team's latest reported value.
latest_team_score AS (
    SELECT
        match_id,
        team_id,
        team_name,
        team_score
    FROM (
        SELECT
            e.match_id,
            e.team_id,
            e.team_name,
            e.team_score,
            ROW_NUMBER() OVER (
                PARTITION BY e.match_id, e.team_id
                ORDER BY e.event_time DESC, e.part_date DESC
            ) AS rn
        FROM recent_score_events e
        INNER JOIN current_match c
            ON e.match_id = c.match_id
        WHERE e.team_score IS NOT NULL
    ) ranked
    WHERE rn = 1
),

top_teams AS (
    SELECT
        team_rank,
        match_id,
        team_id,
        team_name,
        team_score
    FROM (
        SELECT
            ROW_NUMBER() OVER (
                ORDER BY team_score DESC, team_id
            ) AS team_rank,
            match_id,
            team_id,
            team_name,
            team_score
        FROM latest_team_score
    ) ranked
    WHERE team_rank ${Number:number2}
),

-- Keep each player's latest team and personal score in the current match.
latest_member_score AS (
    SELECT
        match_id,
        team_id,
        uuid,
        gid,
        single_score
    FROM (
        SELECT
            e.match_id,
            e.team_id,
            e.uuid,
            e.gid,
            e.single_score,
            ROW_NUMBER() OVER (
                PARTITION BY e.match_id, e.uuid, e.gid
                ORDER BY e.event_time DESC, e.part_date DESC
            ) AS rn
        FROM recent_score_events e
        INNER JOIN current_match c
            ON e.match_id = c.match_id
        WHERE e.uuid IS NOT NULL
          AND e.gid IS NOT NULL
    ) ranked
    WHERE rn = 1
),

-- Restrict the nickname lookup to current members of the top 10 teams.
top_team_members AS (
    SELECT m.*
    FROM latest_member_score m
    INNER JOIN top_teams t
        ON m.match_id = t.match_id
       AND m.team_id = t.team_id
),

-- team_war_score may not carry a nickname; obtain the latest known nickname
-- from any TC event containing new_name or role_name.
latest_member_nickname AS (
    SELECT
        uuid,
        gid,
        nickname
    FROM (
        SELECT
            e.uuid,
            e.gid,
            NULLIF(TRIM(COALESCE(e.new_name, e.role_name)), '') AS nickname,
            ROW_NUMBER() OVER (
                PARTITION BY e.uuid, e.gid
                ORDER BY e."#event_time" DESC, e."$part_date" DESC
            ) AS rn
        FROM ta.v_event_10 e
        INNER JOIN (
            SELECT DISTINCT uuid, gid
            FROM top_team_members
        ) m
           ON e.gid = m.gid
        WHERE e."$part_date">='2026-01-01'
          AND NULLIF(TRIM(COALESCE(e.new_name, e.role_name)), '') IS NOT NULL
    ) ranked
    WHERE rn = 1
)

SELECT
    t.team_rank AS "小隊排名",
    t.team_id AS "小隊ID",
    t.team_name AS "小隊名稱",
    t.team_score AS "小隊積分",
    m.uuid AS "UUID",
    m.gid AS "GID",
    n.nickname AS "暱稱",
    m.single_score AS "個人積分"
FROM top_teams t
LEFT JOIN top_team_members m
    ON t.match_id = m.match_id
   AND t.team_id = m.team_id
LEFT JOIN latest_member_nickname n
    ON m.uuid = n.uuid
   AND m.gid = n.gid
ORDER BY
    t.team_rank,
    m.single_score DESC NULLS LAST,
    m.gid;
