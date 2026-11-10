/*
限时伙伴 / 坐骑核心道具获得数量分布。每个活动一行，仅输出 7 列。
日期参数：v.${PartDate:date1}；同 fc_id 多角色合并。
伙伴只保留机器犬小白（兼容“機器犬小白”），坐骑按活动名称第二段匹配核心奖励。
累计的是所选日期内实际获得的道具数量，不是抽奖次数或奖励数组行数。
优先使用正数 diff，否则使用正数 after-before；数量无法确认时不按 1 个猜测。
OBT 自 2026-10-14 起，排除黑名单及活动 ID=0，保留首次创角后的事件。
*/
WITH
ReportRange AS (
    SELECT MAX(CAST(v."$part_date" AS DATE)) AS end_date
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'active_reward'
),
Blacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_windows_new', 'is_water_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
Registration AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        MIN(CAST(v."#event_time" AS TIMESTAMP)) AS reg_time
    FROM ta.v_event_18 v
    CROSS JOIN ReportRange r
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" BETWEEN '2026-10-14' AND CAST(r.end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),
RawLogs AS (
    SELECT
        TRY_CAST(v.type AS BIGINT) AS activity_type,
        CAST(TRY_CAST(v.id AS DECIMAL(38, 0)) AS VARCHAR) AS activity_id,
        TRIM(COALESCE(TRY(SPLIT(CAST(v.name AS VARCHAR), '-')[2]),
                      CAST(v.name AS VARCHAR))) AS activity_name,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        v.a_rst
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'active_reward'
      AND TRY_CAST(v.type AS BIGINT) IN (1117, 1116)
      AND TRY_CAST(v.id AS DECIMAL(38, 0)) <> 0
),
ActivityLogs AS (
    SELECT *
    FROM RawLogs
    WHERE activity_type = 1116
       OR (activity_type = 1117
           AND activity_name IN ('机器犬小白', '機器犬小白'))
),
Activities AS (
    SELECT activity_type, activity_id,
           MAX_BY(activity_name, event_time) AS activity_name
    FROM ActivityLogs
    GROUP BY 1, 2
),
RewardQuantities AS (
    SELECT
        g.activity_type, g.activity_id, g.fc_id,
        CASE
            WHEN TRY_CAST(u.item_diff AS DECIMAL(38, 0)) > 0
                THEN TRY_CAST(u.item_diff AS DECIMAL(38, 0))
            WHEN TRY_CAST(u.item_after AS DECIMAL(38, 0))
                 - TRY_CAST(u.item_before AS DECIMAL(38, 0)) > 0
                THEN TRY_CAST(u.item_after AS DECIMAL(38, 0))
                     - TRY_CAST(u.item_before AS DECIMAL(38, 0))
        END AS obtained_qty
    FROM ActivityLogs g
    JOIN Registration r ON g.fc_id = r.fc_id AND g.event_time >= r.reg_time
    LEFT JOIN Blacklist b ON g.fc_id = b.fc_id
    CROSS JOIN UNNEST(g.a_rst) AS u(
        item_after, item_before, item_diff, item_id, item_key, item_name
    )
    WHERE b.fc_id IS NULL
      AND REPLACE(TRIM(CAST(u.item_name AS VARCHAR)), '機', '机')
          = REPLACE(g.activity_name, '機', '机')
),
UserQuantities AS (
    SELECT activity_type, activity_id, fc_id, SUM(obtained_qty) AS total_qty
    FROM RewardQuantities
    WHERE obtained_qty > 0
    GROUP BY 1, 2, 3
)
SELECT
    a.activity_id AS "活动ID",
    a.activity_name AS "活动名称",
    COUNT_IF(u.total_qty = 1) AS "获得1个人数",
    COUNT_IF(u.total_qty = 2) AS "获得2个人数",
    COUNT_IF(u.total_qty = 3) AS "获得3个人数",
    COUNT_IF(u.total_qty = 4) AS "获得4个人数",
    COUNT_IF(u.total_qty >= 5) AS "获得5个及以上人数"
FROM Activities a
LEFT JOIN UserQuantities u
  ON a.activity_type = u.activity_type AND a.activity_id = u.activity_id
GROUP BY a.activity_type, a.activity_id, a.activity_name
ORDER BY a.activity_type DESC, a.activity_id;
