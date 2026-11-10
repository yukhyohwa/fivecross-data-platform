/*
繁体正式服 App 18 / Trino：分服开服首日新增 cohort 的 LTV1–30。
数数日期参数：${PartDate:date1}。截止日取所选分区的最大日期；选区只决定截止日，
注册和收入从 OBT 起点 2026-10-14 扫描，避免截断 cohort 历史。

行=服务器；列=LTV1_USD ~ LTV30_USD。
LTVN = 该服开服首日新增账号在开服第1~N个自然日的累计同服收入USD
       / 该服开服首日新增账号数（包括未付费账号；分母固定）。
第1天为开服自然日，非注册后的滚动24小时；第2天及以后注册的账号不纳入。
一账号一服保留首次 OBT 创角，同一 fc_id 跨服时可分别进入各服cohort。
仅计算同服且不早于首次创角的有效 charge；未扣退款，依赖订单不重复上报。

沿用所给SQL实际黑名单：is_water_new、is_windows_new；internal_users_new 暂不启用。
开服日为首个有效 new_role 的自然日；同日开服顺序按ID排序，须结合业务核验。
收入=pay_amount / 当日同币种 exchange；排除 sandbox、is_freebuy、COIN。
汇率去重及金额有效性判定沿用原SQL：汇率冲突/缺失/非正或金额无法转为DOUBLE，
则该订单所在日及之后的累计LTV为NULL。此前不受影响；异常订单数仅计一次。
尚未到达的日龄=NULL；已到达且cohort无订单=0；截止日未结束时保留部分日值。
max_open_days默认30，扩展时须同步修改透视列。LTV保留4位小数，单位USD/账号。
已通过Trino语法解析及转译后的模拟数据执行验证；尚未在真实Trino上执行。
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
    WHERE cluster_name IN ('is_water_new', 'is_windows_new') -- 与原SQL一致：暂不排除 internal_users_new 
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
    SELECT r.server_id, MIN(r.create_date) AS open_date
    FROM RegistrationRows r
    LEFT JOIN Blacklist b ON r.fc_id = b.fc_id
    WHERE r.server_id IS NOT NULL
      AND r.fc_id IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),
Servers AS (
    SELECT s.*, ROW_NUMBER() OVER (
               ORDER BY open_date,
                        TRY_CAST(REGEXP_EXTRACT(server_id, '([0-9]+)', 1) AS BIGINT) NULLS LAST,
                        server_id) AS server_seq
    FROM ServerDates s CROSS JOIN Config c
    WHERE s.open_date BETWEEN c.obt_start_date AND c.report_end_date
),

Registrations AS (
    SELECT r.fc_id, r.server_id, MIN(r.create_time) AS create_time
    FROM RegistrationRows r
    LEFT JOIN Blacklist b ON r.fc_id = b.fc_id
    WHERE r.fc_id IS NOT NULL AND r.server_id IS NOT NULL
      AND r.create_time IS NOT NULL AND b.fc_id IS NULL
    GROUP BY 1, 2
),
-- 分母固定：仅该服开服自然日首次创角的账号；后续注册账号不进入本cohort。
CohortRegistrations AS (
    SELECT r.fc_id, r.server_id, r.create_time
    FROM Registrations r
    JOIN Servers s ON r.server_id = s.server_id
    WHERE CAST(r.create_time AS DATE) = s.open_date
),
CohortSizes AS (
    SELECT server_id, COUNT(*) AS cohort_users
    FROM CohortRegistrations
    GROUP BY 1
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
    JOIN CohortRegistrations r
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
ServerDays AS (
    SELECT s.*, n AS open_day, DATE_ADD('day', n - 1, s.open_date) AS stat_date
    FROM Servers s CROSS JOIN Config c
    CROSS JOIN UNNEST(SEQUENCE(1, c.max_open_days)) AS t(n)
),
DailyRevenue AS (
    SELECT server_id, pay_date, SUM(revenue_usd) AS revenue_usd,
           SUM(invalid_revenue) AS invalid_orders
    FROM Charges GROUP BY 1, 2
),
DayValues AS (
    SELECT d.*,
           CASE WHEN d.stat_date > c.report_end_date THEN NULL
                WHEN COALESCE(r.invalid_orders, 0) > 0 THEN NULL
                ELSE COALESCE(r.revenue_usd, 0) END AS revenue_usd,
           COALESCE(r.invalid_orders, 0) AS invalid_orders
    FROM ServerDays d CROSS JOIN Config c
    LEFT JOIN DailyRevenue r ON d.server_id = r.server_id AND d.stat_date = r.pay_date
),
CumulativeValues AS (
    SELECT d.*,
           SUM(COALESCE(d.revenue_usd, 0)) OVER (
               PARTITION BY d.server_id ORDER BY d.open_day
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS cumulative_revenue_usd,
           SUM(d.invalid_orders) OVER (
               PARTITION BY d.server_id ORDER BY d.open_day
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS cumulative_invalid_orders
    FROM DayValues d
),
LTVValues AS (
    SELECT d.*, n.cohort_users,
           CASE WHEN d.stat_date > c.report_end_date THEN NULL
                WHEN d.cumulative_invalid_orders > 0 THEN NULL
                ELSE d.cumulative_revenue_usd / NULLIF(n.cohort_users, 0)
           END AS ltv_usd
    FROM CumulativeValues d
    CROSS JOIN Config c
    LEFT JOIN CohortSizes n ON d.server_id = n.server_id
)
SELECT d.server_id AS "服务器", d.open_date AS "开服日期",
       MAX(d.cohort_users) AS "开服首日新增账号",
       ROUND(MAX(CASE WHEN d.open_day = 1 THEN d.ltv_usd END), 4) AS "LTV1_USD",
       ROUND(MAX(CASE WHEN d.open_day = 2 THEN d.ltv_usd END), 4) AS "LTV2_USD",
       ROUND(MAX(CASE WHEN d.open_day = 3 THEN d.ltv_usd END), 4) AS "LTV3_USD",
       ROUND(MAX(CASE WHEN d.open_day = 4 THEN d.ltv_usd END), 4) AS "LTV4_USD",
       ROUND(MAX(CASE WHEN d.open_day = 5 THEN d.ltv_usd END), 4) AS "LTV5_USD",
       ROUND(MAX(CASE WHEN d.open_day = 6 THEN d.ltv_usd END), 4) AS "LTV6_USD",
       ROUND(MAX(CASE WHEN d.open_day = 7 THEN d.ltv_usd END), 4) AS "LTV7_USD",
       ROUND(MAX(CASE WHEN d.open_day = 8 THEN d.ltv_usd END), 4) AS "LTV8_USD",
       ROUND(MAX(CASE WHEN d.open_day = 9 THEN d.ltv_usd END), 4) AS "LTV9_USD",
       ROUND(MAX(CASE WHEN d.open_day = 10 THEN d.ltv_usd END), 4) AS "LTV10_USD",
       ROUND(MAX(CASE WHEN d.open_day = 11 THEN d.ltv_usd END), 4) AS "LTV11_USD",
       ROUND(MAX(CASE WHEN d.open_day = 12 THEN d.ltv_usd END), 4) AS "LTV12_USD",
       ROUND(MAX(CASE WHEN d.open_day = 13 THEN d.ltv_usd END), 4) AS "LTV13_USD",
       ROUND(MAX(CASE WHEN d.open_day = 14 THEN d.ltv_usd END), 4) AS "LTV14_USD",
       ROUND(MAX(CASE WHEN d.open_day = 15 THEN d.ltv_usd END), 4) AS "LTV15_USD",
       ROUND(MAX(CASE WHEN d.open_day = 16 THEN d.ltv_usd END), 4) AS "LTV16_USD",
       ROUND(MAX(CASE WHEN d.open_day = 17 THEN d.ltv_usd END), 4) AS "LTV17_USD",
       ROUND(MAX(CASE WHEN d.open_day = 18 THEN d.ltv_usd END), 4) AS "LTV18_USD",
       ROUND(MAX(CASE WHEN d.open_day = 19 THEN d.ltv_usd END), 4) AS "LTV19_USD",
       ROUND(MAX(CASE WHEN d.open_day = 20 THEN d.ltv_usd END), 4) AS "LTV20_USD",
       ROUND(MAX(CASE WHEN d.open_day = 21 THEN d.ltv_usd END), 4) AS "LTV21_USD",
       ROUND(MAX(CASE WHEN d.open_day = 22 THEN d.ltv_usd END), 4) AS "LTV22_USD",
       ROUND(MAX(CASE WHEN d.open_day = 23 THEN d.ltv_usd END), 4) AS "LTV23_USD",
       ROUND(MAX(CASE WHEN d.open_day = 24 THEN d.ltv_usd END), 4) AS "LTV24_USD",
       ROUND(MAX(CASE WHEN d.open_day = 25 THEN d.ltv_usd END), 4) AS "LTV25_USD",
       ROUND(MAX(CASE WHEN d.open_day = 26 THEN d.ltv_usd END), 4) AS "LTV26_USD",
       ROUND(MAX(CASE WHEN d.open_day = 27 THEN d.ltv_usd END), 4) AS "LTV27_USD",
       ROUND(MAX(CASE WHEN d.open_day = 28 THEN d.ltv_usd END), 4) AS "LTV28_USD",
       ROUND(MAX(CASE WHEN d.open_day = 29 THEN d.ltv_usd END), 4) AS "LTV29_USD",
       ROUND(MAX(CASE WHEN d.open_day = 30 THEN d.ltv_usd END), 4) AS "LTV30_USD",
       SUM(d.invalid_orders) AS "展示日龄内异常金额订单数"
FROM LTVValues d
GROUP BY d.server_id, d.server_seq, d.open_date
ORDER BY d.server_seq;
