/*
================================================================================
Game    : Crayon Shin-chan (蜡笔小新)
Region  : TC OBT，2026-10-14 起，与 CBT 共用 App 18
Table   : ta.v_event_18 / user_result_cluster_18 / ta_dim.ta_exchange
Purpose : fc_id 账号 KPI，含区服维度，实时留存与 LTV。
Parameters: ${PartDate:date1}; ${Selector:timetype}=D/W/M/S/A;
            ${Selector:ostype}, ${Selector:country}, ${Selector:zone} 为布尔选择器。

1. new_role/login/charge 直接按 TRIM(CAST(fc_id AS VARCHAR)) 统计，排除 NULL/空串。
   在 2026-10-14 起的全部 OBT 创角历史中取首次 new_role，再筛选注册 cohort。
   不使用 fixed_* 标签，不把筛选期内再次创角当新增，不混入 CBT 创角。
2. 注册日期采用 $part_date，按 #event_time 排首次创角；OS、country、server_id
   均取该记录。区服为首次注册区服，同账号跨服仍只归一个区服；未知区服单列。
3. 地区归并为港澳台/其他，包含 TW/TWN、HK/HKG、MO/MAC 等别名。
4. 黑名单直接按 #varchar_id=fc_id 关联 internal_users_new、is_water_new、is_windows_new，
   所有 KPI、留存、LTV 和新增付费一致排除。
5. 保持本版实时口径：观察截至 CURRENT_DATE（含今日），全部 cohort 账号作为
   各档留存/LTV 分母，不做成熟过滤。尚未到达的留存日计未回访，长期 LTV 为
   已观察到的累计值，不代表已成熟的完整生命周期 LTV。
6. 活跃沿用 new_role/login/有效 charge 并集，留存使用 new_role/login。
   无 OBT 创角档案的事件不计入；第 N 天留存取日龄 N-1，LTV_N 为日龄 [0,N-1]。
7. 收入排除 sandbox/is_freebuy/COIN，按 pay_amount / 当日同币种 exchange 换算。
   相同汇率重复行去重；缺失/非正/冲突汇率或非法金额使受影响收入及 LTV 返回 NULL，
   不默认按 1 换算。仍按 charge 事件统计，要求成功订单不重复上报；流水未扣退款。
8. 输出字段名、顺序沿用所提供 SQL，包括“设备”“新增当日流水(USD)”等原名。
   “设备”实际按 fc_id 账号计数；新增当日流水随 D/W/M/S/A 为新增当期流水。
9. 报表日期须连续，边界由选中分区实际事件推导；使用数数配置的业务时区。
================================================================================
*/
WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date,
           CURRENT_DATE AS observe_end_date
),
ScanConfig AS (
    SELECT MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
           MAX(CAST(v."$part_date" AS DATE)) AS target_end_date,
           MAX(c.observe_end_date) AS observe_end_date,
           MAX(c.obt_start_date) AS obt_start_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE ${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(CURRENT_DATE AS VARCHAR)
      AND v."$part_event" IN ('new_role', 'login', 'charge')
),
AccountBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
-- 全部 OBT 创角历史，不能在此应用 ${PartDate:date1}。
AccountRegistrationRanked AS (
    SELECT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
           CAST(v."$part_date" AS DATE) AS reg_date,
           COALESCE(NULLIF(TRIM(CAST(v.os AS VARCHAR)), ''), '未知') AS os_type,
           COALESCE(NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), ''), '未知区服') AS zone,
           CASE WHEN UPPER(TRIM(CAST(v.country AS VARCHAR))) IN (
               'TW', 'TWN', 'HK', 'HKG', 'MO', 'MAC',
               '台湾', '台灣', '臺灣', '中国台湾', '中國台灣', '中國臺灣',
               '香港', '中国香港', '中國香港', '澳门', '澳門', '中国澳门', '中國澳門',
               '港澳台', '台港澳', 'TAIWAN', 'HONG KONG', 'MACAU', 'MACAO'
           ) THEN '港澳台' ELSE '其他' END AS country,
           ROW_NUMBER() OVER (
               PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
               ORDER BY v."#event_time" ASC NULLS LAST,
                        CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST,
                        CAST(v.os AS VARCHAR) ASC NULLS LAST,
                        CAST(v.server_id AS VARCHAR) ASC NULLS LAST,
                        CAST(v.country AS VARCHAR) ASC NULLS LAST
           ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(GREATEST(sc.target_end_date, sc.observe_end_date) AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),
AccountProfile AS (
    SELECT fc_id, reg_date, os_type, country, zone
    FROM AccountRegistrationRanked
    WHERE rn = 1
),
EligibleAccounts AS (
    SELECT p.*
    FROM AccountProfile p
    LEFT JOIN AccountBlacklist b ON p.fc_id = b.fc_id
    WHERE b.fc_id IS NULL
),
-- 每日每币种仅一行，防止维表重复导致金额翻倍。
ExchangeRates AS (
    SELECT CAST(ex_date AS VARCHAR) AS ex_date,
           UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
           CASE WHEN COUNT_IF(TRY_CAST(exchange AS DOUBLE) IS NULL
                                  OR TRY_CAST(exchange AS DOUBLE) <= 0) = 0
                     AND MIN(TRY_CAST(exchange AS DOUBLE)) = MAX(TRY_CAST(exchange AS DOUBLE))
                THEN MAX(TRY_CAST(exchange AS DOUBLE)) END AS exchange
    FROM ta_dim.ta_exchange
    CROSS JOIN ScanConfig sc
    WHERE CAST(ex_date AS VARCHAR) BETWEEN CAST(sc.target_start_date AS VARCHAR)
          AND CAST(GREATEST(sc.target_end_date, sc.observe_end_date) AS VARCHAR)
    GROUP BY 1, 2
),
AccountEvents AS (
    SELECT p.fc_id, p.reg_date, p.os_type, p.country, p.zone,
           v."$part_date", v."$part_event",
           CAST(v."$part_date" AS DATE) AS event_date,
           CASE WHEN v."$part_event" = 'charge'
                THEN TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(ex.exchange, 0) END AS revenue_usd,
           CASE WHEN v."$part_event" = 'charge'
                     AND (TRY_CAST(v.pay_amount AS DOUBLE) IS NULL OR ex.exchange IS NULL)
                THEN 1 ELSE 0 END AS invalid_revenue_count
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
    CROSS JOIN ScanConfig sc
    LEFT JOIN ExchangeRates ex
      ON v."$part_date" = ex.ex_date
     AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = ex.currency
    WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(GREATEST(sc.target_end_date, sc.observe_end_date) AS VARCHAR)
      AND CAST(v."$part_date" AS DATE) >= p.reg_date
      AND v."$part_event" IN ('new_role', 'login', 'charge')
      AND (v."$part_event" <> 'charge' OR (
          (v.sandbox IS NULL OR v.sandbox = FALSE)
          AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
          AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
      ))
),
AccountRetentionArrays AS (
    SELECT e.fc_id,
           ARRAY_AGG(DISTINCT DATE_DIFF('day', e.reg_date, e.event_date)) AS return_days_array
    FROM AccountEvents e
    CROSS JOIN ScanConfig sc
    WHERE e."$part_event" IN ('new_role', 'login')
      AND e.event_date <= sc.observe_end_date
    GROUP BY 1
),
DailyAccountRevenue AS (
    SELECT e.fc_id, DATE_DIFF('day', e.reg_date, e.event_date) AS day_age,
           SUM(COALESCE(e.revenue_usd, 0.0)) AS revenue_usd,
           SUM(e.invalid_revenue_count) AS invalid_revenue_count
    FROM AccountEvents e
    CROSS JOIN ScanConfig sc
    WHERE e."$part_event" = 'charge'
      AND e.event_date <= sc.observe_end_date
    GROUP BY 1, 2
),
AccountLtvMap AS (
    SELECT fc_id, MAP_AGG(day_age, revenue_usd) AS revenue_map,
           ARRAY_AGG(day_age) FILTER (WHERE invalid_revenue_count > 0) AS invalid_days_array
    FROM DailyAccountRevenue
    GROUP BY 1
),
-- 注册 cohort 在首次 OBT 创角归并后筛选；区服等属性固定于同一条创角。
NewAccountBase AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', s1.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', s1.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', s1.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', s1.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN s1.os_type ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN s1.country ELSE '已合并' END AS country,
        CASE WHEN ${Selector:zone} THEN s1.zone ELSE '已合并' END AS zone,
        s1.fc_id, s1.reg_date, s2.return_days_array, s3.revenue_map, s3.invalid_days_array
    FROM EligibleAccounts s1
    CROSS JOIN ScanConfig sc
    LEFT JOIN AccountRetentionArrays s2 ON s1.fc_id = s2.fc_id
    LEFT JOIN AccountLtvMap s3 ON s1.fc_id = s3.fc_id
    WHERE s1.reg_date BETWEEN sc.target_start_date AND sc.target_end_date
),

-- 10. 留存率计算指标 (实时口径，不做成熟过滤)
NewAccountRR AS (
    SELECT
        time_dimension,
        os_type,
        country,
        zone,

        COUNT(DISTINCT fc_id) AS new_account,

        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_1,

        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_2,

        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_3,

        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_4,

        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_5,

        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_6,

        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_7,

        CAST(COUNT_IF(CONTAINS(return_days_array, 7)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_8,

        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_14,

        CAST(COUNT_IF(CONTAINS(return_days_array, 20)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_21,
            
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_30,

        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_60,

        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_90,

        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_180,

        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT fc_id), 0) AS rr_360,

        CAST(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3
            ) AS DOUBLE
        )
        / NULLIF(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2
            ), 
            0
        ) AS week1_retention_rate,

        CAST(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3
                AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1
            ) AS DOUBLE
        )
        / NULLIF(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3
            ), 
            0
        ) AS week2_return_rate

    FROM NewAccountBase
    GROUP BY 1, 2, 3, 4
),

-- 实时 LTV：各档均使用全部 cohort 账号，不按成熟期缩小分母。
NewAccountLTV AS (
    SELECT time_dimension, os_type, country, zone,
           COUNT(DISTINCT fc_id) AS new_account,
        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 1)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 1)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_1,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 2)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 2)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_2,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 3)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 3)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_3,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 4)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 4)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_4,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 5)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 5)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_5,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 6)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 6)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_6,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 7)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 7)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_7,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 8)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 8)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_8,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 14)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 14)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_14,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 21)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 21)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_21,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 30)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 30)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_30,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 60)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 60)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_60,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 90)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 90)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_90,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 180)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 180)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_180,

        CASE WHEN COUNT_IF(
            COALESCE(CARDINALITY(FILTER(invalid_days_array, x -> x >= 0 AND x < 360)), 0) > 0
        ) > 0 THEN NULL ELSE
            CAST(SUM(COALESCE(REDUCE(
                MAP_VALUES(MAP_FILTER(revenue_map, (k, v) -> k >= 0 AND k < 360)),
                CAST(0 AS DOUBLE), (acc, v) -> acc + v, acc -> acc
            ), 0.0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT fc_id), 0)
        END AS ltv_360
    FROM NewAccountBase
    GROUP BY 1, 2, 3, 4
),

PeriodEvents AS (
    SELECT e.*, 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', e.event_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', e.event_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', e.event_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', e.event_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension
    FROM AccountEvents e
    WHERE ${PartDate:date1}
),
AccountKPI AS (
    SELECT
        e.time_dimension,
        CASE WHEN ${Selector:ostype} THEN e.os_type ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN e.country ELSE '已合并' END AS country,
        CASE WHEN ${Selector:zone} THEN e.zone ELSE '已合并' END AS zone,
        MAX(CONCAT(
            CAST(GREATEST(
                CASE WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                     ELSE CAST(e.time_dimension AS DATE) END,
                sc.target_start_date
            ) AS VARCHAR),
            ' ~ ',
            CAST(LEAST(
                CASE
                    WHEN ${Selector:timetype} = 'D' THEN CAST(e.time_dimension AS DATE)
                    WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, CAST(e.time_dimension AS DATE))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, CAST(e.time_dimension AS DATE)))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, CAST(e.time_dimension AS DATE)))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                END,
                sc.target_end_date
            ) AS VARCHAR)
        )) AS date_range,
        MIN(DATE_DIFF('day', e.event_date, CURRENT_DATE)) AS date_gap,
        COUNT(DISTINCT e.fc_id) AS active_account,
        COUNT(DISTINCT CASE WHEN e."$part_event" = 'charge' THEN e.fc_id END) AS paying_account,
        CASE WHEN SUM(e.invalid_revenue_count) > 0 THEN NULL
             ELSE COALESCE(SUM(e.revenue_usd), 0.0) END AS total_revenue_usd,
        SUM(e.invalid_revenue_count) AS invalid_revenue_count
    FROM PeriodEvents e
    CROSS JOIN ScanConfig sc
    GROUP BY 1, 2, 3, 4
),
CohortAccounts AS (
    SELECT p.fc_id, p.reg_date,
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', p.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', p.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', p.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', p.reg_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,
        CASE WHEN ${Selector:ostype} THEN p.os_type ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN p.country ELSE '已合并' END AS country,
        CASE WHEN ${Selector:zone} THEN p.zone ELSE '已合并' END AS zone
    FROM EligibleAccounts p
    CROSS JOIN ScanConfig sc
    WHERE p.reg_date BETWEEN sc.target_start_date AND sc.target_end_date
),
NewAccountKPI AS (
    SELECT p.time_dimension, p.os_type, p.country, p.zone,
           COUNT(DISTINCT e.fc_id) AS new_paying_account,
           CASE WHEN COALESCE(SUM(e.invalid_revenue_count), 0) > 0 THEN NULL
                ELSE COALESCE(SUM(e.revenue_usd), 0.0) END AS new_account_revenue_usd,
           COALESCE(SUM(e.invalid_revenue_count), 0) AS invalid_revenue_count
    FROM CohortAccounts p
    LEFT JOIN PeriodEvents e
      ON p.fc_id = e.fc_id
     AND p.time_dimension = e.time_dimension
     AND e."$part_event" = 'charge'
     AND e.event_date >= p.reg_date
    GROUP BY 1, 2, 3, 4
)

-- 14. 最终报表汇总
SELECT
    k.time_dimension AS "时间维度", 
    k.os_type AS "OS", 
    k.country AS "地区", 
    k.zone AS "区服", 
    k.date_range AS "日期范围",

    k.active_account AS "活跃设备", 
    k.paying_account AS "付费设备", 
    ROUND(k.total_revenue_usd, 2) AS "总流水(USD)",

    CAST(k.paying_account AS DOUBLE) / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "付费率",
    k.total_revenue_usd / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "ARPU",
    k.total_revenue_usd / NULLIF(CAST(k.paying_account AS DOUBLE), 0.0) AS "ARPPU",
    
    ltv.new_account AS "新增设备", 
    p5.new_paying_account AS "新增付费设备", 
    ROUND(p5.new_account_revenue_usd, 2) AS "新增当日流水(USD)",

    p5.new_account_revenue_usd / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增ARPU",
    p5.new_account_revenue_usd / NULLIF(CAST(p5.new_paying_account AS DOUBLE), 0.0) AS "新增ARPPU",
    CAST(p5.new_paying_account AS DOUBLE) / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增付费率",

    k.date_gap AS "完整生命周期到第几天", 
    rr.rr_2 AS "次留", 
    rr.rr_3 AS "D3留存", 
    rr.rr_4 AS "D4留存", 
    rr.rr_5 AS "D5留存", 
    rr.rr_6 AS "D6留存", 
    rr.rr_7 AS "D7留存", 
    rr.rr_8 AS "D8留存", 
    rr.rr_14 AS "D14留存", 
    rr.rr_21 AS "D21留存",
    rr.rr_30 AS "D30留存", 
    rr.rr_60 AS "D60留存", 
    rr.rr_90 AS "D90留存", 
    rr.rr_180 AS "D180留存", 
    rr.rr_360 AS "D360留存",

    -- rr.week1_retention_rate AS "一阶登陆比率", 
    -- rr.week2_return_rate AS "二阶登陆比率",

    ltv.ltv_1 AS "LTV_1", 
    ltv.ltv_2 AS "LTV_2", 
    ltv.ltv_3 AS "LTV_3", 
    ltv.ltv_4 AS "LTV_4", 
    ltv.ltv_5 AS "LTV_5", 
    ltv.ltv_6 AS "LTV_6", 
    ltv.ltv_7 AS "LTV_7", 
    ltv.ltv_8 AS "LTV_8", 
    ltv.ltv_14 AS "LTV_14", 
    ltv.ltv_21 AS "LTV_21", 
    ltv.ltv_30 AS "LTV_30", 
    ltv.ltv_60 AS "LTV_60", 
    ltv.ltv_90 AS "LTV_90", 
    ltv.ltv_180 AS "LTV_180", 
    ltv.ltv_360 AS "LTV_360"

FROM AccountKPI k
LEFT JOIN NewAccountLTV ltv 
    ON k.time_dimension = ltv.time_dimension 
   AND k.os_type = ltv.os_type 
   AND k.country = ltv.country 
   AND k.zone = ltv.zone
LEFT JOIN NewAccountRR rr 
    ON k.time_dimension = rr.time_dimension 
   AND k.os_type = rr.os_type 
   AND k.country = rr.country 
   AND k.zone = rr.zone
LEFT JOIN NewAccountKPI p5 
    ON k.time_dimension = p5.time_dimension 
   AND k.os_type = p5.os_type 
   AND k.country = p5.country 
   AND k.zone = p5.zone
ORDER BY 1 DESC;
