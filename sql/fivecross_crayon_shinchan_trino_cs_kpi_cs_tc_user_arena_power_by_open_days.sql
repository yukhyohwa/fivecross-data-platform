/*
繁体正式服 App 18 / Trino，OBT 起点 2026-10-14。
数数日期参数使用 ${PartDate:date1}；统计截止日自动取所选分区的最大日期。
维度选择器：${Selector:zone}=TRUE 时按服务器拆分，否则按开服日龄合并服务器；
${Selector:paytier}=TRUE 时拆分充值区间，否则合并；
${Selector:rankgroup}=TRUE 时拆分竞技场排名组，否则合并。
开服时间定义为 2026-10-14 以后，各 server_id 首位有效玩家触发 new_role 的 #event_time。
服务器先后仅按完整开服时间戳判断；时间戳完全相同则视为同时开服。
跨服身份使用 fc_id；一账号一服保留首次创角。黑名单采用 internal_users_new、
is_water_new、is_windows_new；无同服 OBT 创角或早于创角的订单不计入。
收入为 USD：pay_amount / 当日同币种 exchange；排除 sandbox/is_freebuy/COIN。
相同汇率去重，冲突/缺失/非正汇率及非法金额使受影响汇总返回 NULL，并计异常数。
沿用 charge 事件流水口径，要求成功订单不重复上报；未扣退款。
第1天是开服自然日。max_open_days 默认30，扩展时须同步修改透视列。
尚未到达的日龄为 NULL；截止日若未结束，收入为提数时的部分日数据。
本文件未在真实 Trino 数据库执行；已做语法解析及模拟数据验证。
*/
/* 平均战力：本服竞技场排名取 pvp_chapter 且 zonetype=0。
己方取 #account_id + role_info.rank_after；对手取 target_id + target_info.rank_after。
rank_after 是当次结算后的当前名次；rank_before 和 rank_diff 不作为排名。
战力取 card_battlepower.a_rst.after，两者均按 #account_id 关联角色。
每个开服日使用截至当天最后一次已知排名和战力；当天未变化时沿用此前最后记录，
不会使用未来记录。未曾触发 pvp_chapter 的角色无法进入事件观测到的竞技场名单。
行=服务器/当日截至日累计充值区间USD/竞技场排名区间，列=第1~30天平均战力及两类样本人数。
排名使用互斥组：1-10、11-20、21-30、31-40、41-50、50以上。
同账号同服多角色取当日名次最好的一角的战力；冲突角色映射排除，需提前核验。
玩家每天只进入一个排名组；50以上表示排名大于50。
区间默认0、(0,10]、(10,100]、(100,500]、>500、金额异常，可改 TierGroups 和分层CASE。
无可识别排名快照的日期：战力和人数均NULL；有排名但本分组无人：人数0、战力NULL。
缺失/负战力不计平均分母；部分账号快照缺失可能影响均值，结合有效战力人数评估。
不填0、不回填未来数据、不默认沿用旧快照；未声称已核验真实埋点。
*/
WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date,
           MAX(CAST(v."$part_date" AS DATE)) AS report_end_date,
           30 AS max_open_days
    FROM ta.v_event_18 v
    WHERE ${PartDate:date1}
),


Blacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
),
RegistrationRows AS (
    SELECT NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') AS fc_id,
           NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), '') AS server_id,
           NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') AS role_id,
           CAST(v."#event_time" AS TIMESTAMP) AS create_time,
           CAST(v."$part_date" AS DATE) AS create_date
    FROM ta.v_event_18 v CROSS JOIN Config c
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                                 AND CAST(c.report_end_date AS VARCHAR)
),
ServerDates AS (
    SELECT r.server_id, MIN(r.create_time) AS open_time
    FROM RegistrationRows r
    LEFT JOIN Blacklist b ON r.fc_id = b.fc_id
    WHERE r.server_id IS NOT NULL
      AND r.fc_id IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),
Servers AS (
    SELECT s.*,
           CAST(s.open_time AS DATE) AS open_date,
           DENSE_RANK() OVER (ORDER BY s.open_time) AS server_seq
    FROM ServerDates s CROSS JOIN Config c
    WHERE CAST(s.open_time AS DATE) BETWEEN c.obt_start_date AND c.report_end_date
),

Registrations AS (
    SELECT r.fc_id, r.server_id, MIN(r.create_time) AS create_time
    FROM RegistrationRows r
    LEFT JOIN Blacklist b ON r.fc_id = b.fc_id
    WHERE r.fc_id IS NOT NULL AND r.server_id IS NOT NULL
      AND r.create_time IS NOT NULL AND b.fc_id IS NULL
    GROUP BY 1, 2
),
ExchangeRates AS (
    SELECT CAST(ex_date AS VARCHAR) AS ex_date,
           UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
           CASE WHEN COUNT_IF(TRY_CAST(exchange AS DOUBLE) IS NULL OR TRY_CAST(exchange AS DOUBLE) <= 0) = 0
                     AND MIN(TRY_CAST(exchange AS DOUBLE)) = MAX(TRY_CAST(exchange AS DOUBLE))
                THEN MAX(TRY_CAST(exchange AS DOUBLE)) END AS exchange
    FROM ta_dim.ta_exchange CROSS JOIN Config c
    WHERE CAST(ex_date AS VARCHAR) BETWEEN CAST(c.obt_start_date AS VARCHAR)
                                         AND CAST(c.report_end_date AS VARCHAR)
    GROUP BY 1, 2
),
Charges AS (
    SELECT r.fc_id, r.server_id, CAST(v."$part_date" AS DATE) AS pay_date,
           TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(e.exchange, 0) AS revenue_usd,
           CASE WHEN TRY_CAST(v.pay_amount AS DOUBLE) IS NULL OR e.exchange IS NULL
                THEN 1 ELSE 0 END AS invalid_revenue
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    JOIN Registrations r
      ON NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') = r.fc_id
     AND NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), '') = r.server_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= r.create_time
    LEFT JOIN ExchangeRates e ON v."$part_date" = e.ex_date
     AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = e.currency
    WHERE v."$part_event" = 'charge'
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                                 AND CAST(c.report_end_date AS VARCHAR)
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
),
RankGroups(rank_group_order, rank_group, min_rank, max_rank) AS (
    VALUES (1, '1-10', 1, 10),
           (2, '11-20', 11, 20),
           (3, '21-30', 21, 30),
           (4, '31-40', 31, 40),
           (5, '41-50', 41, 50),
           (6, '50以上', 51, CAST(NULL AS INTEGER))
),
TierGroups(tier_order, payer_tier) AS (
    VALUES (0, '0'), (1, '(0,10]'), (2, '(10,100]'),
           (3, '(100,500]'), (4, '>500'), (5, '金额异常')
),
SelectedRankGroups AS (
    SELECT DISTINCT
           CASE WHEN ${Selector:rankgroup} THEN rank_group ELSE '全部竞技场排名' END AS rank_group,
           CASE WHEN ${Selector:rankgroup} THEN rank_group_order ELSE 0 END AS rank_group_order
    FROM RankGroups
),
SelectedTierGroups AS (
    SELECT DISTINCT
           CASE WHEN ${Selector:paytier} THEN payer_tier ELSE '全部充值区间' END AS payer_tier,
           CASE WHEN ${Selector:paytier} THEN tier_order ELSE 0 END AS tier_order
    FROM TierGroups
),
ServerDays AS (
    SELECT s.*, n AS open_day, DATE_ADD('day', n - 1, s.open_date) AS stat_date
    FROM Servers s CROSS JOIN Config c
    CROSS JOIN UNNEST(SEQUENCE(1, c.max_open_days)) AS t(n)
    WHERE DATE_ADD('day', n - 1, s.open_date) <= c.report_end_date
),

RoleMap AS (
    SELECT r.role_id, MAX(r.fc_id) AS fc_id, MAX(r.server_id) AS server_id,
           MIN(r.create_time) AS create_time
    FROM RegistrationRows r JOIN Registrations a
      ON r.fc_id = a.fc_id AND r.server_id = a.server_id
    WHERE r.role_id IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT r.fc_id) = 1 AND COUNT(DISTINCT r.server_id) = 1
),

ArenaRankRows AS (
    SELECT NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') AS role_id,
           CAST(v."$part_date" AS DATE) AS stat_date,
           CAST(v."#event_time" AS TIMESTAMP) AS event_time,
           TRY_CAST(ri.rank_after AS BIGINT) AS arena_rank,
           2 AS source_priority
    FROM ta.v_event_18 v
    CROSS JOIN UNNEST(v.role_info) AS ri
    CROSS JOIN Config c
    WHERE v."$part_event" = 'pvp_chapter'
      AND TRY_CAST(v.zonetype AS INTEGER) = 0
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                                 AND CAST(c.report_end_date AS VARCHAR)

    UNION ALL

    SELECT NULLIF(TRIM(CAST(v.target_id AS VARCHAR)), '') AS role_id,
           CAST(v."$part_date" AS DATE) AS stat_date,
           CAST(v."#event_time" AS TIMESTAMP) AS event_time,
           TRY_CAST(ti.rank_after AS BIGINT) AS arena_rank,
           1 AS source_priority
    FROM ta.v_event_18 v
    CROSS JOIN UNNEST(v.target_info) AS ti
    CROSS JOIN Config c
    WHERE v."$part_event" = 'pvp_chapter'
      AND TRY_CAST(v.zonetype AS INTEGER) = 0
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                                 AND CAST(c.report_end_date AS VARCHAR)
),
BattlePowerRows AS (
    SELECT NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') AS role_id,
           CAST(v."$part_date" AS DATE) AS stat_date,
           CAST(v."#event_time" AS TIMESTAMP) AS event_time,
           TRY_CAST(t.after AS DOUBLE) AS battle_power
    FROM ta.v_event_18 v
    CROSS JOIN UNNEST(v.a_rst) AS t
    CROSS JOIN Config c
    WHERE v."$part_event" = 'card_battlepower'
      AND v."$part_date" BETWEEN CAST(c.obt_start_date AS VARCHAR)
                                 AND CAST(c.report_end_date AS VARCHAR)
      AND TRY_CAST(t.after AS DOUBLE) >= 0
),
DailyArenaRanks AS (
    SELECT d.server_id, d.open_day, d.stat_date, m.fc_id, a.role_id,
           MAX_BY(a.arena_rank, ROW(a.event_time, a.source_priority)) AS arena_rank
    FROM ServerDays d
    JOIN RoleMap m ON d.server_id = m.server_id
    JOIN ArenaRankRows a
      ON m.role_id = a.role_id
     AND a.event_time >= m.create_time
     AND a.stat_date <= d.stat_date
    WHERE a.role_id IS NOT NULL AND a.arena_rank > 0
    GROUP BY 1, 2, 3, 4, 5
),
DailyRoleStats AS (
    SELECT a.fc_id, a.server_id, a.role_id, a.open_day, a.stat_date, a.arena_rank,
           MAX_BY(p.battle_power, p.event_time) AS battle_power
    FROM DailyArenaRanks a
    LEFT JOIN BattlePowerRows p
      ON a.role_id = p.role_id
     AND p.stat_date <= a.stat_date
    GROUP BY 1, 2, 3, 4, 5, 6
),
AccountSnapshotsRanked AS (
    SELECT s.fc_id, s.server_id, s.open_day, s.stat_date, s.arena_rank, s.battle_power,
           ROW_NUMBER() OVER (PARTITION BY s.fc_id, s.server_id, s.stat_date
                              ORDER BY s.arena_rank, s.role_id) AS account_rn
    FROM DailyRoleStats s
),
AccountSnapshots AS (
    SELECT * FROM AccountSnapshotsRanked WHERE account_rn = 1
),

DailyAccountRevenue AS (
    SELECT fc_id, server_id, pay_date, SUM(revenue_usd) AS revenue_usd,
           SUM(invalid_revenue) AS invalid_orders
    FROM Charges GROUP BY 1, 2, 3
),
SnapshotRevenue AS (
    SELECT s.fc_id, s.server_id, s.open_day, s.stat_date, s.arena_rank, s.battle_power,
           COALESCE(SUM(r.revenue_usd), 0) AS cumulative_usd,
           COALESCE(SUM(r.invalid_orders), 0) AS invalid_orders
    FROM AccountSnapshots s
    LEFT JOIN DailyAccountRevenue r ON s.fc_id = r.fc_id AND s.server_id = r.server_id
                                   AND r.pay_date <= s.stat_date
    GROUP BY 1, 2, 3, 4, 5, 6
),
TieredSnapshots AS (
    SELECT s.*, CASE WHEN invalid_orders > 0 OR cumulative_usd < 0 THEN '金额异常'
                     WHEN cumulative_usd = 0 THEN '0'
                     WHEN cumulative_usd <= 10 THEN '(0,10]'
                     WHEN cumulative_usd <= 100 THEN '(10,100]'
                     WHEN cumulative_usd <= 500 THEN '(100,500]'
                     ELSE '>500' END AS payer_tier
    FROM SnapshotRevenue s
),
DailySamples AS (
    SELECT CASE WHEN ${Selector:zone} THEN s.server_id ELSE '全部服务器' END AS server_id,
           s.open_day,
           CASE WHEN ${Selector:paytier} THEN s.payer_tier ELSE '全部充值区间' END AS payer_tier,
           CASE WHEN ${Selector:paytier} THEN t.tier_order ELSE 0 END AS tier_order,
           CASE WHEN ${Selector:rankgroup} THEN g.rank_group ELSE '全部竞技场排名' END AS rank_group,
           CASE WHEN ${Selector:rankgroup} THEN g.rank_group_order ELSE 0 END AS rank_group_order,
           COUNT(*) AS sampled_accounts,
           COUNT_IF(s.battle_power >= 0) AS power_accounts,
           AVG(CASE WHEN s.battle_power >= 0 THEN s.battle_power END) AS avg_power
    FROM TieredSnapshots s
    JOIN TierGroups t ON s.payer_tier = t.payer_tier
    JOIN RankGroups g
      ON s.arena_rank >= g.min_rank
     AND (g.max_rank IS NULL OR s.arena_rank <= g.max_rank)
    GROUP BY 1, 2, 3, 4, 5, 6
),

SnapshotCoverage AS (
    SELECT CASE WHEN ${Selector:zone} THEN server_id ELSE '全部服务器' END AS server_id,
           open_day, COUNT(*) AS snapshot_accounts
    FROM AccountSnapshots
    GROUP BY 1, 2
),
SelectedServerDays AS (
    SELECT CASE WHEN ${Selector:zone} THEN server_id ELSE '全部服务器' END AS server_id,
           CASE WHEN ${Selector:zone} THEN server_seq ELSE 0 END AS server_seq,
           CASE WHEN ${Selector:zone} THEN open_time ELSE CAST(NULL AS TIMESTAMP) END AS open_time,
           CASE WHEN ${Selector:zone} THEN open_date ELSE CAST(NULL AS DATE) END AS open_date,
           open_day
    FROM ServerDays
    GROUP BY 1, 2, 3, 4, 5
),
DayValues AS (
    SELECT d.*, t.payer_tier, t.tier_order,
           g.rank_group_order, g.rank_group,
           r.avg_power,
           CASE WHEN cov.snapshot_accounts > 0 THEN COALESCE(r.sampled_accounts, 0) END AS sampled_accounts,
           CASE WHEN cov.snapshot_accounts > 0 THEN COALESCE(r.power_accounts, 0) END AS power_accounts
    FROM SelectedServerDays d CROSS JOIN SelectedTierGroups t CROSS JOIN SelectedRankGroups g
    LEFT JOIN DailySamples r ON d.server_id = r.server_id AND d.open_day = r.open_day
                           AND t.payer_tier = r.payer_tier
                           AND g.rank_group = r.rank_group
    LEFT JOIN SnapshotCoverage cov ON d.server_id = cov.server_id AND d.open_day = cov.open_day
)
SELECT d.server_id AS "服务器", d.payer_tier AS "截至当日累计充值区间USD",
       d.rank_group AS "竞技场排名分组",
    MAX(CASE WHEN d.open_day = 1 THEN d.avg_power END) AS "第1天平均战力",
    MAX(CASE WHEN d.open_day = 1 THEN d.sampled_accounts END) AS "第1天实际取样人数",
    MAX(CASE WHEN d.open_day = 1 THEN d.power_accounts END) AS "第1天有效战力人数",
    MAX(CASE WHEN d.open_day = 2 THEN d.avg_power END) AS "第2天平均战力",
    MAX(CASE WHEN d.open_day = 2 THEN d.sampled_accounts END) AS "第2天实际取样人数",
    MAX(CASE WHEN d.open_day = 2 THEN d.power_accounts END) AS "第2天有效战力人数",
    MAX(CASE WHEN d.open_day = 3 THEN d.avg_power END) AS "第3天平均战力",
    MAX(CASE WHEN d.open_day = 3 THEN d.sampled_accounts END) AS "第3天实际取样人数",
    MAX(CASE WHEN d.open_day = 3 THEN d.power_accounts END) AS "第3天有效战力人数",
    MAX(CASE WHEN d.open_day = 4 THEN d.avg_power END) AS "第4天平均战力",
    MAX(CASE WHEN d.open_day = 4 THEN d.sampled_accounts END) AS "第4天实际取样人数",
    MAX(CASE WHEN d.open_day = 4 THEN d.power_accounts END) AS "第4天有效战力人数",
    MAX(CASE WHEN d.open_day = 5 THEN d.avg_power END) AS "第5天平均战力",
    MAX(CASE WHEN d.open_day = 5 THEN d.sampled_accounts END) AS "第5天实际取样人数",
    MAX(CASE WHEN d.open_day = 5 THEN d.power_accounts END) AS "第5天有效战力人数",
    MAX(CASE WHEN d.open_day = 6 THEN d.avg_power END) AS "第6天平均战力",
    MAX(CASE WHEN d.open_day = 6 THEN d.sampled_accounts END) AS "第6天实际取样人数",
    MAX(CASE WHEN d.open_day = 6 THEN d.power_accounts END) AS "第6天有效战力人数",
    MAX(CASE WHEN d.open_day = 7 THEN d.avg_power END) AS "第7天平均战力",
    MAX(CASE WHEN d.open_day = 7 THEN d.sampled_accounts END) AS "第7天实际取样人数",
    MAX(CASE WHEN d.open_day = 7 THEN d.power_accounts END) AS "第7天有效战力人数",
    MAX(CASE WHEN d.open_day = 8 THEN d.avg_power END) AS "第8天平均战力",
    MAX(CASE WHEN d.open_day = 8 THEN d.sampled_accounts END) AS "第8天实际取样人数",
    MAX(CASE WHEN d.open_day = 8 THEN d.power_accounts END) AS "第8天有效战力人数",
    MAX(CASE WHEN d.open_day = 9 THEN d.avg_power END) AS "第9天平均战力",
    MAX(CASE WHEN d.open_day = 9 THEN d.sampled_accounts END) AS "第9天实际取样人数",
    MAX(CASE WHEN d.open_day = 9 THEN d.power_accounts END) AS "第9天有效战力人数",
    MAX(CASE WHEN d.open_day = 10 THEN d.avg_power END) AS "第10天平均战力",
    MAX(CASE WHEN d.open_day = 10 THEN d.sampled_accounts END) AS "第10天实际取样人数",
    MAX(CASE WHEN d.open_day = 10 THEN d.power_accounts END) AS "第10天有效战力人数",
    MAX(CASE WHEN d.open_day = 11 THEN d.avg_power END) AS "第11天平均战力",
    MAX(CASE WHEN d.open_day = 11 THEN d.sampled_accounts END) AS "第11天实际取样人数",
    MAX(CASE WHEN d.open_day = 11 THEN d.power_accounts END) AS "第11天有效战力人数",
    MAX(CASE WHEN d.open_day = 12 THEN d.avg_power END) AS "第12天平均战力",
    MAX(CASE WHEN d.open_day = 12 THEN d.sampled_accounts END) AS "第12天实际取样人数",
    MAX(CASE WHEN d.open_day = 12 THEN d.power_accounts END) AS "第12天有效战力人数",
    MAX(CASE WHEN d.open_day = 13 THEN d.avg_power END) AS "第13天平均战力",
    MAX(CASE WHEN d.open_day = 13 THEN d.sampled_accounts END) AS "第13天实际取样人数",
    MAX(CASE WHEN d.open_day = 13 THEN d.power_accounts END) AS "第13天有效战力人数",
    MAX(CASE WHEN d.open_day = 14 THEN d.avg_power END) AS "第14天平均战力",
    MAX(CASE WHEN d.open_day = 14 THEN d.sampled_accounts END) AS "第14天实际取样人数",
    MAX(CASE WHEN d.open_day = 14 THEN d.power_accounts END) AS "第14天有效战力人数",
    MAX(CASE WHEN d.open_day = 15 THEN d.avg_power END) AS "第15天平均战力",
    MAX(CASE WHEN d.open_day = 15 THEN d.sampled_accounts END) AS "第15天实际取样人数",
    MAX(CASE WHEN d.open_day = 15 THEN d.power_accounts END) AS "第15天有效战力人数",
    MAX(CASE WHEN d.open_day = 16 THEN d.avg_power END) AS "第16天平均战力",
    MAX(CASE WHEN d.open_day = 16 THEN d.sampled_accounts END) AS "第16天实际取样人数",
    MAX(CASE WHEN d.open_day = 16 THEN d.power_accounts END) AS "第16天有效战力人数",
    MAX(CASE WHEN d.open_day = 17 THEN d.avg_power END) AS "第17天平均战力",
    MAX(CASE WHEN d.open_day = 17 THEN d.sampled_accounts END) AS "第17天实际取样人数",
    MAX(CASE WHEN d.open_day = 17 THEN d.power_accounts END) AS "第17天有效战力人数",
    MAX(CASE WHEN d.open_day = 18 THEN d.avg_power END) AS "第18天平均战力",
    MAX(CASE WHEN d.open_day = 18 THEN d.sampled_accounts END) AS "第18天实际取样人数",
    MAX(CASE WHEN d.open_day = 18 THEN d.power_accounts END) AS "第18天有效战力人数",
    MAX(CASE WHEN d.open_day = 19 THEN d.avg_power END) AS "第19天平均战力",
    MAX(CASE WHEN d.open_day = 19 THEN d.sampled_accounts END) AS "第19天实际取样人数",
    MAX(CASE WHEN d.open_day = 19 THEN d.power_accounts END) AS "第19天有效战力人数",
    MAX(CASE WHEN d.open_day = 20 THEN d.avg_power END) AS "第20天平均战力",
    MAX(CASE WHEN d.open_day = 20 THEN d.sampled_accounts END) AS "第20天实际取样人数",
    MAX(CASE WHEN d.open_day = 20 THEN d.power_accounts END) AS "第20天有效战力人数",
    MAX(CASE WHEN d.open_day = 21 THEN d.avg_power END) AS "第21天平均战力",
    MAX(CASE WHEN d.open_day = 21 THEN d.sampled_accounts END) AS "第21天实际取样人数",
    MAX(CASE WHEN d.open_day = 21 THEN d.power_accounts END) AS "第21天有效战力人数",
    MAX(CASE WHEN d.open_day = 22 THEN d.avg_power END) AS "第22天平均战力",
    MAX(CASE WHEN d.open_day = 22 THEN d.sampled_accounts END) AS "第22天实际取样人数",
    MAX(CASE WHEN d.open_day = 22 THEN d.power_accounts END) AS "第22天有效战力人数",
    MAX(CASE WHEN d.open_day = 23 THEN d.avg_power END) AS "第23天平均战力",
    MAX(CASE WHEN d.open_day = 23 THEN d.sampled_accounts END) AS "第23天实际取样人数",
    MAX(CASE WHEN d.open_day = 23 THEN d.power_accounts END) AS "第23天有效战力人数",
    MAX(CASE WHEN d.open_day = 24 THEN d.avg_power END) AS "第24天平均战力",
    MAX(CASE WHEN d.open_day = 24 THEN d.sampled_accounts END) AS "第24天实际取样人数",
    MAX(CASE WHEN d.open_day = 24 THEN d.power_accounts END) AS "第24天有效战力人数",
    MAX(CASE WHEN d.open_day = 25 THEN d.avg_power END) AS "第25天平均战力",
    MAX(CASE WHEN d.open_day = 25 THEN d.sampled_accounts END) AS "第25天实际取样人数",
    MAX(CASE WHEN d.open_day = 25 THEN d.power_accounts END) AS "第25天有效战力人数",
    MAX(CASE WHEN d.open_day = 26 THEN d.avg_power END) AS "第26天平均战力",
    MAX(CASE WHEN d.open_day = 26 THEN d.sampled_accounts END) AS "第26天实际取样人数",
    MAX(CASE WHEN d.open_day = 26 THEN d.power_accounts END) AS "第26天有效战力人数",
    MAX(CASE WHEN d.open_day = 27 THEN d.avg_power END) AS "第27天平均战力",
    MAX(CASE WHEN d.open_day = 27 THEN d.sampled_accounts END) AS "第27天实际取样人数",
    MAX(CASE WHEN d.open_day = 27 THEN d.power_accounts END) AS "第27天有效战力人数",
    MAX(CASE WHEN d.open_day = 28 THEN d.avg_power END) AS "第28天平均战力",
    MAX(CASE WHEN d.open_day = 28 THEN d.sampled_accounts END) AS "第28天实际取样人数",
    MAX(CASE WHEN d.open_day = 28 THEN d.power_accounts END) AS "第28天有效战力人数",
    MAX(CASE WHEN d.open_day = 29 THEN d.avg_power END) AS "第29天平均战力",
    MAX(CASE WHEN d.open_day = 29 THEN d.sampled_accounts END) AS "第29天实际取样人数",
    MAX(CASE WHEN d.open_day = 29 THEN d.power_accounts END) AS "第29天有效战力人数",
    MAX(CASE WHEN d.open_day = 30 THEN d.avg_power END) AS "第30天平均战力",
    MAX(CASE WHEN d.open_day = 30 THEN d.sampled_accounts END) AS "第30天实际取样人数",
    MAX(CASE WHEN d.open_day = 30 THEN d.power_accounts END) AS "第30天有效战力人数"
FROM DayValues d
GROUP BY d.server_id, d.server_seq,
         d.payer_tier, d.tier_order, d.rank_group_order, d.rank_group
ORDER BY d.server_seq, d.tier_order, d.rank_group_order;
