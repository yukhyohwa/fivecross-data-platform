/*
================================================================================
Game: Kuroko's Basketball
Region: KR
Description: 2026-07-01 ~ 2026-07-12 每日新用户 / 14日未登入以上回流用户
             - 人数、首日金额(USD)
             - LTV1 ~ LTV7
             - 留存：次留、3留、4留、5留、6留、7留

Notes:
  1. LTV1 = cohort 当日收入 / cohort 人数，LTV7 = cohort D0~D6 累计收入 / cohort 人数。
  2. 回流定义：本次登录距离上一次登录 >= 14 天，且不是首登。
  3. data_end_date 固定为 2026-07-12；未成熟天数输出 NULL。
================================================================================
*/

WITH
Params AS (
    SELECT
        DATE '2026-07-01' AS start_date,
        DATE '2026-07-12' AS end_date,
        DATE '2026-07-12' AS data_end_date
),

FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

DateSpine AS (
    SELECT d AS cohort_date
    FROM Params p
    CROSS JOIN UNNEST(SEQUENCE(p.start_date, p.end_date)) AS t(d)
),

CohortTypes AS (
    SELECT 'new_user' AS cohort_type, '新用户' AS user_type_name
),

DailyLogins AS (
    SELECT DISTINCT
        v.uuid AS user_id,
        CAST(v."$part_date" AS DATE) AS log_date
    FROM ta.v_event_12 v
    CROSS JOIN Params p
    WHERE v."$part_event" = 'login'
      AND v."$part_date" >= '2023-01-01'
      AND v."$part_date" <= CAST(p.data_end_date AS VARCHAR)
      AND v.uuid IS NOT NULL AND v.uuid <> ''
      AND v."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

UserStatus AS (
    SELECT
        user_id,
        log_date,
        LAG(log_date) OVER (PARTITION BY user_id ORDER BY log_date) AS prev_log_date,
        MIN(log_date) OVER (PARTITION BY user_id) AS first_log_date
    FROM DailyLogins
),

CohortUsers AS (
    SELECT
        s.user_id,
        s.log_date AS cohort_date,
        'new_user' AS cohort_type
    FROM UserStatus s
    CROSS JOIN Params p
    WHERE s.log_date BETWEEN p.start_date AND p.end_date
      AND s.log_date = s.first_log_date
),

UserRevenue AS (
    SELECT
        r.uuid AS user_id,
        CAST(r."$part_date" AS DATE) AS pay_date,
        SUM(CAST(r.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS rev_usd
    FROM ta.v_event_12 r
    CROSS JOIN Params p
    LEFT JOIN (
        SELECT
            ex_date,
            currency,
            ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date
        AND r.pay_currency = ex.currency
    WHERE r."$part_event" = 'charge'
      AND r."$part_date" >= CAST(p.start_date AS VARCHAR)
      AND r."$part_date" <= CAST(p.data_end_date AS VARCHAR)
      AND (r.sandbox = false OR r.sandbox IS NULL)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r.uuid IS NOT NULL AND r.uuid <> ''
      AND r."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1, 2
),

CohortRevenue AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        DATE_DIFF('day', c.cohort_date, p.data_end_date) AS mature_days,
        COALESCE(r.rev_usd, 0.0) AS rev_usd,
        DATE_DIFF('day', c.cohort_date, r.pay_date) AS ltv_day
    FROM CohortUsers c
    CROSS JOIN Params p
    LEFT JOIN UserRevenue r
        ON c.user_id = r.user_id
       AND DATE_DIFF('day', c.cohort_date, r.pay_date) BETWEEN 0 AND 11
),

UserLtvAgg AS (
    SELECT
        user_id,
        cohort_date,
        cohort_type,
        MAX(mature_days) AS mature_days,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 0 THEN rev_usd ELSE 0.0 END) AS rev_ltv1,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 1 THEN rev_usd ELSE 0.0 END) AS rev_ltv2,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 2 THEN rev_usd ELSE 0.0 END) AS rev_ltv3,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 3 THEN rev_usd ELSE 0.0 END) AS rev_ltv4,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 4 THEN rev_usd ELSE 0.0 END) AS rev_ltv5,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 5 THEN rev_usd ELSE 0.0 END) AS rev_ltv6,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 6 THEN rev_usd ELSE 0.0 END) AS rev_ltv7,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 7 THEN rev_usd ELSE 0.0 END) AS rev_ltv8,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 8 THEN rev_usd ELSE 0.0 END) AS rev_ltv9,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 9 THEN rev_usd ELSE 0.0 END) AS rev_ltv10,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 10 THEN rev_usd ELSE 0.0 END) AS rev_ltv11,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 11 THEN rev_usd ELSE 0.0 END) AS rev_ltv12
    FROM CohortRevenue
    GROUP BY 1, 2, 3
),

CohortLtvDaily AS (
    SELECT
        cohort_date,
        cohort_type,
        COUNT(*) AS users,
        SUM(rev_ltv1) AS amount_day1_usd,

        COUNT_IF(mature_days >= 0) AS ltv1_den,
        SUM(CASE WHEN mature_days >= 0 THEN rev_ltv1 ELSE 0.0 END) AS ltv1_rev,
        COUNT_IF(mature_days >= 1) AS ltv2_den,
        SUM(CASE WHEN mature_days >= 1 THEN rev_ltv2 ELSE 0.0 END) AS ltv2_rev,
        COUNT_IF(mature_days >= 2) AS ltv3_den,
        SUM(CASE WHEN mature_days >= 2 THEN rev_ltv3 ELSE 0.0 END) AS ltv3_rev,
        COUNT_IF(mature_days >= 3) AS ltv4_den,
        SUM(CASE WHEN mature_days >= 3 THEN rev_ltv4 ELSE 0.0 END) AS ltv4_rev,
        COUNT_IF(mature_days >= 4) AS ltv5_den,
        SUM(CASE WHEN mature_days >= 4 THEN rev_ltv5 ELSE 0.0 END) AS ltv5_rev,
        COUNT_IF(mature_days >= 5) AS ltv6_den,
        SUM(CASE WHEN mature_days >= 5 THEN rev_ltv6 ELSE 0.0 END) AS ltv6_rev,
        COUNT_IF(mature_days >= 6) AS ltv7_den,
        SUM(CASE WHEN mature_days >= 6 THEN rev_ltv7 ELSE 0.0 END) AS ltv7_rev,
        COUNT_IF(mature_days >= 7) AS ltv8_den,
        SUM(CASE WHEN mature_days >= 7 THEN rev_ltv8 ELSE 0.0 END) AS ltv8_rev,
        COUNT_IF(mature_days >= 8) AS ltv9_den,
        SUM(CASE WHEN mature_days >= 8 THEN rev_ltv9 ELSE 0.0 END) AS ltv9_rev,
        COUNT_IF(mature_days >= 9) AS ltv10_den,
        SUM(CASE WHEN mature_days >= 9 THEN rev_ltv10 ELSE 0.0 END) AS ltv10_rev,
        COUNT_IF(mature_days >= 10) AS ltv11_den,
        SUM(CASE WHEN mature_days >= 10 THEN rev_ltv11 ELSE 0.0 END) AS ltv11_rev,
        COUNT_IF(mature_days >= 11) AS ltv12_den,
        SUM(CASE WHEN mature_days >= 11 THEN rev_ltv12 ELSE 0.0 END) AS ltv12_rev
    FROM UserLtvAgg
    GROUP BY 1, 2
),

CohortRetentionDaily AS (
    SELECT
        c.cohort_date,
        c.cohort_type,
        COUNT(DISTINCT CASE WHEN DATE_DIFF('day', c.cohort_date, l.log_date) = 1 THEN c.user_id END) AS retain_d1,
        COUNT(DISTINCT CASE WHEN DATE_DIFF('day', c.cohort_date, l.log_date) = 2 THEN c.user_id END) AS retain_d2,
        COUNT(DISTINCT CASE WHEN DATE_DIFF('day', c.cohort_date, l.log_date) = 3 THEN c.user_id END) AS retain_d3,
        COUNT(DISTINCT CASE WHEN DATE_DIFF('day', c.cohort_date, l.log_date) = 4 THEN c.user_id END) AS retain_d4,
        COUNT(DISTINCT CASE WHEN DATE_DIFF('day', c.cohort_date, l.log_date) = 5 THEN c.user_id END) AS retain_d5,
        COUNT(DISTINCT CASE WHEN DATE_DIFF('day', c.cohort_date, l.log_date) = 6 THEN c.user_id END) AS retain_d6
    FROM CohortUsers c
    LEFT JOIN DailyLogins l
        ON c.user_id = l.user_id
       AND DATE_DIFF('day', c.cohort_date, l.log_date) BETWEEN 1 AND 6
    GROUP BY 1, 2
),

OverallDAU AS (
    SELECT
        CAST("$part_date" AS DATE) AS log_date,
        COUNT(DISTINCT "#user_id") AS dau
    FROM ta.v_event_12
    CROSS JOIN Params p
    WHERE "$part_event" = 'login'
      AND "$part_date" >= CAST(p.start_date AS VARCHAR)
      AND "$part_date" <= CAST(p.end_date AS VARCHAR)
      AND "#user_id" IS NOT NULL
      AND "#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
),

OverallRevenue AS (
    SELECT
        CAST(r."$part_date" AS DATE) AS pay_date,
        SUM(CAST(r.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0)) AS total_rev_usd
    FROM ta.v_event_12 r
    CROSS JOIN Params p
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date AND r.pay_currency = ex.currency
    WHERE r."$part_event" = 'charge'
      AND r."$part_date" >= CAST(p.start_date AS VARCHAR)
      AND r."$part_date" <= CAST(p.end_date AS VARCHAR)
      AND (r.sandbox = false OR r.sandbox IS NULL)
      AND (r.order_id NOT IN ('11') OR r.order_id IS NULL)
      AND r."#user_id" IS NOT NULL
      AND r."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
    GROUP BY 1
)

SELECT
    CAST(d.cohort_date AS VARCHAR) AS "日期",
    COALESCE(od.dau, 0) AS "当日大盘DAU",
    ROUND(COALESCE(orv.total_rev_usd, 0.0), 2) AS "当日大盘总流水(USD)",
    COALESCE(l.users, 0) AS "新用户数",
    ROUND(COALESCE(l.amount_day1_usd, 0.0), 2) AS "新用户首日金额(USD)",

    ROUND(TRY(l.ltv1_rev / NULLIF(l.ltv1_den, 0)), 2) AS "LTV1",
    ROUND(TRY(l.ltv2_rev / NULLIF(l.ltv2_den, 0)), 2) AS "LTV2",
    ROUND(TRY(l.ltv3_rev / NULLIF(l.ltv3_den, 0)), 2) AS "LTV3",
    ROUND(TRY(l.ltv4_rev / NULLIF(l.ltv4_den, 0)), 2) AS "LTV4",
    ROUND(TRY(l.ltv5_rev / NULLIF(l.ltv5_den, 0)), 2) AS "LTV5",
    ROUND(TRY(l.ltv6_rev / NULLIF(l.ltv6_den, 0)), 2) AS "LTV6",
    ROUND(TRY(l.ltv7_rev / NULLIF(l.ltv7_den, 0)), 2) AS "LTV7",
    ROUND(TRY(l.ltv8_rev / NULLIF(l.ltv8_den, 0)), 2) AS "LTV8",
    ROUND(TRY(l.ltv9_rev / NULLIF(l.ltv9_den, 0)), 2) AS "LTV9",
    ROUND(TRY(l.ltv10_rev / NULLIF(l.ltv10_den, 0)), 2) AS "LTV10",
    ROUND(TRY(l.ltv11_rev / NULLIF(l.ltv11_den, 0)), 2) AS "LTV11",
    ROUND(TRY(l.ltv12_rev / NULLIF(l.ltv12_den, 0)), 2) AS "LTV12",

    ROUND(COALESCE(l.ltv1_rev, 0.0), 2) AS "Rev1",
    ROUND(COALESCE(l.ltv2_rev, 0.0), 2) AS "Rev2",
    ROUND(COALESCE(l.ltv3_rev, 0.0), 2) AS "Rev3",
    ROUND(COALESCE(l.ltv4_rev, 0.0), 2) AS "Rev4",
    ROUND(COALESCE(l.ltv5_rev, 0.0), 2) AS "Rev5",
    ROUND(COALESCE(l.ltv6_rev, 0.0), 2) AS "Rev6",
    ROUND(COALESCE(l.ltv7_rev, 0.0), 2) AS "Rev7",
    ROUND(COALESCE(l.ltv8_rev, 0.0), 2) AS "Rev8",
    ROUND(COALESCE(l.ltv9_rev, 0.0), 2) AS "Rev9",
    ROUND(COALESCE(l.ltv10_rev, 0.0), 2) AS "Rev10",
    ROUND(COALESCE(l.ltv11_rev, 0.0), 2) AS "Rev11",
    ROUND(COALESCE(l.ltv12_rev, 0.0), 2) AS "Rev12",

    CASE
        WHEN DATE_DIFF('day', d.cohort_date, p.data_end_date) >= 1
        THEN CAST(ROUND(TRY(CAST(COALESCE(r.retain_d1, 0) AS DOUBLE) / NULLIF(l.users, 0) * 100), 2) AS VARCHAR) || '%'
    END AS "次留",
    CASE
        WHEN DATE_DIFF('day', d.cohort_date, p.data_end_date) >= 2
        THEN CAST(ROUND(TRY(CAST(COALESCE(r.retain_d2, 0) AS DOUBLE) / NULLIF(l.users, 0) * 100), 2) AS VARCHAR) || '%'
    END AS "3留",
    CASE
        WHEN DATE_DIFF('day', d.cohort_date, p.data_end_date) >= 3
        THEN CAST(ROUND(TRY(CAST(COALESCE(r.retain_d3, 0) AS DOUBLE) / NULLIF(l.users, 0) * 100), 2) AS VARCHAR) || '%'
    END AS "4留",
    CASE
        WHEN DATE_DIFF('day', d.cohort_date, p.data_end_date) >= 4
        THEN CAST(ROUND(TRY(CAST(COALESCE(r.retain_d4, 0) AS DOUBLE) / NULLIF(l.users, 0) * 100), 2) AS VARCHAR) || '%'
    END AS "5留",
    CASE
        WHEN DATE_DIFF('day', d.cohort_date, p.data_end_date) >= 5
        THEN CAST(ROUND(TRY(CAST(COALESCE(r.retain_d5, 0) AS DOUBLE) / NULLIF(l.users, 0) * 100), 2) AS VARCHAR) || '%'
    END AS "6留",
    CASE
        WHEN DATE_DIFF('day', d.cohort_date, p.data_end_date) >= 6
        THEN CAST(ROUND(TRY(CAST(COALESCE(r.retain_d6, 0) AS DOUBLE) / NULLIF(l.users, 0) * 100), 2) AS VARCHAR) || '%'
    END AS "7留"
FROM DateSpine d
CROSS JOIN CohortTypes t
CROSS JOIN Params p
LEFT JOIN CohortLtvDaily l
    ON d.cohort_date = l.cohort_date
   AND t.cohort_type = l.cohort_type
LEFT JOIN CohortRetentionDaily r
    ON d.cohort_date = r.cohort_date
   AND t.cohort_type = r.cohort_type
LEFT JOIN OverallDAU od
    ON d.cohort_date = od.log_date
LEFT JOIN OverallRevenue orv
    ON d.cohort_date = orv.pay_date
ORDER BY d.cohort_date;
