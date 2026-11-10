/*
繁体正式服 App 18 / Trino，OBT 起点 2026-10-14。
数数日期参数使用 ${PartDate:date1}；统计截止日自动取所选分区的最大日期。
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
/* 滚服追踪：在序号更小的服先创角，之后在当前服创角，同一 fc_id 为一账号。
旧服和当前服金额使用同一名单；旧服累计到报表截止日，包括转服后继续在旧服充值。
若需转服时点口径，另按当前服首次创角时间截断旧服订单。本报表不受30天限制。
账号可在多个目标服入组，跨行金额不可直接相加作为独立总收入。
滚服付费账号指滚服账号中，在当前服至少产生过一笔有效 charge 的账号；
滚服付费率 = 滚服付费账号数 / 滚服账号数。汇率异常影响金额，不影响付费账号判断。
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

PreviousServers AS (
    SELECT cur.fc_id, cur.server_id AS current_server_id, prev.server_id AS previous_server_id
    FROM Registrations cur
    JOIN Servers cs ON cur.server_id = cs.server_id
    JOIN Registrations prev ON cur.fc_id = prev.fc_id AND prev.create_time < cur.create_time
    JOIN Servers ps ON prev.server_id = ps.server_id AND ps.server_seq < cs.server_seq
),
ReplayAccounts AS (
    SELECT DISTINCT fc_id, current_server_id FROM PreviousServers
),
AccountServerRevenue AS (
    SELECT fc_id, server_id, SUM(revenue_usd) AS revenue_usd,
           SUM(invalid_revenue) AS invalid_orders
    FROM Charges GROUP BY 1, 2
),
PreviousRevenue AS (
    SELECT p.current_server_id, SUM(COALESCE(r.revenue_usd, 0)) AS revenue_usd,
           SUM(COALESCE(r.invalid_orders, 0)) AS invalid_orders
    FROM PreviousServers p
    LEFT JOIN AccountServerRevenue r
      ON p.fc_id = r.fc_id AND p.previous_server_id = r.server_id
    GROUP BY 1
),
CurrentRevenue AS (
    SELECT a.current_server_id, COUNT(*) AS replay_accounts,
           COUNT_IF(r.fc_id IS NOT NULL) AS replay_payer_accounts,
           SUM(COALESCE(r.revenue_usd, 0)) AS revenue_usd,
           SUM(COALESCE(r.invalid_orders, 0)) AS invalid_orders
    FROM ReplayAccounts a
    LEFT JOIN AccountServerRevenue r ON a.fc_id = r.fc_id AND a.current_server_id = r.server_id
    GROUP BY 1
)
SELECT s.server_id AS "服务器",
       CASE WHEN COALESCE(p.invalid_orders, 0) > 0 THEN NULL ELSE COALESCE(p.revenue_usd, 0) END AS "旧服累计充值USD",
       CASE WHEN COALESCE(r.invalid_orders, 0) > 0 THEN NULL ELSE COALESCE(r.revenue_usd, 0) END AS "当前服累计充值USD",
       COALESCE(r.replay_accounts, 0) AS "滚服账号数",
       COALESCE(r.replay_payer_accounts, 0) AS "滚服付费账号数",
       ROUND(
           COALESCE(r.replay_payer_accounts, 0) * 100.0
           / NULLIF(COALESCE(r.replay_accounts, 0), 0),
           2
       ) AS "滚服付费率%",
       COALESCE(p.invalid_orders, 0) AS "旧服异常金额订单数",
       COALESCE(r.invalid_orders, 0) AS "当前服异常金额订单数",
       s.open_time AS "推定开服时间", s.open_date AS "开服日期"
FROM Servers s
LEFT JOIN PreviousRevenue p ON s.server_id = p.current_server_id
LEFT JOIN CurrentRevenue r ON s.server_id = r.current_server_id
ORDER BY s.open_time;
