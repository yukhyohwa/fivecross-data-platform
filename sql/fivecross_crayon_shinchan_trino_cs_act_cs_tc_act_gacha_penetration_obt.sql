/*
蜡笔小新繁中 App18 OBT｜技能、伙伴抽卡渗透率。
日期：${PartDate:date}；时间粒度：${Selector:timetype}（D/W/M/S/A）。
按 fc_id 合并多角色；OBT 自 2026-10-14 起，排除 OBT Windows、内部、水号。
仅扫描所选日期的 login/skill_get/Companion_get，不依赖注册时间或历史截止日。
抽卡次数累计 len；人数按发生抽卡事件的账号计数，不将缺失 len 猜成 1。
活跃人数保留原口径：login_type IN (2,3)。影像抽卡仍不纳入。
先按时间、账号聚合，再展开两种抽卡类型；日志源仅引用一次。
URL:https://ss-web.5xgames.com/#/tga/ide/18_4760?tab=result&fromPanel=18_913
*/
WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_windows_new', 'internal_users_new', 'is_water_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
EventRows AS (
    SELECT
        CASE ${Selector:timetype}
            WHEN 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN 'A' THEN '已合并'
        END AS time_dimension,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        v."$part_event" AS event_name,
        TRY_CAST(v.len AS BIGINT) AS draw_count
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" IN ('login', 'skill_get', 'Companion_get')
      AND (v."$part_event" <> 'login' OR v.login_type IN (2, 3))
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),
AccountCounts AS (
    SELECT
        time_dimension,
        fc_id,
        COUNT_IF(event_name = 'login') > 0 AS is_active,
        COUNT_IF(event_name = 'skill_get') > 0 AS has_skill_draw,
        COUNT_IF(event_name = 'Companion_get') > 0 AS has_companion_draw,
        SUM(draw_count) FILTER (WHERE event_name = 'skill_get') AS skill_draws,
        SUM(draw_count) FILTER (WHERE event_name = 'Companion_get') AS companion_draws
    FROM EventRows
    GROUP BY 1, 2
),
PeriodCounts AS (
    SELECT
        a.time_dimension,
        u.gacha_type,
        SUM(u.draws) AS total_gacha_times,
        COUNT_IF(u.has_draw) AS gacha_user_count,
        COUNT_IF(a.is_active) AS active_user_count
    FROM AccountCounts a
    CROSS JOIN UNNEST(
        ARRAY['技能抽卡', '伙伴抽卡'],
        ARRAY[a.skill_draws, a.companion_draws],
        ARRAY[a.has_skill_draw, a.has_companion_draw]
    ) AS u(gacha_type, draws, has_draw)
    GROUP BY 1, 2
    HAVING COUNT_IF(u.has_draw) > 0
)
SELECT
    time_dimension AS "时间维度",
    gacha_type AS "抽卡类型",
    total_gacha_times AS "总抽卡次数",
    gacha_user_count AS "抽卡人数",
    ROUND(CAST(total_gacha_times AS DOUBLE) / NULLIF(gacha_user_count, 0), 2) AS "人均抽卡次数",
    active_user_count AS "活跃人数",
    ROUND(CAST(gacha_user_count AS DOUBLE) / NULLIF(active_user_count, 0), 4) AS "抽卡渗透率"
FROM PeriodCounts
ORDER BY time_dimension DESC, gacha_type;
