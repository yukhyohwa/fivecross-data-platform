/*
================================================================================
蜡笔小新繁体 OBT - 限时伙伴 / 限时坐骑抽取次数分布（fc_id 账号口径）

参数：
    日期：v.${PartDate:date}
    时间维度：${Selector:timetype}
        D      = 每日内按 fc_id 累计抽数后统计分布
        其他值 = 各活动观测周期内按 fc_id 累计抽数后统计分布

活动类型：
    1117 = 限时伙伴
    1116 = 限时坐骑

抽数口径：
    不使用 active_reward.a_rst 的元素数；相同奖励会合并，数组长度会低估抽数。
    每条晶钻原始消耗 1500（折算 15 晶钻）计 1 抽；
    每条红钻消耗 200 计 1 抽，10 条红钻消耗合计 2000 对应 10 抽。
    消耗事件分配给同 fc_id、同账号、其后 2 秒内最早的目标 active_reward。
    同一 fc_id 的多个角色合并；不要求创角记录，不按注册时间过滤。
    分布每 50 抽一档：1-50、51-100、101-150……；仅保留累计抽数大于 0 的用户。
    仅统计活动 ID 不等于 0 的记录。

活动周期：
    在所选查询范围内，按 activity_type + activity_id，取首次、末次目标
    active_reward 日期；这是实际观测窗口，不等同于配置中的正式活动起止时间。

过滤：
    日期完全由所选日期参数控制，不额外限制开服日期。
    排除 internal_users_new、is_windows_new、is_water_new 和空 fc_id。
================================================================================
*/

WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN (
        'internal_users_new',
        'is_windows_new',
        'is_water_new'
    )
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

-- 保留所选范围内目标活动的原始记录，先用于确定活动观测窗口。
RawGachaLogs AS (
    SELECT
        v."$part_date" AS stat_date,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."#te_event_id" AS VARCHAR) AS gacha_event_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        TRY_CAST(v.type AS BIGINT) AS activity_type,
        CAST(TRY_CAST(v.id AS DECIMAL(38, 0)) AS VARCHAR) AS activity_id,
        CAST(v.name AS VARCHAR) AS activity_name
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'active_reward'
      AND TRY_CAST(v.type AS BIGINT) IN (1117, 1116)
      AND TRY_CAST(v.id AS DECIMAL(38, 0)) <> DECIMAL '0'
),

ActivityWindows AS (
    SELECT
        activity_type,
        activity_id,
        MAX_BY(activity_name, event_time)
            FILTER (WHERE activity_name IS NOT NULL) AS activity_name,
        MIN(stat_date) AS activity_start_date,
        MAX(stat_date) AS activity_end_date
    FROM RawGachaLogs
    GROUP BY 1, 2
),

-- 抽卡记录排除空 fc_id 和黑名单，不关联注册记录。
EligibleGachaLogs AS (
    SELECT
        g.*,
        ROW_NUMBER() OVER (
            PARTITION BY g.fc_id
            ORDER BY g.event_time,
                     COALESCE(g.account_id, ''),
                     COALESCE(g.gacha_event_id, '')
        ) AS log_seq
    FROM RawGachaLogs g
    LEFT JOIN UserBlacklist b
      ON g.fc_id = b.fc_id
    WHERE NULLIF(g.fc_id, '') IS NOT NULL
      AND b.fc_id IS NULL
),

-- 每条合格货币消耗代表 1 抽。
CurrencySpendRowsRaw AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."#event_time" AS TIMESTAMP) AS spend_time,
        CAST(v."#te_event_id" AS VARCHAR) AS spend_event_id,
        u.spend_ordinal
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    CROSS JOIN UNNEST(v.a_rst) WITH ORDINALITY AS u(
        item_after,
        item_before,
        item_diff,
        item_id,
        item_key,
        item_name,
        spend_ordinal
    )
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'item_change'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (
          (TRY_CAST(u.item_id AS BIGINT) = 10206
           AND TRY_CAST(u.item_before AS DOUBLE) - TRY_CAST(u.item_after AS DOUBLE) = 1500.0)
          OR
          (TRY_CAST(u.item_id AS BIGINT) = 10009
           AND TRY_CAST(u.item_before AS DOUBLE) - TRY_CAST(u.item_after AS DOUBLE) = 200.0)
      )
),

CurrencySpendRows AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.fc_id
            ORDER BY s.spend_time,
                     COALESCE(s.spend_event_id, ''),
                     s.spend_ordinal
        ) AS spend_seq
    FROM CurrencySpendRowsRaw s
),

-- 每条消费只分配给其后 2 秒内最早的一条目标抽卡日志。
SpendCandidates AS (
    SELECT
        s.fc_id,
        s.spend_seq,
        g.gacha_event_id,
        g.activity_type,
        g.activity_id,
        ROW_NUMBER() OVER (
            PARTITION BY s.fc_id, s.spend_seq
            ORDER BY g.event_time, g.log_seq
        ) AS match_rn
    FROM CurrencySpendRows s
    INNER JOIN EligibleGachaLogs g
      ON s.fc_id = g.fc_id
     AND s.account_id = g.account_id
     AND g.event_time >= s.spend_time
     AND g.event_time <= DATE_ADD('second', 2, s.spend_time)
),

DrawsByGachaLog AS (
    SELECT
        fc_id,
        gacha_event_id,
        activity_type,
        activity_id,
        COUNT(*) AS draw_count
    FROM SpendCandidates
    WHERE match_rn = 1
    GROUP BY 1, 2, 3, 4
),

GachaWithDraws AS (
    SELECT
        g.*,
        COALESCE(d.draw_count, 0) AS draw_count
    FROM EligibleGachaLogs g
    LEFT JOIN DrawsByGachaLog d
      ON g.fc_id = d.fc_id
     AND g.gacha_event_id = d.gacha_event_id
     AND g.activity_type = d.activity_type
     AND g.activity_id = d.activity_id
),

GachaWithPeriod AS (
    SELECT
        g.fc_id,
        g.activity_type,
        g.activity_id,
        g.draw_count,
        w.activity_name,
        w.activity_start_date,
        w.activity_end_date,
        CASE
            WHEN ${Selector:timetype} = 'D' THEN g.stat_date
            ELSE CONCAT(w.activity_start_date, ' ~ ', w.activity_end_date)
        END AS time_dim,
        CASE
            WHEN ${Selector:timetype} = 'D' THEN g.stat_date
            ELSE w.activity_start_date
        END AS period_start_date
    FROM GachaWithDraws g
    INNER JOIN ActivityWindows w
      ON g.activity_type = w.activity_type
     AND g.activity_id = w.activity_id
    WHERE g.draw_count > 0
),

-- 每个时间粒度、活动、fc_id 先累计抽数，保证一名用户只进入一个抽数值。
UserDrawTotals AS (
    SELECT
        time_dim,
        activity_type,
        activity_id,
        MAX(activity_name) AS activity_name,
        MIN(period_start_date) AS period_start_date,
        fc_id,
        SUM(draw_count) AS user_draw_count
    FROM GachaWithPeriod
    GROUP BY 1, 2, 3, 6
    HAVING SUM(draw_count) > 0
),

UserDrawBuckets AS (
    SELECT
        u.*,
        CAST(FLOOR((user_draw_count - 1) / 50.0) AS BIGINT) * 50 + 1
            AS draw_bucket_start,
        CAST(FLOOR((user_draw_count - 1) / 50.0) AS BIGINT) * 50 + 50
            AS draw_bucket_end
    FROM UserDrawTotals u
),

DrawDistribution AS (
    SELECT
        time_dim,
        activity_type,
        activity_id,
        MAX(activity_name) AS activity_name,
        MIN(period_start_date) AS period_start_date,
        draw_bucket_start,
        draw_bucket_end,
        COUNT(*) AS user_count
    FROM UserDrawBuckets
    GROUP BY 1, 2, 3, 6, 7
),

DistributionWithTotals AS (
    SELECT
        d.*,
        SUM(user_count) OVER (
            PARTITION BY time_dim, activity_type, activity_id
        ) AS total_gacha_users,
        SUM(user_count) OVER (
            PARTITION BY time_dim, activity_type, activity_id
            ORDER BY draw_bucket_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_users
    FROM DrawDistribution d
)

SELECT
    time_dim AS "时间维度",
    CASE activity_type
        WHEN 1117 THEN '限时伙伴'
        WHEN 1116 THEN '限时坐骑'
    END AS "活动类型",
    activity_id AS "活动ID",
    TRY(SPLIT(activity_name, '-')[2]) AS "活动名称",
    CONCAT(
        CAST(draw_bucket_start AS VARCHAR),
        '-',
        CAST(draw_bucket_end AS VARCHAR)
    ) AS "抽取次数区间",
    user_count AS "人数",
    total_gacha_users AS "活动抽卡总人数",
    ROUND(100.0 * user_count / NULLIF(total_gacha_users, 0), 2)
        AS "人数占比(%)",
    cumulative_users AS "累计人数",
    ROUND(100.0 * cumulative_users / NULLIF(total_gacha_users, 0), 2)
        AS "累计人数占比(%)"
FROM DistributionWithTotals
ORDER BY
    period_start_date DESC,
    activity_type,
    activity_id,
    draw_bucket_start;
