/*
================================================================================
Game: Slam Dunk - GL
Description: Comprehensive KPI & LTV report split by Southeast Asia country group.
Environment: Trino
Event table: ta.v_event_21
Country mapping source: fixed_country in user_result_cluster_21
================================================================================
*/

WITH
-- 1. Scan boundary derived from the requested date selector.
ScanConfig AS (
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_21
    WHERE ${PartDate:date1}
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. Internal/test accounts.
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_21
    WHERE cluster_name = 'internal_users'
),

-- 3. User profile at account grain.
UserProfileRaw AS (
    SELECT
        "#varchar_id" AS "#account_id",
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os' THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store' THEN tag_value END) AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_21 u
    WHERE cluster_name IN (
        'fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate'
    )
    GROUP BY "#varchar_id"
),
UserProfileDetail AS (
    SELECT
        *,
        CASE
            WHEN fixed_country IN (
                '文萊', '文莱', 'Brunei', 'BN',
                '印尼', '印度尼西亞', '印度尼西亚', 'Indonesia', 'ID',
                '柬埔寨', 'Cambodia', 'KH',
                '老撾', '老挝', '寮國', '寮国', 'Laos', 'LA',
                '緬甸', '缅甸', 'Myanmar', 'MM',
                '馬來西亞', '马来西亚', 'Malaysia', 'MY',
                '菲律賓', '菲律宾', 'Philippines', 'PH',
                '新加坡', 'Singapore', 'SG',
                '東帝汶', '东帝汶', 'Timor-Leste', 'TL',
                '越南', 'Vietnam', 'VN'
            ) THEN '东南亚'
            ELSE '非东南亚'
        END AS game_version
    FROM UserProfileRaw
),

-- 4. Active-day array used for retention calculations.
AccountRetentionArrays AS (
    SELECT
        a."#account_id",
        TRANSFORM(
            ARRAY_SORT(a.return_date_array),
            d -> DATE_DIFF('day', CAST(p.fixed_regdate AS DATE), d)
        ) AS return_days_array
    FROM (
        SELECT
            "#account_id",
            ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_21
        CROSS JOIN ScanConfig sc
        WHERE "$part_date" >= CAST(sc.target_start_date AS VARCHAR)
          AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
        GROUP BY 1
    ) a
    INNER JOIN UserProfileDetail p ON a."#account_id" = p."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE CAST(p.fixed_regdate AS DATE) >= sc.target_start_date
),

-- 6. Daily paid revenue in CNY.
DailyAccountRevenue AS (
    SELECT
        e."#account_id",
        e."$part_date",
        SUM(
            CAST(JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.curamt') AS DOUBLE)
            / fx.exchange * cny.exchange
        ) AS revenue_cny
    FROM ta.v_event_21 e
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange fx
        ON e."$part_date" = fx.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.cur') = fx.currency
    LEFT JOIN ta_dim.ta_exchange cny
        ON e."$part_date" = cny.ex_date AND cny.currency = 'CNY'
    WHERE e."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND e."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
    GROUP BY 1, 2
),
AccountLtvMap AS (
    SELECT
        p."#account_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(p.fixed_regdate AS DATE), CAST(r."$part_date" AS DATE)),
            r.revenue_cny
        ) AS revenue_map
    FROM DailyAccountRevenue r
    INNER JOIN UserProfileDetail p ON r."#account_id" = p."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE CAST(p.fixed_regdate AS DATE) >= sc.target_start_date
    GROUP BY 1
),

-- 7. One cohort row per selected dimensions, including game_version.
NewAccountCohort AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(p.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(p.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(p.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(p.fixed_regdate AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN p.fixed_os ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN p.fixed_country ELSE '已合并' END AS country,
        CASE WHEN ${Selector:affcode} THEN p.fixed_affcode ELSE '已合并' END AS affcode,
        CASE WHEN ${Selector:store} THEN p.fixed_store ELSE '已合并' END AS store,
        COALESCE(p.game_version, '非东南亚') AS game_version,
        p."#account_id",
        a.return_days_array,
        l.revenue_map
    FROM UserProfileDetail p
    LEFT JOIN AccountRetentionArrays a ON p."#account_id" = a."#account_id"
    LEFT JOIN AccountLtvMap l ON p."#account_id" = l."#account_id"
    LEFT JOIN UserBlacklist b ON p."#account_id" = b."#account_id"
    CROSS JOIN ScanConfig sc
    WHERE b."#account_id" IS NULL
      AND CAST(p.fixed_regdate AS DATE) >= sc.target_start_date
),
NewAccountRRAndLTV AS (
    SELECT
        time_dimension, os_type, country, affcode, store, game_version,
        COUNT(DISTINCT "#account_id") AS new_account,
        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / NULLIF(COUNT(DISTINCT "#account_id"), 0) AS rr_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0)) AS DOUBLE) AS ltv_180
    FROM NewAccountCohort
    GROUP BY 1, 2, 3, 4, 5, 6
),

-- 7. Period KPI. Accounts without a profile tag are grouped as non-SEA.
AccountKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(e."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(e."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(e."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(e."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '已合并'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN p.fixed_os ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN p.fixed_country ELSE '已合并' END AS country,
        CASE WHEN ${Selector:affcode} THEN p.fixed_affcode ELSE '已合并' END AS affcode,
        CASE WHEN ${Selector:store} THEN p.fixed_store ELSE '已合并' END AS store,
        COALESCE(p.game_version, '非东南亚') AS game_version,
        MAX(CONCAT(
            CAST(GREATEST(
                CASE
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', CAST(e."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', CAST(e."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', CAST(e."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_TRUNC('quarter', CAST(e."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                    ELSE CAST(e."$part_date" AS DATE)
                END,
                sc.target_start_date
            ) AS VARCHAR),
            ' ~ ',
            CAST(LEAST(
                CASE
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', CAST(e."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', CAST(e."$part_date" AS DATE)))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', CAST(e."$part_date" AS DATE))))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, DATE_TRUNC('quarter', CAST(e."$part_date" AS DATE))))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                    ELSE CAST(e."$part_date" AS DATE)
                END,
                sc.target_end_date
            ) AS VARCHAR)
        )) AS date_range,
        COUNT(DISTINCT e."#account_id") AS active_account,
        COUNT(DISTINCT CASE WHEN e."$part_event" = 'PURCHASE' THEN e."#account_id" END) AS paying_account,
        SUM(CASE WHEN e."$part_event" = 'PURCHASE' THEN CAST(JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.curamt') AS DOUBLE) / fx.exchange * cny.exchange END) AS total_revenue_cny
    FROM ta.v_event_21 e
    LEFT JOIN UserProfileDetail p ON e."#account_id" = p."#account_id"
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange fx ON e."$part_date" = fx.ex_date AND JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.cur') = fx.currency
    LEFT JOIN ta_dim.ta_exchange cny ON e."$part_date" = cny.ex_date AND cny.currency = 'CNY'
    LEFT JOIN UserBlacklist b ON e."#account_id" = b."#account_id"
    WHERE b."#account_id" IS NULL
      AND e.${PartDate:date1}
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'PURCHASE')
      AND (e."$part_event" <> 'PURCHASE' OR JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT')
    GROUP BY 1, 2, 3, 4, 5, 6
),
NewAccountKPI AS (
    SELECT
        c.time_dimension, c.os_type, c.country, c.affcode, c.store, c.game_version,
        COUNT(DISTINCT CASE WHEN e."$part_event" = 'PURCHASE' THEN e."#account_id" END) AS new_paying_account,
        SUM(CASE WHEN e."$part_event" = 'PURCHASE' THEN CAST(JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.curamt') AS DOUBLE) / fx.exchange * cny.exchange END) AS new_account_revenue_cny
    FROM NewAccountCohort c
    INNER JOIN UserProfileDetail p ON c."#account_id" = p."#account_id"
    INNER JOIN ta.v_event_21 e ON c."#account_id" = e."#account_id"
    LEFT JOIN ta_dim.ta_exchange fx ON e."$part_date" = fx.ex_date AND JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.cur') = fx.currency
    LEFT JOIN ta_dim.ta_exchange cny ON e."$part_date" = cny.ex_date AND cny.currency = 'CNY'
    WHERE e.${PartDate:date1}
      AND e."$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'PURCHASE')
      AND (e."$part_event" <> 'PURCHASE' OR JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT')
      AND (
          (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(e."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(p.fixed_regdate AS DATE))) OR
          (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(e."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(p.fixed_regdate AS DATE))) OR
          (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(e."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(p.fixed_regdate AS DATE))) OR
          (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(e."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(p.fixed_regdate AS DATE))) OR
          (${Selector:timetype} = 'A')
      )
    GROUP BY 1, 2, 3, 4, 5, 6
)

SELECT
    k.time_dimension AS "时间维度",
    k.os_type,
    k.country,
    k.affcode,
    k.store,
    k.game_version AS "国家分组",
    k.date_range AS "日期范围",
    k.active_account,
    k.paying_account,
    k.total_revenue_cny,
    CAST(k.paying_account AS DOUBLE) / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS payrate,
    k.total_revenue_cny / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS arpu,
    k.total_revenue_cny / NULLIF(CAST(k.paying_account AS DOUBLE), 0.0) AS arppu,
    c.new_account,
    n.new_paying_account,
    n.new_account_revenue_cny,
    CAST(n.new_paying_account AS DOUBLE) / NULLIF(CAST(c.new_account AS DOUBLE), 0.0) AS new_account_payrate,
    n.new_account_revenue_cny / NULLIF(CAST(c.new_account AS DOUBLE), 0.0) AS new_account_arpu,
    n.new_account_revenue_cny / NULLIF(CAST(n.new_paying_account AS DOUBLE), 0.0) AS new_account_arppu,
    c.rr_1, c.rr_2, c.rr_3, c.rr_4, c.rr_5, c.rr_6, c.rr_7, c.rr_14, c.rr_30, c.rr_60, c.rr_90, c.rr_180,
    c.ltv_1, c.ltv_7, c.ltv_30, c.ltv_60, c.ltv_90, c.ltv_180
FROM AccountKPI k
LEFT JOIN NewAccountRRAndLTV c
    ON k.time_dimension = c.time_dimension
   AND k.os_type = c.os_type
   AND k.country = c.country
   AND k.affcode = c.affcode
   AND k.store = c.store
   AND k.game_version = c.game_version
LEFT JOIN NewAccountKPI n
    ON k.time_dimension = n.time_dimension
   AND k.os_type = n.os_type
   AND k.country = n.country
   AND k.affcode = n.affcode
   AND k.store = n.store
   AND k.game_version = n.game_version
ORDER BY 1 DESC, 6;
