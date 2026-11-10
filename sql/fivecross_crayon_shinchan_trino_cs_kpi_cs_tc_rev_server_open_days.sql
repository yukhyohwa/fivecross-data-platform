/*
繁中 App18 OBT｜分服每日付费。
${PartDate:date1}：开服记录筛选范围；${PartDate:date2}：付费日期范围。
开服时间取 date1 范围内该服最早的有效 new_role 日期。
仅靠范围内 new_role 无法区分旧服新增角色与真正新开服务器；
不额外读取范围外注册历史，不将此日期声明为运营配置开服日期。
充值直接使用 charge 事件所属 server_id，不要求存在该账号的注册记录。
黑名单：is_water_new、is_windows_new；排除 sandbox/is_freebuy/COIN。
收入 USD = pay_amount / 当日同币种 exchange；同日同币种汇率先去重。
汇率缺失、冲突、非正，或金额无法转换时，该服当日收入为 NULL，并列异常订单数。
沿用 charge 流水口径，不额外做订单去重或扣除退款。不补无充值日期。
两个日期参数独立筛选，开服记录日期不额外限制付费日期。
*/
WITH
Blacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
Servers AS (
    SELECT
        TRIM(CAST(v.server_id AS VARCHAR)) AS server_id,
        MIN(CAST(v."$part_date" AS DATE)) AS open_date
    FROM ta.v_event_18 v
    LEFT JOIN Blacklist b
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'new_role'
      AND NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),
ExchangeRates AS (
    SELECT
        CAST(ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
        CASE
            WHEN COUNT_IF(
                TRY_CAST(exchange AS DOUBLE) IS NULL
                OR TRY_CAST(exchange AS DOUBLE) <= 0
            ) = 0
            AND MIN(TRY_CAST(exchange AS DOUBLE)) = MAX(TRY_CAST(exchange AS DOUBLE))
            THEN MAX(TRY_CAST(exchange AS DOUBLE))
        END AS exchange
    FROM ta_dim.ta_exchange
    GROUP BY 1, 2
),
Charges AS (
    SELECT
        TRIM(CAST(v.server_id AS VARCHAR)) AS server_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS pay_date,
        TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(e.exchange, 0) AS revenue_usd,
        CASE
            WHEN TRY_CAST(v.pay_amount AS DOUBLE) IS NULL OR e.exchange IS NULL
            THEN 1 ELSE 0
        END AS invalid_revenue
    FROM ta.v_event_18 v
    LEFT JOIN Blacklist b
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ExchangeRates e
      ON v."$part_date" = e.ex_date
     AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = e.currency
    WHERE v.${PartDate:date2}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'charge'
      AND NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
),
DailyPayment AS (
    SELECT
        server_id,
        pay_date,
        COUNT(DISTINCT fc_id) AS pay_users,
        COUNT(*) AS pay_orders,
        CASE WHEN SUM(invalid_revenue) > 0 THEN NULL
             ELSE SUM(revenue_usd)
        END AS revenue_usd,
        SUM(invalid_revenue) AS invalid_orders
    FROM Charges
    GROUP BY 1, 2
)
SELECT
    s.server_id AS "服务器",
    s.open_date AS "开服时间",
    p.pay_date AS "付费日期",
    p.pay_users AS "付费人数",
    p.pay_orders AS "充值笔数",
    ROUND(p.revenue_usd, 2) AS "充值收入USD",
    p.invalid_orders AS "异常金额订单数"
FROM Servers s
JOIN DailyPayment p ON s.server_id = p.server_id
ORDER BY p.pay_date DESC, s.open_date, s.server_id;
