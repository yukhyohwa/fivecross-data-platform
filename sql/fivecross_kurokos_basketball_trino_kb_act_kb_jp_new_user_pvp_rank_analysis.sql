WITH new_users AS (
    -- 1. 获取选定时间段内的新增用户
    SELECT *
    FROM (
        SELECT DISTINCT uuid, MIN("$part_date") "$part_date"
        FROM ta.v_event_9
        WHERE "$part_date">='2023-11-15'
          AND "$part_event" = 'new_role'
        GROUP BY 1
    )
    WHERE ${PartDate:date1} 
),

user_info AS (
    -- 2. 获取这些用户的最新昵称
    SELECT uuid, gid, nickname
    FROM (
        SELECT 
            uuid, gid, COALESCE("new_name", "role_name") AS nickname,
            ROW_NUMBER() OVER(PARTITION BY uuid, gid ORDER BY "$part_date" DESC, "#event_time" DESC) as rank
        FROM ta.v_event_9
        WHERE ${PartDate:date1} 
          AND "$part_event" IN ('change_name','new_role')
          AND ("role_name" IS NOT NULL OR "new_name" IS NOT NULL)
    )
    WHERE rank = 1 
),
user_matches AS (
    -- 3. 获取新手前 50 场对局
    SELECT 
        uuid, gid, pvp_session, target_id_list,
        ROW_NUMBER() OVER(PARTITION BY uuid, gid ORDER BY "#event_time" ASC) as match_num
    FROM ta.v_event_9
    WHERE "$part_event" = 'battle_result'
      AND CAST(pvp_type AS BIGINT) = 502
      AND target_id_list IS NOT NULL
      -- 这里的 date2 应该是一个比 date1 更宽泛的范围，比如接下来两个月，保证能覆盖这批人打完50场
      AND ${PartDate:date1} 
      AND uuid IN (SELECT uuid FROM new_users)
),
filtered_matches AS (
    -- 只取前50场
    SELECT * FROM user_matches WHERE match_num <= 50
),
match_opponents AS (
    -- 4. 关联对局中的对手并获取其当场对局的最高段位
    SELECT WITH new_users AS (
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

match_opponents AS (
    -- 5. 匹配每一场 target_id_list 中的真实玩家
    -- 并取该场对手中的最高 rank
    SELECT
        b.uuid,
        b.gid,
        b.pvp_session,
        b.match_num,

        MAX(
            CASE
                WHEN p.realplayer = true
                THEN CAST(p.rank AS BIGINT)
                ELSE 0
            END
        ) AS max_opp_rank

    FROM filtered_matches b

    LEFT JOIN ta.v_event_9 p
      ON p."$part_event" = 'player_activity'

     -- 502 模式
     AND CAST(p.type AS BIGINT) = 502

     -- 同一场 session
     AND p.session = b.pvp_session

     -- player_activity 也必须使用对局观察窗口
     AND ${PartDate:date2}

     -- 核心修复：
     -- p.gid 原始类型直接转 varchar 会变成科学计数法
     -- 例如 102381736 -> 1.02381736E8
     -- 所以先转 BIGINT，再转 VARCHAR
     AND contains(
         b.target_id_list,
         CAST(CAST(p.gid AS BIGINT) AS VARCHAR)
     )

    GROUP BY
        b.uuid,
        b.gid,
        b.pvp_session,
        b.match_num
)

-- 6. 将前 50 场横向展开
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
    match_1;
        b.uuid, b.gid, b.pvp_session, b.match_num,
        MAX(CASE WHEN p.realplayer = true THEN CAST(p.rank AS BIGINT) ELSE 0 END) as max_opp_rank
    FROM filtered_matches b
    LEFT JOIN ta.v_event_9 p 
      ON p."$part_event" = 'player_activity' 
     AND CAST(p.type AS BIGINT) = 502
     AND p.session = b.pvp_session
     AND ${PartDate:date1}
     AND (contains(b.target_id_list, CAST(p.gid AS VARCHAR)) OR contains(b.target_id_list, '"' || CAST(p.gid AS VARCHAR) || '"'))
    GROUP BY b.uuid, b.gid, b.pvp_session, b.match_num
)
-- 5. 聚合输出结果：将 50 场透视为列
SELECT 
    i.uuid AS fc_id,
    i.gid AS role_id,
    i.nickname,
    MAX(CASE WHEN m.match_num = 1 THEN m.max_opp_rank END) AS match_1,
    MAX(CASE WHEN m.match_num = 2 THEN m.max_opp_rank END) AS match_2,
    MAX(CASE WHEN m.match_num = 3 THEN m.max_opp_rank END) AS match_3,
    MAX(CASE WHEN m.match_num = 4 THEN m.max_opp_rank END) AS match_4,
    MAX(CASE WHEN m.match_num = 5 THEN m.max_opp_rank END) AS match_5,
    MAX(CASE WHEN m.match_num = 6 THEN m.max_opp_rank END) AS match_6,
    MAX(CASE WHEN m.match_num = 7 THEN m.max_opp_rank END) AS match_7,
    MAX(CASE WHEN m.match_num = 8 THEN m.max_opp_rank END) AS match_8,
    MAX(CASE WHEN m.match_num = 9 THEN m.max_opp_rank END) AS match_9,
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
LEFT JOIN match_opponents m ON i.uuid = m.uuid AND i.gid = m.gid
GROUP BY 
    i.uuid,
    i.gid,
    i.nickname
ORDER BY i.uuid;
