/*
================================================================================
项目    : 蜡笔小新 (Crayon Shin-chan) - TC 繁体大区 OBT
表名    : ta.v_event_18, user_result_cluster_18, ta_dim.ta_exchange
描述    : 基于 fc_id（5X ID）的单日分时累计 KPI（0-23 小时）
          输出字段名及顺序保持原 SQL 不变。

口径：
1. OBT 从 2026-10-14 开始。new_role/login/charge 均按非空 fc_id 去重。
2. NUU 只统计 fc_id 在整个 OBT 历史中的首次 new_role；同账号多角色不重复计算。
3. DAU 沿用原逻辑：当天 login/new_role/有效 charge 任一事件出现即计活跃。
4. 黑名单直接使用 user_result_cluster_18 的 #varchar_id，标签为
   internal_users_new、is_water_new、is_windows_new。沙盒及福利账号由黑名单表维护，
   本查询不再扫描事件表重复构造名单。
5. 有效充值排除 sandbox、is_freebuy、COIN。USD = pay_amount / exchange。
   同日同币种汇率先去重；缺失、非正数、冲突汇率或非法金额会让受影响小时起的
   sales、arpu、arppu 返回 NULL，不把异常金额当 0，也不将汇率默认为 1。
6. ${PartDate:date1} 应选择单日。历史日期输出 0-23 点；当天只输出到当前小时。
7. 小时取 #event_time 在数数项目配置时区中的小时。
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

ReportConfig AS (
    SELECT
        MIN(CAST(v."$part_date" AS DATE)) AS report_start_date,
        MAX(CAST(v."$part_date" AS DATE)) AS report_end_date,
        CASE
            WHEN MAX(CAST(v."$part_date" AS DATE)) = CURRENT_DATE THEN HOUR(CURRENT_TIME)
            ELSE 23
        END AS max_output_hour
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role', 'charge')
),

AccountBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

-- 全部 OBT 创角历史中取每个 fc_id 首次 new_role；不能先套报表日期筛选。
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    CROSS JOIN ReportConfig rc
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(rc.report_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

AccountProfile AS (
    SELECT fc_id, reg_date, reg_event_time
    FROM AccountRegistrationRanked
    WHERE rn = 1
),

EligibleAccounts AS (
    SELECT p.*
    FROM AccountProfile p
    LEFT JOIN AccountBlacklist b ON p.fc_id = b.fc_id
    WHERE b.fc_id IS NULL
),

-- 防止汇率维表重复行把流水放大；冲突或无效汇率保留为 NULL。
ExchangeRates AS (
    SELECT
        CAST(ex.ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(ex.currency AS VARCHAR))) AS currency,
        CASE
            WHEN COUNT_IF(TRY_CAST(ex.exchange AS DOUBLE) IS NULL
                          OR TRY_CAST(ex.exchange AS DOUBLE) <= 0) = 0
             AND MIN(TRY_CAST(ex.exchange AS DOUBLE)) = MAX(TRY_CAST(ex.exchange AS DOUBLE))
            THEN MAX(TRY_CAST(ex.exchange AS DOUBLE))
        END AS exchange
    FROM ta_dim.ta_exchange ex
    CROSS JOIN ReportConfig rc
    WHERE CAST(ex.ex_date AS DATE) BETWEEN rc.report_start_date AND rc.report_end_date
    GROUP BY 1, 2
),

-- 当天有效账号事件；仅保留发生在该账号首次 OBT 创角之后的事件。
RawEvents AS (
    SELECT
        p.fc_id,
        p.reg_date,
        v."$part_event",
        CAST(v."$part_date" AS DATE) AS event_date,
        HOUR(CAST(v."#event_time" AS TIMESTAMP)) AS event_hour,
        CASE
            WHEN v."$part_event" = 'charge'
            THEN TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(ex.exchange, 0)
        END AS pay_amount_usd,
        CASE
            WHEN v."$part_event" = 'charge'
             AND (TRY_CAST(v.pay_amount AS DOUBLE) IS NULL OR ex.exchange IS NULL)
            THEN 1 ELSE 0
        END AS invalid_revenue_count
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
    LEFT JOIN ExchangeRates ex
        ON v."$part_date" = ex.ex_date
       AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = ex.currency
    WHERE v.${PartDate:date1}
      AND CAST(v."$part_date" AS DATE) >= p.reg_date
      AND v."$part_event" IN ('login', 'new_role', 'charge')
      AND (
          v."$part_event" <> 'charge'
          OR (
              (v.sandbox IS NULL OR v.sandbox = FALSE)
              AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
              AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
          )
      )
),

Hours AS (
    SELECT hr AS hour
    FROM UNNEST(SEQUENCE(0, 23)) AS h(hr)
),

AccountDailyStats AS (
    SELECT
        r.fc_id,
        MIN(r.event_hour) AS min_active_hour,
        MIN(CASE
            WHEN r."$part_event" = 'new_role' AND r.event_date = r.reg_date
            THEN r.event_hour
        END) AS min_nuu_hour
    FROM RawEvents r
    GROUP BY 1
),

HourlyPeople AS (
    SELECT
        h.hour,
        COUNT(DISTINCT CASE WHEN s.min_active_hour <= h.hour THEN s.fc_id END) AS dau,
        COUNT(DISTINCT CASE WHEN s.min_nuu_hour <= h.hour THEN s.fc_id END) AS nuu
    FROM Hours h
    LEFT JOIN AccountDailyStats s ON s.min_active_hour <= h.hour
    GROUP BY 1
),

AccountPayEvents AS (
    SELECT fc_id, event_hour, pay_amount_usd, invalid_revenue_count
    FROM RawEvents
    WHERE "$part_event" = 'charge'
),

AccountFirstPay AS (
    SELECT fc_id, MIN(event_hour) AS min_pay_hour
    FROM AccountPayEvents
    GROUP BY 1
),

HourlyPay AS (
    SELECT
        h.hour,
        SUM(CASE WHEN e.event_hour <= h.hour THEN COALESCE(e.pay_amount_usd, 0.0) ELSE 0.0 END) AS sales,
        SUM(CASE WHEN e.event_hour <= h.hour THEN e.invalid_revenue_count ELSE 0 END) AS invalid_revenue_count
    FROM Hours h
    LEFT JOIN AccountPayEvents e ON e.event_hour <= h.hour
    GROUP BY 1
),

HourlyPayUsers AS (
    SELECT
        h.hour,
        COUNT(DISTINCT CASE WHEN fp.min_pay_hour <= h.hour THEN fp.fc_id END) AS paying_users
    FROM Hours h
    LEFT JOIN AccountFirstPay fp ON fp.min_pay_hour <= h.hour
    GROUP BY 1
)

SELECT
    LPAD(CAST(p.hour AS VARCHAR), 2, '0') || ':00' AS "時間",
    p.nuu AS "nuu",
    p.dau AS "dau",
    CAST(COALESCE(hpu.paying_users, 0) AS DOUBLE) AS "付费用户数",
    CASE WHEN hp.invalid_revenue_count > 0 THEN NULL
         ELSE ROUND(COALESCE(hp.sales, 0.0), 2) END AS "sales",
    CASE WHEN hp.invalid_revenue_count > 0 THEN NULL
         ELSE ROUND(COALESCE(hp.sales, 0.0) / NULLIF(p.dau, 0), 2) END AS "arpu",
    CAST(COALESCE(hpu.paying_users, 0) AS DOUBLE) / NULLIF(p.dau, 0) AS "pr",
    CASE WHEN hp.invalid_revenue_count > 0 THEN NULL
         ELSE ROUND(COALESCE(hp.sales, 0.0) / NULLIF(hpu.paying_users, 0), 2) END AS "arppu"
FROM HourlyPeople p
CROSS JOIN ReportConfig rc
LEFT JOIN HourlyPay hp ON p.hour = hp.hour
LEFT JOIN HourlyPayUsers hpu ON p.hour = hpu.hour
WHERE p.hour <= rc.max_output_hour
ORDER BY p.hour DESC;
