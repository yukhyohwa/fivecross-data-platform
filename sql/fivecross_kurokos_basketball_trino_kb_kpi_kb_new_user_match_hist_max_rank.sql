/*
================================================================================
Description: 新增用户前50场比赛对手历史最高段位统计
================================================================================
*/

WITH new_users AS (
    -- 1. 获取选定时间段内的新增用户
    SELECT
        uuid,
        "$part_date"
    FROM (
        SELECT
            uuid,
            MIN("$part_date") AS "$part_date"
        FROM ta.v_event_9
        WHERE "$part_date" >= '2023-11-15'
          AND "$part_event" = 'new_role'
        GROUP BY uuid
    )
    WHERE ${PartDate:date1}
),

user_info AS (
    -- 2. 获取这些新增用户的最新角色信息 / 昵称
    SELECT
        uuid,
        gid,
        nickname
    FROM (
        SELECT
            uuid,
            gid,
            COALESCE("new_name", "role_name") AS nickname,
            ROW_NUMBER() OVER (
                PARTITION BY uuid, gid
                ORDER BY "$part_date" DESC, "#event_time" DESC
            ) AS rn
        FROM ta.v_event_9
        WHERE "$part_event" IN ('change_name', 'new_role')
          AND ("role_name" IS NOT NULL OR "new_name" IS NOT NULL)
          AND uuid IN (
              SELECT uuid
              FROM new_users
          )
          -- 如果希望拿到新增后更晚发生的改名，可以用 date2
          AND ${PartDate:date2}
    )
    WHERE rn = 1
),

user_matches AS (
    -- 3. 获取这些新增用户的 502 模式对局
    SELECT
        uuid,
        gid,
        pvp_session,
        target_id_list,
        "#event_time",
        ROW_NUMBER() OVER (
            PARTITION BY uuid, gid
            ORDER BY "#event_time" ASC
        ) AS match_num
    FROM ta.v_event_9
    WHERE "$part_event" = 'battle_result'
      AND CAST(pvp_type AS BIGINT) = 502
      AND target_id_list IS NOT NULL
      AND uuid IN (
          SELECT uuid
          FROM new_users
      )
      -- 对局观察窗口要比新增用户时间宽
      AND ${PartDate:date2}
),

filtered_matches AS (
    -- 4. 只保留前 50 场
    SELECT
        uuid,
        gid,
        pvp_session,
        target_id_list,
        match_num
    FROM user_matches
    WHERE match_num <= 50
),

match_opponents_base AS (
    -- 5. 首先提取每场 target_id_list 中的真实玩家对应的 gid
    -- 通过 session 关联确切找出该场比赛中的对手
    SELECT
        b.uuid,
        b.gid,
        b.pvp_session,
        b.match_num,
        CAST(CAST(p.gid AS BIGINT) AS VARCHAR) AS opp_gid
    FROM filtered_matches b
    JOIN ta.v_event_9 p
      ON p."$part_event" = 'player_activity'
     AND CAST(p.type AS BIGINT) = 502
     AND p.session = b.pvp_session
     AND ${PartDate:date2}
     AND p.realplayer = true
     AND contains(
         b.target_id_list,
         CAST(CAST(p.gid AS BIGINT) AS VARCHAR)
     )
),

opp_hist_rank AS (
    -- 6. 获取这批对手的历史最高 rank
    -- 注意：这里会去查整个 player_activity 历史记录来找最高段位，
    -- 如果底层 ta.v_user_9 表有类似 hist_max_rank 的用户属性字段，建议直接连用户表会更快
    SELECT 
        o.opp_gid,
        MAX(CAST(p.rank AS BIGINT)) AS max_hist_rank
    FROM (SELECT DISTINCT opp_gid FROM match_opponents_base) o
    JOIN ta.v_event_9 p
      ON p."$part_event" = 'player_activity'
     AND CAST(p.type AS BIGINT) = 502
     AND p.realplayer = true
     AND CAST(CAST(p.gid AS BIGINT) AS VARCHAR) = o.opp_gid
    GROUP BY o.opp_gid
),

match_opponents AS (
    -- 7. 聚合每场对局中所有对手的历史最高 rank
    SELECT 
        m.uuid,
        m.gid,
        m.pvp_session,
        m.match_num,
        MAX(COALESCE(r.max_hist_rank, 0)) AS max_opp_rank
    FROM match_opponents_base m
    LEFT JOIN opp_hist_rank r ON m.opp_gid = r.opp_gid
    GROUP BY 
        m.uuid,
        m.gid,
        m.pvp_session,
        m.match_num
)

-- 8. 将前 50 场横向展开
SELECT
    i.uuid AS fc_id,
    i.gid AS role_id,
    i.nickname,

    MAX(CASE WHEN m.match_num = 1  THEN m.max_opp_rank END) AS match_1,
    MAX(CASE WHEN m.match_num = 2  THEN m.max_opp_rank END) AS match_2,
    MAX(CASE WHEN m.match_num = 3  THEN m.max_opp_rank END) AS match_3,
    MAX(CASE WHEN m.match_num = 4  THEN m.max_opp_rank END) AS match_4,
    MAX(CASE WHEN m.match_num = 5  THEN m.max_opp_rank END) AS match_5,
    MAX(CASE WHEN m.match_num = 6  THEN m.max_opp_rank END) AS match_6,
    MAX(CASE WHEN m.match_num = 7  THEN m.max_opp_rank END) AS match_7,
    MAX(CASE WHEN m.match_num = 8  THEN m.max_opp_rank END) AS match_8,
    MAX(CASE WHEN m.match_num = 9  THEN m.max_opp_rank END) AS match_9,
    MAX(CASE WHEN m.match_num = 10 THEN m.max_opp_rank END) AS match_10,

    MAX(CASE WHEN m.match_num = 11 THEN m.max_opp_rank END) AS match_11,
    MAX(CASE WHEN m.match_num = 12 THEN m.max_opp_rank END) AS match_12,
    MAX(CASE WHEN m.match_num = 13 THEN m.max_opp_rank END) AS match_13,
    MAX(CASE WHEN m.match_num = 14 THEN m.max_opp_rank END) AS match_14,
    MAX(CASE WHEN m.match_num = 15 THEN m.max_opp_rank END) AS match_15,
    MAX(CASE WHEN m.match_num = 16 THEN m.max_opp_rank END) AS match_16,
    MAX(CASE WHEN m.match_num = 17 THEN m.max_opp_rank END) AS match_17,
    MAX(CASE WHEN m.match_num = 18 THEN m.max_opp_rank END) AS match_18,
    MAX(CASE WHEN m.match_num = 19 THEN m.max_opp_rank END) AS match_19,
    MAX(CASE WHEN m.match_num = 20 THEN m.max_opp_rank END) AS match_20,

    MAX(CASE WHEN m.match_num = 21 THEN m.max_opp_rank END) AS match_21,
    MAX(CASE WHEN m.match_num = 22 THEN m.max_opp_rank END) AS match_22,
    MAX(CASE WHEN m.match_num = 23 THEN m.max_opp_rank END) AS match_23,
    MAX(CASE WHEN m.match_num = 24 THEN m.max_opp_rank END) AS match_24,
    MAX(CASE WHEN m.match_num = 25 THEN m.max_opp_rank END) AS match_25,
    MAX(CASE WHEN m.match_num = 26 THEN m.max_opp_rank END) AS match_26,
    MAX(CASE WHEN m.match_num = 27 THEN m.max_opp_rank END) AS match_27,
    MAX(CASE WHEN m.match_num = 28 THEN m.max_opp_rank END) AS match_28,
    MAX(CASE WHEN m.match_num = 29 THEN m.max_opp_rank END) AS match_29,
    MAX(CASE WHEN m.match_num = 30 THEN m.max_opp_rank END) AS match_30,

    MAX(CASE WHEN m.match_num = 31 THEN m.max_opp_rank END) AS match_31,
    MAX(CASE WHEN m.match_num = 32 THEN m.max_opp_rank END) AS match_32,
    MAX(CASE WHEN m.match_num = 33 THEN m.max_opp_rank END) AS match_33,
    MAX(CASE WHEN m.match_num = 34 THEN m.max_opp_rank END) AS match_34,
    MAX(CASE WHEN m.match_num = 35 THEN m.max_opp_rank END) AS match_35,
    MAX(CASE WHEN m.match_num = 36 THEN m.max_opp_rank END) AS match_36,
    MAX(CASE WHEN m.match_num = 37 THEN m.max_opp_rank END) AS match_37,
    MAX(CASE WHEN m.match_num = 38 THEN m.max_opp_rank END) AS match_38,
    MAX(CASE WHEN m.match_num = 39 THEN m.max_opp_rank END) AS match_39,
    MAX(CASE WHEN m.match_num = 40 THEN m.max_opp_rank END) AS match_40,

    MAX(CASE WHEN m.match_num = 41 THEN m.max_opp_rank END) AS match_41,
    MAX(CASE WHEN m.match_num = 42 THEN m.max_opp_rank END) AS match_42,
    MAX(CASE WHEN m.match_num = 43 THEN m.max_opp_rank END) AS match_43,
    MAX(CASE WHEN m.match_num = 44 THEN m.max_opp_rank END) AS match_44,
    MAX(CASE WHEN m.match_num = 45 THEN m.max_opp_rank END) AS match_45,
    MAX(CASE WHEN m.match_num = 46 THEN m.max_opp_rank END) AS match_46,
    MAX(CASE WHEN m.match_num = 47 THEN m.max_opp_rank END) AS match_47,
    MAX(CASE WHEN m.match_num = 48 THEN m.max_opp_rank END) AS match_48,
    MAX(CASE WHEN m.match_num = 49 THEN m.max_opp_rank END) AS match_49,
    MAX(CASE WHEN m.match_num = 50 THEN m.max_opp_rank END) AS match_50

FROM user_info i

LEFT JOIN match_opponents m
  ON i.uuid = m.uuid
 AND i.gid = m.gid

GROUP BY
    i.uuid,
    i.gid,
    i.nickname

ORDER BY
    match_1 DESC,match_2 DESC, match_3 DESC, match_4 DESC, match_5 DESC, match_6 DESC, match_7 DESC, match_8 DESC, match_9 DESC, match_10 DESC, 
    match_11 DESC,match_12 DESC, match_13 DESC, match_14 DESC, match_15 DESC, match_16 DESC, match_17 DESC, match_18 DESC, match_19 DESC, match_20 DESC,
    match_21 DESC,match_22 DESC, match_23 DESC, match_24 DESC, match_25 DESC, match_26 DESC, match_27 DESC, match_28 DESC, match_29 DESC, match_30 DESC,
    match_31 DESC,match_32 DESC, match_33 DESC, match_34 DESC, match_35 DESC, match_36 DESC, match_37 DESC, match_38 DESC, match_39 DESC, match_40 DESC,
    match_41 DESC,match_42 DESC, match_43 DESC, match_44 DESC, match_45 DESC, match_46 DESC, match_47 DESC, match_48 DESC, match_49 DESC, match_50 DESC
