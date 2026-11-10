/*
蜡笔小新繁中 OBT｜晶钻（10206）每日平均持仓。
时间直接使用 v.${PartDate:date1}，不扫描日志求日期边界，不读取注册历史。
仅统计所选日期、OBT 开始后 item_change 中的晶钻余额。
每日每个 fc_id 取最后一条晶钻记录的 after；同账号多角色合并为最后记录，非角色余额求和。
黑名单使用 #varchar_id，排除 is_water_new/is_windows_new/internal_users_new。
平均值分母为当天存在有效余额的账号，不是全服账号；未变动账号不补齐历史余额。
同一账号相同事件时间若存在不同余额，缺少事件序号时无法确定先后。
晶钻余额除以 100；输出字段名称、顺序不变。
*/
WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new', 'internal_users_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
ItemEvents AS (
    SELECT
        v."$part_date" AS part_date,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        FILTER(v.a_rst, x -> TRY_CAST(x.id AS BIGINT) = 10206) AS gem_changes
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'item_change'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),
LatestState AS (
    SELECT
        e.part_date,
        e.fc_id,
        MAX_BY(u.balance, e.event_time) AS balance
    FROM ItemEvents e
    CROSS JOIN UNNEST(
        TRANSFORM(e.gem_changes, x -> TRY_CAST(x.after AS BIGINT))
    ) AS u(balance)
    GROUP BY 1, 2
)
SELECT
    part_date AS "日期",
    AVG(balance) / 100.0 AS "平均晶钻持仓"
FROM LatestState
GROUP BY 1
ORDER BY 1 DESC;
