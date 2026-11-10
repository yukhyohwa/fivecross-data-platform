/*
================================================================================
蜡笔小新繁体 OBT - 限时伙伴 / 限时坐骑抽卡看板（等级、充值区间可拆分）

数数参数：
1. 日期：v.${PartDate:date}
2. 时间：${Selector:timetype}
   D = 按日；其他值 = 按活动观测周期汇总
3. 等级维度：${Selector:levelgroup}
   TRUE = 拆分用户等级区间；FALSE = 合并为“全部等级”
4. 充值维度：${Selector:paytier}
   TRUE = 拆分截至统计周期末累计充值区间；FALSE = 合并为“全部充值区间”

活动类型：1117=限时伙伴，1116=限时坐骑。
账号口径：按 fc_id 去重；不要求创角记录，不按注册时间过滤。
等级口径：OBT 起、周期末以前最后一次非空 login.role_lev；同 fc_id 多角色取最高等级。关闭等级分层时跳过等级历史查询。
充值口径：从 OBT 开始累计至统计周期末，换算 USD；排除 sandbox、免费单和 COIN。关闭充值分层时跳过充值历史查询。
参与率分母：同一时间、活动、等级区间、充值区间内的去重 login fc_id。
抽数：晶钻原始消耗1500或红钻消耗200各计1抽；归因给其后2秒内最早的目标抽卡日志。
黑名单：internal_users_new、is_windows_new、is_water_new，字段为 #varchar_id。
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_windows_new', 'is_water_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

/* 所选日期内的看板事件。 */
RawEvents AS (
    SELECT
        CAST(v."$part_date" AS DATE) AS stat_date,
        v."$part_event" AS event_name,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
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
    LEFT JOIN UserBlacklist b
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_event" IN ('login', 'active_reward', 'item_change')
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
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
      AND activity_id <> '0'
    GROUP BY 1, 2
),

BaseEvents AS (
    SELECT * FROM RawEvents
),

LoginAccounts AS (
    SELECT DISTINCT stat_date, fc_id
    FROM BaseEvents
    WHERE event_name = 'login'
),

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
            ORDER BY event_time, COALESCE(account_id, ''), COALESCE(event_id, '')
        ) AS log_seq
    FROM BaseEvents
    WHERE event_name = 'active_reward'
      AND activity_type IN (1117, 1116)
      AND activity_id IS NOT NULL
      AND activity_id <> '0'
),

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
        item_after, item_before, item_diff, item_id, item_key, item_name, spend_ordinal
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
            ORDER BY s.spend_time, COALESCE(s.spend_event_id, ''), s.spend_ordinal
        ) AS spend_seq
    FROM CurrencySpendRowsRaw s
),

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

GachaWithPeriodBase AS (
    SELECT
        g.*,
        w.activity_name,
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(g.stat_date AS VARCHAR)
            ELSE CONCAT(CAST(w.activity_start_date AS VARCHAR), ' ~ ', CAST(w.activity_end_date AS VARCHAR))
        END AS time_dim,
        CASE WHEN ${Selector:timetype} = 'D' THEN g.stat_date ELSE w.activity_start_date END AS period_start_date,
        CASE WHEN ${Selector:timetype} = 'D' THEN g.stat_date ELSE w.activity_end_date END AS period_end_date
    FROM GachaEnriched g
    INNER JOIN ActivityWindows w
      ON g.activity_type = w.activity_type
     AND g.activity_id = w.activity_id
),

Periods AS (
    SELECT DISTINCT
        time_dim,
        activity_type,
        activity_id,
        activity_name,
        period_start_date,
        period_end_date
    FROM GachaWithPeriodBase
),

/*
统计周期内出现于活跃分母或抽卡分子的账号。
后续按周期末快照统一确定等级和累计充值区间。
*/
PeriodUsers AS (
    SELECT DISTINCT
        p.time_dim,
        p.activity_type,
        p.activity_id,
        p.period_start_date,
        p.period_end_date,
        l.fc_id
    FROM Periods p
    INNER JOIN LoginAccounts l
      ON l.stat_date BETWEEN p.period_start_date AND p.period_end_date

    UNION

    SELECT DISTINCT
        g.time_dim,
        g.activity_type,
        g.activity_id,
        g.period_start_date,
        g.period_end_date,
        g.fc_id
    FROM GachaWithPeriodBase g
),

/* 仅开启等级分层时读取历史；下游按各周期末截断，不扫描日志推导截止日期。 */
LevelRows AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        TRY_CAST(v.role_lev AS BIGINT) AS role_level
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    CROSS JOIN Config c
    WHERE ${Selector:levelgroup}
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                               AND CAST(CURRENT_DATE AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND TRY_CAST(v.role_lev AS BIGINT) IS NOT NULL
      AND  v."$part_event" IN ('login')
),

PeriodRoleLevels AS (
    SELECT
        p.time_dim,
        p.activity_type,
        p.activity_id,
        p.fc_id,
        l.account_id,
        MAX_BY(l.role_level, l.event_time) AS role_level
    FROM PeriodUsers p
    LEFT JOIN LevelRows l
      ON p.fc_id = l.fc_id
     AND CAST(l.event_time AS DATE) <= p.period_end_date
    GROUP BY 1, 2, 3, 4, 5
),

PeriodAccountLevels AS (
    SELECT
        time_dim,
        activity_type,
        activity_id,
        fc_id,
        MAX(role_level) AS role_level
    FROM PeriodRoleLevels
    GROUP BY 1, 2, 3, 4
),

ExchangeRates AS (
    SELECT
        CAST(ex_date AS DATE) AS ex_date,
        UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
        CASE
            WHEN COUNT_IF(TRY_CAST(exchange AS DOUBLE) IS NULL OR TRY_CAST(exchange AS DOUBLE) <= 0) = 0
             AND MIN(TRY_CAST(exchange AS DOUBLE)) = MAX(TRY_CAST(exchange AS DOUBLE))
            THEN MAX(TRY_CAST(exchange AS DOUBLE))
        END AS exchange_rate
    FROM ta_dim.ta_exchange
    WHERE ${Selector:paytier}
    GROUP BY 1, 2
),

/* 仅开启充值分层时读取 OBT 累计流水；下游只累计到各自 period_end_date。 */
ChargeRows AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS pay_date,
        TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(e.exchange_rate, 0) AS revenue_usd,
        CASE
            WHEN TRY_CAST(v.pay_amount AS DOUBLE) IS NULL
              OR e.exchange_rate IS NULL
              OR e.exchange_rate <= 0
            THEN 1 ELSE 0
        END AS invalid_revenue
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    CROSS JOIN Config c
    LEFT JOIN ExchangeRates e
      ON CAST(v."$part_date" AS DATE) = e.ex_date
     AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = e.currency
    WHERE ${Selector:paytier}
      AND v."$part_event" = 'charge'
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                               AND CAST(CURRENT_DATE AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
),

PeriodPayments AS (
    SELECT
        p.time_dim,
        p.activity_type,
        p.activity_id,
        p.fc_id,
        COALESCE(SUM(c.revenue_usd), 0.0) AS cumulative_revenue_usd,
        COALESCE(SUM(c.invalid_revenue), 0) AS invalid_revenue_rows
    FROM PeriodUsers p
    LEFT JOIN ChargeRows c
      ON p.fc_id = c.fc_id
     AND c.pay_date <= p.period_end_date
    GROUP BY 1, 2, 3, 4
),

/* 选择器关闭时合并；打开时按固定区间拆分。 */
UserSegments AS (
    SELECT
        p.time_dim,
        p.activity_type,
        p.activity_id,
        p.fc_id,
        CASE
            WHEN NOT ${Selector:levelgroup} THEN '全部等级'
            WHEN l.role_level IS NULL THEN '未知等级'
            WHEN l.role_level BETWEEN 1 AND 10 THEN '01.1-10级'
            WHEN l.role_level BETWEEN 11 AND 20 THEN '02.11-20级'
            WHEN l.role_level BETWEEN 21 AND 30 THEN '03.21-30级'
            WHEN l.role_level BETWEEN 31 AND 40 THEN '04.31-40级'
            WHEN l.role_level BETWEEN 41 AND 50 THEN '05.41-50级'
            WHEN l.role_level BETWEEN 51 AND 60 THEN '06.51-60级'
            WHEN l.role_level BETWEEN 61 AND 70 THEN '07.61-70级'
            WHEN l.role_level BETWEEN 71 AND 80 THEN '08.71-80级'
            WHEN l.role_level BETWEEN 81 AND 90 THEN '09.81-90级'
            ELSE '10.91级及以上'
        END AS level_group,
        CASE
            WHEN NOT ${Selector:levelgroup} THEN 0
            WHEN l.role_level IS NULL THEN 999
            WHEN l.role_level BETWEEN 1 AND 10 THEN 1
            WHEN l.role_level BETWEEN 11 AND 20 THEN 2
            WHEN l.role_level BETWEEN 21 AND 30 THEN 3
            WHEN l.role_level BETWEEN 31 AND 40 THEN 4
            WHEN l.role_level BETWEEN 41 AND 50 THEN 5
            WHEN l.role_level BETWEEN 51 AND 60 THEN 6
            WHEN l.role_level BETWEEN 61 AND 70 THEN 7
            WHEN l.role_level BETWEEN 71 AND 80 THEN 8
            WHEN l.role_level BETWEEN 81 AND 90 THEN 9
            ELSE 10
        END AS level_order,
        CASE
            WHEN NOT ${Selector:paytier} THEN '全部充值区间'
            WHEN pay.invalid_revenue_rows > 0 THEN '99.金额异常'
            WHEN pay.cumulative_revenue_usd = 0 THEN '00.免费用户'
            WHEN pay.cumulative_revenue_usd <= 10 THEN '01.(0,10] USD'
            WHEN pay.cumulative_revenue_usd <= 50 THEN '02.(10,50] USD'
            WHEN pay.cumulative_revenue_usd <= 100 THEN '03.(50,100] USD'
            WHEN pay.cumulative_revenue_usd <= 300 THEN '04.(100,300] USD'
            WHEN pay.cumulative_revenue_usd <= 500 THEN '05.(300,500] USD'
            ELSE '06.(500,+∞) USD'
        END AS pay_tier,
        CASE
            WHEN NOT ${Selector:paytier} THEN 0
            WHEN pay.invalid_revenue_rows > 0 THEN 999
            WHEN pay.cumulative_revenue_usd = 0 THEN 0
            WHEN pay.cumulative_revenue_usd <= 10 THEN 1
            WHEN pay.cumulative_revenue_usd <= 50 THEN 2
            WHEN pay.cumulative_revenue_usd <= 100 THEN 3
            WHEN pay.cumulative_revenue_usd <= 300 THEN 4
            WHEN pay.cumulative_revenue_usd <= 500 THEN 5
            ELSE 6
        END AS pay_order
    FROM PeriodUsers p
    LEFT JOIN PeriodAccountLevels l
      ON p.time_dim = l.time_dim
     AND p.activity_type = l.activity_type
     AND p.activity_id = l.activity_id
     AND p.fc_id = l.fc_id
    LEFT JOIN PeriodPayments pay
      ON p.time_dim = pay.time_dim
     AND p.activity_type = pay.activity_type
     AND p.activity_id = pay.activity_id
     AND p.fc_id = pay.fc_id
),

GachaWithSegments AS (
    SELECT
        g.*,
        s.level_group,
        s.level_order,
        s.pay_tier,
        s.pay_order
    FROM GachaWithPeriodBase g
    INNER JOIN UserSegments s
      ON g.time_dim = s.time_dim
     AND g.activity_type = s.activity_type
     AND g.activity_id = s.activity_id
     AND g.fc_id = s.fc_id
),

GachaSummary AS (
    SELECT
        time_dim,
        activity_type,
        activity_id,
        activity_name,
        period_start_date,
        period_end_date,
        level_group,
        level_order,
        pay_tier,
        pay_order,
        COUNT(DISTINCT fc_id) AS gacha_users,
        SUM(draw_count) AS gacha_draws,
        COUNT(DISTINCT CASE WHEN red_consumed > 0 THEN fc_id END) AS red_users,
        COUNT(DISTINCT CASE WHEN gem_consumed > 0 THEN fc_id END) AS gem_users,
        SUM(red_consumed) AS red_consumed,
        SUM(gem_consumed) AS gem_consumed
    FROM GachaWithSegments
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
),

ActiveUsers AS (
    SELECT
        p.time_dim,
        p.activity_type,
        p.activity_id,
        s.level_group,
        s.level_order,
        s.pay_tier,
        s.pay_order,
        COUNT(DISTINCT l.fc_id) AS active_users
    FROM Periods p
    INNER JOIN LoginAccounts l
      ON l.stat_date BETWEEN p.period_start_date AND p.period_end_date
    INNER JOIN UserSegments s
      ON p.time_dim = s.time_dim
     AND p.activity_type = s.activity_type
     AND p.activity_id = s.activity_id
     AND l.fc_id = s.fc_id
    GROUP BY 1, 2, 3, 4, 5, 6, 7
)

SELECT
    s.time_dim AS "时间维度",
    CASE s.activity_type
        WHEN 1117 THEN '限时伙伴'
        WHEN 1116 THEN '限时坐骑'
    END AS "活动类型",
    s.activity_id AS "活动ID",
    TRY(SPLIT(s.activity_name, '-')[2]) AS "活动名称",
    s.level_group AS "用户等级区间",
    s.pay_tier AS "截至周期末累计充值区间",
    COALESCE(a.active_users, 0) AS "分层期间活跃人数",
    s.gacha_users AS "抽卡人数",
    s.gacha_draws AS "抽卡总次数",
    ROUND(1.0 * s.gacha_draws / NULLIF(s.gacha_users, 0), 2) AS "人均抽卡次数",
    ROUND(100.0 * s.gacha_users / NULLIF(a.active_users, 0), 2) AS "分层抽卡参与率(%)",
    s.red_users AS "红钻消耗人数",
    s.gem_users AS "晶钻消耗人数",
    ROUND(s.red_consumed, 2) AS "红钻消耗量",
    ROUND(s.gem_consumed, 2) AS "晶钻消耗量"
FROM GachaSummary s
LEFT JOIN ActiveUsers a
  ON s.time_dim = a.time_dim
 AND s.activity_type = a.activity_type
 AND s.activity_id = a.activity_id
 AND s.level_group = a.level_group
 AND s.level_order = a.level_order
 AND s.pay_tier = a.pay_tier
 AND s.pay_order = a.pay_order
ORDER BY
    s.period_start_date DESC,
    s.activity_type,
    s.activity_id,
    s.level_order,
    s.pay_order;
