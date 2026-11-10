/*
================================================================================
蜡笔小新繁体 OBT - 限时伙伴 / 限时坐骑抽卡看板（fc_id 账号口径）

日期参数：v.${PartDate:date}
时间维度：${Selector:timetype}
    D      = 按日
    其他值 = 按活动汇总

活动类型：
    1117 = 限时伙伴
    1116 = 限时坐骑

活动观测周期：
    查询范围内，按 activity_type + activity_id，
    取首次、末次目标 active_reward 的日期。
    不等同于配置中的正式活动起止时间。

账号口径：
    账号按 fc_id 去重，同一 fc_id 多角色合并；日期完全由所选区间控制。
    不要求创角记录，不按注册时间过滤。

抽数：
    不使用 active_reward.a_rst 的元素数；相同奖励会合并，数组长度会低估抽数。
    每条晶钻原始消耗 1500（折算 15 晶钻）计 1 抽；
    每条红钻消耗 200 计 1 抽，因此 10 条红钻消耗合计 2000 对应 10 抽。
    消耗事件分配给同 fc_id、同账号、其后 2 秒内最早的目标 active_reward。

消耗：
    红钻 ID = 10009；
    晶钻 ID = 10206，原始数量除以 100。

过滤：
    黑名单账号字段使用 user_result_cluster_18."#varchar_id"。
    因指标涉及晶钻消耗，统一排除 internal_users_new、is_windows_new、is_water_new。
    排除空 fc_id。

URL:https://ss-web.5xgames.com/#/tga/ide/18_5112?fromPanel=18_914
================================================================================
*/

WITH
UserBlacklist AS (
    SELECT DISTINCT
        TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN (
        'internal_users_new',
        'is_windows_new',
        'is_water_new'
    )
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

-- 4. 所选日期内的原始事件；活动窗口保留原始目标活动记录，不受人群过滤影响
RawEvents AS (
    SELECT
        v."$part_date" AS stat_date,
        v."$part_event" AS event_name,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."#user_id" AS VARCHAR) AS user_id,
        CAST(v."#te_event_id" AS VARCHAR) AS event_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        TRY_CAST(v.type AS BIGINT) AS activity_type,

        CASE
            WHEN v."$part_event" = 'active_reward'
             AND TRY_CAST(v.type AS BIGINT) IN (1117, 1116)
            THEN CAST(CAST(v.id AS DECIMAL(38, 0)) AS VARCHAR)
        END AS activity_id,

        CAST(v.name AS VARCHAR) AS activity_name,
        v.a_rst
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date}
      AND v."$part_event" IN ('login', 'active_reward', 'item_change')
),

ActivityWindows AS (
    SELECT
        activity_type,
        activity_id,
        MAX_BY(activity_name, event_time)
            FILTER (WHERE activity_name IS NOT NULL) AS activity_name,
        MIN(stat_date) AS activity_start_date,
        MAX(stat_date) AS activity_end_date
    FROM RawEvents
    WHERE event_name = 'active_reward'
      AND activity_type IN (1117, 1116)
      AND activity_id IS NOT NULL
    GROUP BY 1, 2
),

-- 指标统计排除空 fc_id 和黑名单，不关联注册记录
BaseEvents AS (
    SELECT r.*
    FROM RawEvents r
    LEFT JOIN UserBlacklist b
      ON r.fc_id = b.fc_id
    WHERE NULLIF(r.fc_id, '') IS NOT NULL
      AND b.fc_id IS NULL
),

-- 6. 活跃 fc_id：先按日、fc_id 去重
LoginAccounts AS (
    SELECT DISTINCT
        stat_date,
        fc_id
    FROM BaseEvents
    WHERE event_name = 'login'
),

-- 7. 目标抽卡日志；活动 ID=0 不纳入
GachaLogs AS (
    SELECT
        stat_date,
        fc_id,
        account_id,
        event_id AS gacha_event_id,
        event_time,
        activity_type,
        activity_id,
        ROW_NUMBER() OVER (
            PARTITION BY fc_id
            ORDER BY event_time,
                     COALESCE(account_id, ''),
                     COALESCE(event_id, '')
        ) AS log_seq
    FROM BaseEvents
    WHERE event_name = 'active_reward'
      AND activity_type IN (1117, 1116)
      AND activity_id IS NOT NULL
      AND activity_id <> '0'
),

-- 8. 每条合格货币消耗代表 1 抽；保留行级顺序供后续唯一匹配
CurrencySpendRowsRaw AS (
    SELECT
        b.fc_id,
        b.account_id,
        b.event_time AS spend_time,
        b.event_id AS spend_event_id,
        u.spend_ordinal,
        TRY_CAST(u.item_id AS BIGINT) AS item_id,
        TRY_CAST(u.item_before AS DOUBLE) - TRY_CAST(u.item_after AS DOUBLE) AS raw_spent
    FROM BaseEvents b
    CROSS JOIN UNNEST(b.a_rst) WITH ORDINALITY AS u(
        item_after,
        item_before,
        item_diff,
        item_id,
        item_key,
        item_name,
        spend_ordinal
    )
    WHERE b.event_name = 'item_change'
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

-- 9. 每条消费只分配给其后 2 秒内最早的一条目标抽卡日志
SpendCandidates AS (
    SELECT
        s.fc_id,
        s.spend_seq,
        s.item_id,
        s.raw_spent,
        g.gacha_event_id,
        g.activity_type,
        g.activity_id,
        ROW_NUMBER() OVER (
            PARTITION BY s.fc_id, s.spend_seq
            ORDER BY g.event_time, g.log_seq
        ) AS match_rn
    FROM CurrencySpendRows s
    INNER JOIN GachaLogs g
      ON s.fc_id = g.fc_id
     AND s.account_id = g.account_id
     AND g.event_time >= s.spend_time
     AND g.event_time <= DATE_ADD('second', 2, s.spend_time)
),

SpendByGachaLog AS (
    SELECT
        fc_id,
        gacha_event_id,
        activity_type,
        activity_id,
        COUNT(*) AS draw_count,
        SUM(CASE WHEN item_id = 10009 THEN raw_spent ELSE 0.0 END) AS red_consumed,
        SUM(CASE WHEN item_id = 10206 THEN raw_spent / 100.0 ELSE 0.0 END) AS gem_consumed
    FROM SpendCandidates
    WHERE match_rn = 1
    GROUP BY 1, 2, 3, 4
),

-- 10. 抽数与消耗均来自已成功归因的消费记录
GachaEnriched AS (
    SELECT
        g.stat_date,
        g.fc_id,
        g.activity_type,
        g.activity_id,
        COALESCE(s.draw_count, 0) AS draw_count,
        COALESCE(s.red_consumed, 0.0) AS red_consumed,
        COALESCE(s.gem_consumed, 0.0) AS gem_consumed
    FROM GachaLogs g
    LEFT JOIN SpendByGachaLog s
      ON g.fc_id = s.fc_id
     AND g.gacha_event_id = s.gacha_event_id
     AND g.activity_type = s.activity_type
     AND g.activity_id = s.activity_id
),

-- 11. 只保留按日 / 按活动汇总两种统计粒度
GachaWithPeriod AS (
    SELECT
        g.*,
        w.activity_name,

        CASE
            WHEN ${Selector:timetype} = 'D' THEN g.stat_date
            ELSE CONCAT(w.activity_start_date, ' ~ ', w.activity_end_date)
        END AS time_dim,

        CASE
            WHEN ${Selector:timetype} = 'D' THEN g.stat_date
            ELSE w.activity_start_date
        END AS period_start_date,

        CASE
            WHEN ${Selector:timetype} = 'D' THEN g.stat_date
            ELSE w.activity_end_date
        END AS period_end_date

    FROM GachaEnriched g
    JOIN ActivityWindows w
      ON g.activity_type = w.activity_type
     AND g.activity_id = w.activity_id
),

GachaSummary AS (
    SELECT
        time_dim,
        activity_type,
        activity_id,
        activity_name,
        period_start_date,
        period_end_date,

        COUNT(DISTINCT fc_id) AS gacha_users,
        SUM(draw_count) AS gacha_draws,

        COUNT(DISTINCT CASE WHEN red_consumed > 0 THEN fc_id END) AS red_users,
        COUNT(DISTINCT CASE WHEN gem_consumed > 0 THEN fc_id END) AS gem_users,

        SUM(red_consumed) AS red_consumed,
        SUM(gem_consumed) AS gem_consumed

    FROM GachaWithPeriod
    GROUP BY 1, 2, 3, 4, 5, 6
),

-- 12. 每个统计周期内重新计算去重活跃 fc_id
-- 汇总时按各活动自身起止日期计算，不能累加 DAU
Periods AS (
    SELECT DISTINCT
        time_dim,
        activity_type,
        activity_id,
        period_start_date,
        period_end_date
    FROM GachaSummary
),

ActiveUsers AS (
    SELECT
        p.time_dim,
        p.activity_type,
        p.activity_id,
        COUNT(DISTINCT l.fc_id) AS active_users
    FROM Periods p
    LEFT JOIN LoginAccounts l
      ON l.stat_date BETWEEN p.period_start_date AND p.period_end_date
    GROUP BY 1, 2, 3
)

-- 13. 看板输出
SELECT
    s.time_dim AS "时间维度",

    CASE s.activity_type
        WHEN 1117 THEN '限时伙伴'
        WHEN 1116 THEN '限时坐骑'
    END AS "活动类型",

    s.activity_id AS "活动ID",
    TRY(SPLIT(s.activity_name, '-')[2]) AS "活动名称",

    COALESCE(a.active_users, 0) AS "期间活跃人数",
    s.gacha_users AS "抽卡人数",
    s.gacha_draws AS "抽卡总次数",

    ROUND(1.0 * s.gacha_draws / NULLIF(s.gacha_users, 0), 2)
        AS "人均抽卡次数",

    ROUND(100.0 * s.gacha_users / NULLIF(a.active_users, 0), 2)
        AS "抽卡参与率(%)",

    s.red_users AS "红钻消耗人数",
    s.gem_users AS "晶钻消耗人数",

    ROUND(s.red_consumed, 2) AS "红钻消耗量",
    ROUND(s.gem_consumed, 2) AS "晶钻消耗量"

FROM GachaSummary s
LEFT JOIN ActiveUsers a
  ON s.time_dim = a.time_dim
 AND s.activity_type = a.activity_type
 AND s.activity_id = a.activity_id
ORDER BY
    s.period_start_date DESC,
    s.activity_type,
    s.activity_id;
