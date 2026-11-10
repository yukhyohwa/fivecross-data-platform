/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 各副本与玩法参与深度及渗透率
指标：时间维度、玩法名称、参与人数、参与次数、人均参与次数、活跃/资格分母、渗透率

口径：
1. OBT 从 2026-10-14 开始；活跃、战斗和玩法参与人数均按 fc_id 去重。
2. 仅统计账号首次 OBT 创角后的事件，同账号多角色合并。
3. 黑名单使用 #varchar_id，排除 internal_users_new、is_windows_new、is_water_new。
4. shriosaving_fight 没有 fc_id，通过 #distinct_id 映射到 fc_id。
5. 其余玩法事件直接使用事件中的 fc_id。
6. stage_type=1027 为限时闯关，参与率分母改用当天最高 role_lev>=30 的去重 fc_id；其它玩法仍使用全服活跃人数。
7. 输出显式保留全服活跃、30级资格人数、实际分母人数和分母口径。
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

ReportRange AS (
    SELECT MAX(CAST(v."$part_date" AS DATE)) AS report_end_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_windows_new', 'is_water_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定每个 fc_id 的首次创角
--------------------------------------------------------------------------------
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    CROSS JOIN ReportRange r
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.report_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

EligibleAccounts AS (
    SELECT r.fc_id, r.reg_event_time
    FROM AccountRegistrationRanked r
    LEFT JOIN UserBlacklist b ON r.fc_id = b.fc_id
    WHERE r.rn = 1
      AND b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- session_id → fc_id；login/new_role 仅用于减少映射扫描量
--------------------------------------------------------------------------------
SessionAccountRanked AS (
    SELECT
        TRIM(CAST(v."#distinct_id" AS VARCHAR)) AS session_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v."#distinct_id" AS VARCHAR))
            ORDER BY v."#event_time" DESC NULLS LAST,
                     CAST(v.fc_id AS VARCHAR) DESC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    CROSS JOIN ReportRange r
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.report_end_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#distinct_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

SessionAccountMap AS (
    SELECT session_id, fc_id
    FROM SessionAccountRanked
    WHERE rn = 1
),

DimStage AS (
    SELECT * FROM (VALUES
        (1001, '主线副本'),
        (1002, '挑战玩具小偷'),
        (1003, '挑战怪物扭蛋人'),
        (1005, '守护古老城市'),
        (1004, '竞技场'),
        (1018, '挑战邪恶的兔兔玩偶'),
        (1019, '挑战邪恶喵巴士'),
        (1006, '守护海滩'),
        (1007, '恐龙拳手大挑战'),
        (1022, '花圃内pvp副本'),
        (1008, '影像副本'),
        (1023, '切磋'),
        (1009, '穿越魔法之门'),
        (1021, '积木大乱斗'),
        (1024, '跨服竞技场'),
        (1010, '宝物预览副本'),
        (1011, '忍道・甜酸试炼'),
        (1012, '冒险试炼'),
        (1013, '宠物旅行'),
        (1014, '动感超人试炼—钻地土拨鼠'),
        (1015, '动感超人试炼—挖铲土拨鼠'),
        (1016, '动感超人试炼—挖矿土拨鼠'),
        (1017, '动感超人比赛'),
        (1020, '社团大评比'),
        (1027, '限时闯关')
    ) AS t(stage_type, stage_name)
),

ActiveUsers AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        COUNT(DISTINCT p.fc_id) AS active_user_count
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN Config c
    WHERE v."$part_event" IN ('login', 'new_role', 'charge')
      AND v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
    GROUP BY 1
),

ObservedAccountLevels AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        p.fc_id,
        MAX(TRY_CAST(v.role_lev AS BIGINT)) AS max_role_level
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
    GROUP BY 1, 2
),

EligibleLevel30Users AS (
    SELECT time_dimension, COUNT(*) AS eligible_level30_users
    FROM ObservedAccountLevels
    WHERE max_role_level >= 30
    GROUP BY 1
),

StageLogs AS (
    -- 常规 stage_fight 副本
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        CAST(v.a_rst[1].key AS VARCHAR) AS stage_type,
        COUNT(1) AS fight_times,
        COUNT(DISTINCT p.fc_id) AS fight_users
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN Config c
    WHERE v."#event_name" = 'stage_fight'
      AND v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
    GROUP BY 1, 2

    UNION ALL

    -- 其它带特定 event_name 的玩法
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        CASE
            WHEN v."#event_name" = 'match3_combo' THEN '三消'
            WHEN v."#event_name" = 'pet_travel_start' THEN '宠物旅行'
            WHEN v."#event_name" = 'board_tile_land' THEN '大富翁'
        END AS stage_type,
        COUNT(1) AS fight_times,
        COUNT(DISTINCT p.fc_id) AS fight_users
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN Config c
    WHERE v."#event_name" IN ('match3_combo', 'pet_travel_start', 'board_tile_land')
      AND v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
    GROUP BY 1, 2

    UNION ALL

    -- 拯救小白：事件没有 fc_id，通过 #distinct_id 映射
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS time_dimension,
        '拯救小白' AS stage_type,
        COUNT(1) AS fight_times,
        COUNT(DISTINCT p.fc_id) AS fight_users
    FROM ta.v_event_18 v
    INNER JOIN SessionAccountMap sm
        ON TRIM(CAST(v."#distinct_id" AS VARCHAR)) = sm.session_id
    INNER JOIN EligibleAccounts p
        ON sm.fc_id = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN Config c
    WHERE v."#event_name" = 'shriosaving_fight'
      AND v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v.stage_id NOT IN (1, 2)
    GROUP BY 1, 2
)

SELECT
    s.time_dimension AS "时间维度",
    COALESCE(ds.stage_name, s.stage_type) AS "玩法名称",
    s.fight_users AS "参与人数",
    s.fight_times AS "参与次数",
    CAST(s.fight_times AS DOUBLE) / NULLIF(s.fight_users, 0) AS "人均参与次数",
    a.active_user_count AS "全服活跃人数(按区服)",
    CASE WHEN s.stage_type = '1027' THEN e.eligible_level30_users END AS "30级以上可参与人数",
    CASE WHEN s.stage_type = '1027' THEN e.eligible_level30_users ELSE a.active_user_count END AS "参与率分母人数",
    CASE WHEN s.stage_type = '1027' THEN '当天最高角色等级>=30的去重fc_id' ELSE '全服活跃去重fc_id' END AS "参与率分母口径",
    CAST(s.fight_users AS DOUBLE) /
        NULLIF(CASE WHEN s.stage_type = '1027' THEN e.eligible_level30_users ELSE a.active_user_count END, 0) AS "参与渗透率"
FROM StageLogs s
LEFT JOIN DimStage ds
    ON s.stage_type = CAST(ds.stage_type AS VARCHAR)
LEFT JOIN ActiveUsers a
    ON s.time_dimension = a.time_dimension
LEFT JOIN EligibleLevel30Users e
    ON s.time_dimension = e.time_dimension
ORDER BY 1 DESC, 2 ASC, 5 DESC;
