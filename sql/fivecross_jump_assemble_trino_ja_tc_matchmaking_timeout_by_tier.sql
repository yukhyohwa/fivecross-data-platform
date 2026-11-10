/*
排位赛（model_type=2）与漫斗赛（model_type=5）的匹配时长分布。

不按日期拆分；仅用 ${PartDate:date1} 限定扫描日期范围。
时长分桶和比例均按去重 battle_id 统计：
0-5 秒（含 5）、5-10 秒（大于 5 且含 10）、10-30 秒（大于 10 且含 30）、30 秒以上。
段位名称按 RankLevel.xlsx 的 RankLevel 映射。
*/
WITH params AS (
    SELECT
        2 AS ranked_model_type,
        5 AS brawl_model_type
),
fight AS (
    SELECT *
    FROM (
        SELECT
            v.battle_id,
            CAST(v.rolecommon.role_id AS VARCHAR) AS role_id,
            COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
            TRY_CAST(v.model_type AS INTEGER) AS model_type,
            TRY_CAST(v.player_ladder_level AS INTEGER) AS ladder_level,
            ROW_NUMBER() OVER (
                PARTITION BY v.battle_id, CAST(v.rolecommon.role_id AS VARCHAR)
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 v
        CROSS JOIN params p
        WHERE ${PartDate:date1}
          AND v."$part_event" = 'arena_fight'
          AND TRY_CAST(v.model_type AS INTEGER) IN (p.ranked_model_type, p.brawl_model_type)
    ) t
    WHERE rn = 1
),
match_cost_by_battle AS (
    SELECT
        v.battle_id,
        TRY_CAST(v.model_type AS INTEGER) AS model_type,
        MAX(TRY_CAST(v.match_cost AS DOUBLE)) AS match_seconds
    FROM ta.v_event_23 v
    CROSS JOIN params p
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'battle_process'
      AND TRY_CAST(v.model_type AS INTEGER) IN (p.ranked_model_type, p.brawl_model_type)
      AND v.battle_id IS NOT NULL
      AND v.match_cost IS NOT NULL
      AND TRY_CAST(v.match_cost AS DOUBLE) >= 0
    GROUP BY 1, 2
),
labeled AS (
    SELECT
        f.battle_id,
        f.lcx_id,
        f.model_type,
        f.ladder_level,
        mc.match_seconds,
        CASE f.model_type
            WHEN 2 THEN '排位赛'
            WHEN 5 THEN '漫斗赛'
        END AS game_type,
        CASE f.ladder_level
            WHEN 1 THEN '初战青铜Ⅲ'
            WHEN 2 THEN '初战青铜Ⅱ'
            WHEN 3 THEN '初战青铜Ⅰ'
            WHEN 4 THEN '休闲白银Ⅲ'
            WHEN 5 THEN '休闲白银Ⅱ'
            WHEN 6 THEN '休闲白银Ⅰ'
            WHEN 7 THEN '激斗黄金Ⅳ'
            WHEN 8 THEN '激斗黄金Ⅲ'
            WHEN 9 THEN '激斗黄金Ⅱ'
            WHEN 10 THEN '激斗黄金Ⅰ'
            WHEN 11 THEN '试炼铂金Ⅴ'
            WHEN 12 THEN '试炼铂金Ⅳ'
            WHEN 13 THEN '试炼铂金Ⅲ'
            WHEN 14 THEN '试炼铂金Ⅱ'
            WHEN 15 THEN '试炼铂金Ⅰ'
            WHEN 16 THEN '非凡钻石Ⅴ'
            WHEN 17 THEN '非凡钻石Ⅳ'
            WHEN 18 THEN '非凡钻石Ⅲ'
            WHEN 19 THEN '非凡钻石Ⅱ'
            WHEN 20 THEN '非凡钻石Ⅰ'
            WHEN 21 THEN '封神星耀Ⅴ'
            WHEN 22 THEN '封神星耀Ⅳ'
            WHEN 23 THEN '封神星耀Ⅲ'
            WHEN 24 THEN '封神星耀Ⅱ'
            WHEN 25 THEN '封神星耀Ⅰ'
            WHEN 26 THEN '不灭王者Ⅲ'
            WHEN 27 THEN '不灭王者Ⅱ'
            WHEN 28 THEN '不灭王者Ⅰ'
            WHEN 29 THEN '绝世王者Ⅲ'
            WHEN 30 THEN '绝世王者Ⅱ'
            WHEN 31 THEN '绝世王者Ⅰ'
            WHEN 32 THEN '巅峰王者'
            ELSE '未知段位'
        END AS ladder_name
    FROM fight f
    JOIN match_cost_by_battle mc
      ON f.battle_id = mc.battle_id
     AND f.model_type = mc.model_type
)
SELECT
    game_type AS "玩法类型",
    model_type AS "model_type",
    ladder_level AS "段位等级",
    ladder_name AS "段位名称",
    COUNT(DISTINCT battle_id) AS "对局数",
    COUNT(DISTINCT lcx_id) AS "玩家数",
    COUNT(DISTINCT CASE WHEN match_seconds <= 5 THEN battle_id END) AS "0-5秒对局数",
    COUNT(DISTINCT CASE WHEN match_seconds > 5 AND match_seconds <= 10 THEN battle_id END) AS "5-10秒对局数",
    COUNT(DISTINCT CASE WHEN match_seconds > 10 AND match_seconds <= 30 THEN battle_id END) AS "10-30秒对局数",
    COUNT(DISTINCT CASE WHEN match_seconds > 30 THEN battle_id END) AS "30秒以上对局数",
    ROUND(
        CAST(COUNT(DISTINCT CASE WHEN match_seconds > 5 THEN battle_id END) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT battle_id), 0),
        4
    ) AS "超过5秒比例",
    ROUND(
        CAST(COUNT(DISTINCT CASE WHEN match_seconds > 10 THEN battle_id END) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT battle_id), 0),
        4
    ) AS "超过10秒比例"
FROM labeled
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3;
