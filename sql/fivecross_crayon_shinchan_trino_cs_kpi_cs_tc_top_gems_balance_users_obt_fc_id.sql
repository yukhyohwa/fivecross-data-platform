/*
App18 TC OBT: gem balance Top 50 by role (#account_id).
fc_id identifies the account; account_id identifies the ranked role.
fc_id is displayed and matches the OBT blacklist; roles are not merged.
Balance: v.${PartDate:date1}. No registration-history dependency.
Historical charge and latest login/new_role name: OBT start through selected end.
The selected end comes from an in-memory calendar filtered by the same parameter.
Each daily SEQUENCE contains at most 366 entries; no log scan for date bounds.
Same-time conflicting balance records require an event sequence to resolve.
Exchange fallback and the six output column names follow the existing report.
*/
WITH
SelectedDates AS (
    SELECT CAST(v."$part_date" AS DATE) AS dt
    FROM UNNEST(
        SEQUENCE(DATE '2026-01-01', DATE_TRUNC('year', CURRENT_DATE), INTERVAL '1' YEAR)
    ) AS y(year_start)
    CROSS JOIN UNNEST(
        TRANSFORM(
            SEQUENCE(y.year_start,
                DATE_ADD('day', -1, DATE_ADD('year', 1, y.year_start)), INTERVAL '1' DAY),
            d -> CAST(d AS VARCHAR)
        )
    ) AS v("$part_date")
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
),
ReportEnd AS (
    SELECT CAST(MAX(dt) AS VARCHAR) AS end_date FROM SelectedDates
),
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new', 'internal_users_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
BalanceEvents AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        FILTER(v.a_rst, x -> TRY_CAST(x.id AS BIGINT) = 10206) AS changes
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'item_change'
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),
BalanceRanked AS (
    SELECT
        e.fc_id, e.account_id, u.balance,
        ROW_NUMBER() OVER (
            PARTITION BY e.account_id
            ORDER BY e.event_time DESC NULLS LAST, e.account_id ASC NULLS LAST
        ) AS rn
    FROM BalanceEvents e
    CROSS JOIN UNNEST(
        TRANSFORM(e.changes, x -> TRY_CAST(x.after AS BIGINT))
    ) AS u(balance)
),
TopUsers AS (
    SELECT fc_id, account_id, balance,
        ROW_NUMBER() OVER (ORDER BY balance DESC NULLS LAST, account_id ASC) AS rank_num
    FROM BalanceRanked
    WHERE rn = 1
    ORDER BY balance DESC NULLS LAST, account_id ASC
    LIMIT 50
),
LatestRoleName AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        MAX_BY(TRIM(CAST(v.role_name AS VARCHAR)),
               CAST(v."#event_time" AS TIMESTAMP)) AS role_name
    FROM ta.v_event_18 v
    CROSS JOIN ReportEnd r
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v."$part_date" BETWEEN '2026-10-14' AND r.end_date
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.role_name AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),
ExchangeRates AS (
    SELECT
        CAST(ex.ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(ex.currency AS VARCHAR))) AS currency,
        MAX(TRY_CAST(ex.exchange AS DOUBLE)) AS exchange
    FROM ta_dim.ta_exchange ex
    CROSS JOIN ReportEnd r
    WHERE CAST(ex.ex_date AS VARCHAR) BETWEEN '2026-10-14' AND r.end_date
    GROUP BY 1, 2
),
HistoricalCharge AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        SUM(TRY_CAST(v.pay_amount AS DOUBLE)
            / COALESCE(NULLIF(ex.exchange, 0), 1.0)) AS total_charge
    FROM ta.v_event_18 v
    CROSS JOIN ReportEnd r
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ExchangeRates ex
      ON v."$part_date" = ex.ex_date
     AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = ex.currency
    WHERE v."$part_date" BETWEEN '2026-10-14' AND r.end_date
      AND v."$part_event" = 'charge'
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
    GROUP BY 1
)
SELECT
    t.rank_num AS "排名",
    t.fc_id,
    t.account_id,
    n.role_name AS "昵称",
    t.balance / 100.0 AS "晶钻余额",
    ROUND(COALESCE(c.total_charge, 0), 0) AS "历史累计充值金额(USD)"
FROM TopUsers t
LEFT JOIN LatestRoleName n ON t.account_id = n.account_id
LEFT JOIN HistoricalCharge c ON t.account_id = c.account_id
ORDER BY t.rank_num ASC;
