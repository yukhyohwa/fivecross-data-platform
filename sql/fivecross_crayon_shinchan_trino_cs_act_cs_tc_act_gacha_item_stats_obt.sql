/*
蜡笔小新繁中 App18 OBT｜抽卡道具产出。
日期：${PartDate:date}；时间粒度：${Selector:timetype}（D/W/M/S/A）。
按 fc_id 合并多角色；排除 OBT Windows、内部、水号；不查注册历史。
先汇总奖励列表，再关联按 ID 去重的维表，避免维表重复放大数量。
产出总量沿用原口径：奖励列表中每个元素计 1，同 ID 重复元素保留。
这不是 a_rst 的实际获得数量；若列表包含碎片 ID，不自动换算成完整伙伴。
技能/伙伴按对应列表读取，空列表可回退另一列表；影像保留原双列表取法。
影像的独立奖励字段尚未确认：若双列表都为空，不会产生影像明细，不猜测字段。
URL:https://ss-web.5xgames.com/#/tga/ide/18_4761?fromPanel=18_913
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
        CASE v."$part_event"
            WHEN 'skill_get' THEN '技能抽卡'
            WHEN 'Companion_get' THEN '伙伴抽卡'
            WHEN 'movie_get' THEN '影像抽卡'
        END AS gacha_type,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CASE
            WHEN v."$part_event" = 'skill_get' THEN
                CASE WHEN CARDINALITY(v.skill_list) > 0 THEN v.skill_list ELSE v.companion_list END
            ELSE
                CASE WHEN CARDINALITY(v.companion_list) > 0 THEN v.companion_list ELSE v.skill_list END
        END AS reward_items
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" IN ('skill_get', 'Companion_get', 'movie_get')
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),
ItemCounts AS (
    SELECT
        e.time_dimension,
        e.gacha_type,
        u.item AS item_id,
        COUNT(*) AS output_count,
        COUNT(DISTINCT e.fc_id) AS user_count
    FROM EventRows e
    CROSS JOIN UNNEST(e.reward_items) AS u(item)
    WHERE u.item IS NOT NULL
    GROUP BY 1, 2, 3
),
ItemDim AS (
    SELECT
        TRY_CAST("item_id@item_id" AS BIGINT) AS item_id,
        ARBITRARY(ROW("item_id@item_type", "item_id@item_name")) AS attributes
    FROM ta_dim.dim_18_0_52781
    GROUP BY 1
),
FriendDim AS (
    SELECT
        TRY_CAST("friend.role_id@friend_id" AS BIGINT) AS item_id,
        ARBITRARY(ROW("friend.role_id@quality", "friend.role_id@quality_name")) AS attributes
    FROM ta_dim.dim_18_0_53443
    GROUP BY 1
)
SELECT
    c.time_dimension AS "时间维度",
    c.gacha_type AS "抽卡类型",
    d.attributes[1] AS "道具类型",
    c.item_id AS "道具ID",
    d.attributes[2] AS "道具名称",
    f.attributes[1] AS "friend.role_id@quality",
    f.attributes[2] AS "friend.role_id@quality_name",
    c.output_count AS "产出总量",
    c.user_count AS "获得人数"
FROM ItemCounts c
LEFT JOIN ItemDim d ON TRY_CAST(c.item_id AS BIGINT) = d.item_id
LEFT JOIN FriendDim f ON TRY_CAST(c.item_id AS BIGINT) = f.item_id
ORDER BY c.time_dimension DESC, c.gacha_type, c.output_count DESC;
