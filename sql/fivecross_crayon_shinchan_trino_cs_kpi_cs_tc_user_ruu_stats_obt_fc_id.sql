/*
================================================================================
Game       : Crayon Shin-chan (蜡笔小新) - TC OBT
Description: 回流账号（连续 30 天及以上未活跃）KPI、留存及 LTV。
Environment: Trino
Tables     : ta.v_event_18 / user_result_cluster_18 / ta_dim.ta_exchange

口径：
1. OBT 从 2026-10-14 开始；账号使用 fc_id，同账号多角色合并。
2. 从 OBT 开服日扫描完整 new_role/login 日活历史；相邻活跃日间隔 >= 30 天判定回流。
3. 黑名单使用 #varchar_id，排除 internal_users_new、is_water_new、is_windows_new。
4. OS、地区取账号首次 OBT 创角记录；地区统一为“港澳台”和“其他”。
5. App 18 收入使用 pay_amount / exchange；排除 sandbox、is_freebuy。
6. 留存和 LTV 使用各自成熟分母；尚未完成观察窗口时返回 NULL。
7. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/

WITH
Config AS (
    SELECT
        DATE '2026-10-14' AS obt_start_date,
        DATE_ADD('day', -1, CURRENT_DATE) AS mature_end_date
),

ScanConfig AS (
    SELECT
        MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
        MAX(CAST(v."$part_date" AS DATE)) AS target_end_date,
        MAX(c.obt_start_date) AS obt_start_date,
        MAX(c.mature_end_date) AS mature_end_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('new_role', 'login')
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定每个 fc_id 的首次创角及归属维度
--------------------------------------------------------------------------------
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        COALESCE(NULLIF(TRIM(CAST(v.os AS VARCHAR)), ''), '未知') AS os_type,
        CASE
            WHEN UPPER(TRIM(CAST(v.country AS VARCHAR))) IN (
                'TW', 'TWN', 'HK', 'HKG', 'MO', 'MAC',
                '台湾', '台灣', '臺灣', '中国台湾', '中國台灣', '中國臺灣',
                '香港', '中国香港', '中國香港',
                '澳门', '澳門', '中国澳门', '中國澳門',
                '港澳台', '台港澳', 'TAIWAN', 'HONG KONG', 'MACAU', 'MACAO'
            ) THEN '港澳台'
            ELSE '其他'
        END AS country,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST,
                     CAST(v.os AS VARCHAR) ASC NULLS LAST,
                     CAST(v.country AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

AccountProfile AS (
    SELECT fc_id, reg_date, reg_event_time, os_type, country
    FROM AccountRegistrationRanked
    WHERE rn = 1
),

EligibleAccounts AS (
    SELECT p.*
    FROM AccountProfile p
    LEFT JOIN UserBlacklist b ON p.fc_id = b.fc_id
    WHERE b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- 从 OBT 开服日开始扫描完整活跃历史，避免漏掉 60 天以上未登录的回流账号
--------------------------------------------------------------------------------
UserDailyLogin AS (
    SELECT
        p.fc_id,
        CAST(v."$part_date" AS DATE) AS login_date
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" IN ('new_role', 'login')
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
    GROUP BY 1, 2
),

UserLoginSequence AS (
    SELECT
        fc_id,
        login_date,
        LAG(login_date) OVER (
            PARTITION BY fc_id
            ORDER BY login_date ASC
        ) AS prev_login_date
    FROM UserDailyLogin
),

ReturnEvents AS (
    SELECT fc_id, login_date AS return_date, prev_login_date
    FROM UserLoginSequence
    WHERE prev_login_date IS NOT NULL
      AND DATE_DIFF('day', prev_login_date, login_date) >= 30
),

TargetReturnUsers AS (
    SELECT
        re.fc_id,
        re.return_date,
        p.os_type,
        p.country
    FROM ReturnEvents re
    INNER JOIN EligibleAccounts p ON re.fc_id = p.fc_id
    CROSS JOIN ScanConfig sc
    WHERE re.return_date BETWEEN sc.target_start_date AND sc.target_end_date
),

--------------------------------------------------------------------------------
-- 回流后 D0~D29 的活跃日期；留存仅使用 login
--------------------------------------------------------------------------------
ReturneeRetention AS (
    SELECT
        tru.fc_id,
        tru.return_date,
        ARRAY_AGG(DISTINCT DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE))) AS retention_days_array
    FROM TargetReturnUsers tru
    INNER JOIN ta.v_event_18 v
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = tru.fc_id
       AND CAST(v."$part_date" AS DATE) BETWEEN tru.return_date
                                             AND DATE_ADD('day', 29, tru.return_date)
    WHERE v."$part_event" = 'login'
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 汇率按日期、币种压成一行，避免重复汇率记录放大收入
--------------------------------------------------------------------------------
ExchangeRates AS (
    SELECT
        CAST(ex.ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(ex.currency AS VARCHAR))) AS currency,
        MAX(TRY_CAST(ex.exchange AS DOUBLE)) AS exchange
    FROM ta_dim.ta_exchange ex
    CROSS JOIN ScanConfig sc
    WHERE CAST(ex.ex_date AS DATE) BETWEEN sc.target_start_date
                                        AND DATE_ADD('day', 29, sc.target_end_date)
    GROUP BY 1, 2
),

ValidReturnCharges AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS pay_date,
        TRY_CAST(v.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1.0) AS pay_amount_usd
    FROM ta.v_event_18 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN ExchangeRates ex
        ON v."$part_date" = ex.ex_date
       AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = ex.currency
    WHERE v."$part_event" = 'charge'
      AND CAST(v."$part_date" AS DATE) BETWEEN sc.target_start_date
                                            AND DATE_ADD('day', 29, sc.target_end_date)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
),

ReturneeLtvStats AS (
    SELECT
        tru.fc_id,
        tru.return_date,
        SUM(CASE
            WHEN (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', tru.return_date) = DATE_TRUNC('day', v.pay_date)) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', tru.return_date) = DATE_TRUNC('week', v.pay_date)) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', tru.return_date) = DATE_TRUNC('month', v.pay_date)) OR
                (${Selector:timetype} = 'A')
            ) THEN v.pay_amount_usd ELSE 0.0
        END) AS rev_period,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, v.pay_date) < 1 THEN v.pay_amount_usd ELSE 0.0 END) AS rev_1,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, v.pay_date) < 7 THEN v.pay_amount_usd ELSE 0.0 END) AS rev_7,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, v.pay_date) < 14 THEN v.pay_amount_usd ELSE 0.0 END) AS rev_14,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, v.pay_date) < 30 THEN v.pay_amount_usd ELSE 0.0 END) AS rev_30
    FROM TargetReturnUsers tru
    LEFT JOIN ValidReturnCharges v
        ON tru.fc_id = v.fc_id
       AND v.pay_date BETWEEN tru.return_date AND DATE_ADD('day', 29, tru.return_date)
    GROUP BY 1, 2
)

SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '已合并'
    END AS "时间维度",
    CASE WHEN ${Selector:ostype} THEN p1.os_type ELSE '已合并' END AS os_type,
    CASE WHEN ${Selector:country} THEN p1.country ELSE '已合并' END AS country,
    MAX(CONCAT(
        CAST(GREATEST(
            CASE
                WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', p1.return_date)
                WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', p1.return_date)
                WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', p1.return_date)
                WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                ELSE p1.return_date
            END,
            sc.target_start_date
        ) AS VARCHAR),
        ' ~ ',
        CAST(LEAST(
            CASE
                WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', p1.return_date)
                WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', p1.return_date))
                WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', p1.return_date)))
                WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                ELSE p1.return_date
            END,
            sc.target_end_date
        ) AS VARCHAR)
    )) AS "日期范围",

    COUNT(DISTINCT p1.fc_id) AS "回流人数(RUU)",
    COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1.fc_id END) AS "付费回流人数",
    CAST(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1.fc_id END) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT p1.fc_id), 0) AS "付费回流率",
    SUM(r_ltv.rev_period) AS "回流首期收入(USD)",
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT p1.fc_id), 0) AS "RUU_ARPU",
    SUM(r_ltv.rev_period)
        / NULLIF(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1.fc_id END), 0) AS "RUU_ARPPU",

    CAST(COUNT_IF(
        DATE_ADD('day', 1, p1.return_date) <= sc.mature_end_date
        AND CONTAINS(r_ret.retention_days_array, 1)
    ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 1, p1.return_date) <= sc.mature_end_date), 0) AS "回流次留",

    CAST(COUNT_IF(
        DATE_ADD('day', 2, p1.return_date) <= sc.mature_end_date
        AND CONTAINS(r_ret.retention_days_array, 2)
    ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 2, p1.return_date) <= sc.mature_end_date), 0) AS "回流3留",

    CAST(COUNT_IF(
        DATE_ADD('day', 6, p1.return_date) <= sc.mature_end_date
        AND CONTAINS(r_ret.retention_days_array, 6)
    ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 6, p1.return_date) <= sc.mature_end_date), 0) AS "回流7留",

    CAST(COUNT_IF(
        DATE_ADD('day', 13, p1.return_date) <= sc.mature_end_date
        AND CONTAINS(r_ret.retention_days_array, 13)
    ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 13, p1.return_date) <= sc.mature_end_date), 0) AS "回流14留",

    CAST(COUNT_IF(
        DATE_ADD('day', 29, p1.return_date) <= sc.mature_end_date
        AND CONTAINS(r_ret.retention_days_array, 29)
    ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 29, p1.return_date) <= sc.mature_end_date), 0) AS "回流30留",

    SUM(CASE
        WHEN p1.return_date <= sc.mature_end_date THEN COALESCE(r_ltv.rev_1, 0.0)
    END) / NULLIF(COUNT_IF(p1.return_date <= sc.mature_end_date), 0) AS ltv_1,

    SUM(CASE
        WHEN DATE_ADD('day', 6, p1.return_date) <= sc.mature_end_date THEN COALESCE(r_ltv.rev_7, 0.0)
    END) / NULLIF(COUNT_IF(DATE_ADD('day', 6, p1.return_date) <= sc.mature_end_date), 0) AS ltv_7,

    SUM(CASE
        WHEN DATE_ADD('day', 13, p1.return_date) <= sc.mature_end_date THEN COALESCE(r_ltv.rev_14, 0.0)
    END) / NULLIF(COUNT_IF(DATE_ADD('day', 13, p1.return_date) <= sc.mature_end_date), 0) AS ltv_14,

    SUM(CASE
        WHEN DATE_ADD('day', 29, p1.return_date) <= sc.mature_end_date THEN COALESCE(r_ltv.rev_30, 0.0)
    END) / NULLIF(COUNT_IF(DATE_ADD('day', 29, p1.return_date) <= sc.mature_end_date), 0) AS ltv_30

FROM TargetReturnUsers p1
CROSS JOIN ScanConfig sc
LEFT JOIN ReturneeRetention r_ret
    ON p1.fc_id = r_ret.fc_id
   AND p1.return_date = r_ret.return_date
LEFT JOIN ReturneeLtvStats r_ltv
    ON p1.fc_id = r_ltv.fc_id
   AND p1.return_date = r_ltv.return_date
GROUP BY 1, 2, 3
ORDER BY 1 DESC;
