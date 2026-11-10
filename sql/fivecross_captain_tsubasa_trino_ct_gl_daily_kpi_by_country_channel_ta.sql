/*
================================================================================
Game    : Captain Tsubasa / 足球小将 GL
App ID  : 65002005
Purpose : 开服至今，按日 x 国家 x 渠道(iOS / GG)输出 LTV 与 留存率 以及 基础DAU/充值 (数数版本)
Metrics : DAU、当日付费、新增、留存率 (次留到180留)、LTV (1到180)
Engine  : Trino (Presto) over ODPS
Table   : ta.v_event_19
================================================================================
*/

WITH IdentifiedEvents AS (
    SELECT
        v.*,
        CASE
            WHEN
                   applicationid IN ('23000113','seiya30tw')
                OR productid IN ('23000113','seiya30tw')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('23000113')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('23000113')
                OR substring(affcode, length(affcode) - 7) IN ('23000113')
                OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('23000113','seiya30tw')
            THEN 'Saint Seiya (TC)'
            WHEN
                   applicationid IN ('60000001')
                OR productid IN ('60000001')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('60000001')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('60000001')
                OR substring(affcode, length(affcode) - 7) IN ('60000001')
                OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('60000001')
            THEN 'Saint Seiya (SEA)'
            WHEN
                   applicationid IN ('65002004')
                OR productid IN ('65002004')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002004')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('65002004')
                OR substring(affcode, length(affcode) - 7) IN ('65002004')
                OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
            THEN 'Three Kingdoms'
            WHEN
                   applicationid IN ('65002005')
                OR productid IN ('65002005')
                OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002005')
                OR regexp_extract(productid, 'g(\d+)', 1) IN ('65002005')
                OR substring(affcode, length(affcode) - 7) IN ('65002005')
                OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002005')
            THEN 'Captain Tsubasa'
            ELSE 'UNKNOWN'
        END AS game_name
    FROM ta.v_event_19 v
    WHERE "$part_date" >= '2026-05-28'
),

TargetGameEvents AS (
    SELECT *
    FROM IdentifiedEvents
    WHERE game_name = 'Captain Tsubasa'
),

UserProfileDetail AS (
    SELECT
        "#varchar_id" AS "#account_id",
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_countrycode' THEN tag_value END) AS fixed_countrycode
    FROM user_result_cluster_19
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_countrycode', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

cohort AS (
    SELECT DISTINCT
        v."#account_id",
        u.fixed_regdate AS cohort_date,
        COALESCE(u.fixed_countrycode, 'UNKNOWN') AS country_code,
        COALESCE(u.fixed_os, 'UNKNOWN') AS os
    FROM TargetGameEvents v
    JOIN UserProfileDetail u ON v."#account_id" = u."#account_id"
    WHERE v."$part_date" = u.fixed_regdate
      AND u.fixed_regdate IS NOT NULL
),

activity AS (
    SELECT
        c."#account_id",
        c.cohort_date,
        c.country_code,
        c.os,
        COALESCE(
            CASE WHEN v."$part_event" = 'PURCHASE' AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
                 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange
                 ELSE 0.0
            END, 0.0) AS daily_purchase_rmb,
        DATE_DIFF('day', CAST(c.cohort_date AS DATE), current_date - interval '1' day) AS current_days_since_cohort,
        DATE_DIFF('day', CAST(c.cohort_date AS DATE), CAST(v."$part_date" AS DATE)) AS days_since_cohort
    FROM cohort c
    LEFT JOIN TargetGameEvents v
        ON c."#account_id" = v."#account_id"
        AND v."$part_date" >= c.cohort_date
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
),

user_ltv_ret AS (
    SELECT
        cohort_date,
        country_code,
        os,
        "#account_id",
        MAX(current_days_since_cohort) AS current_days_since_cohort,
        SUM(CASE WHEN days_since_cohort <= 0 THEN daily_purchase_rmb ELSE 0 END) AS ltv_1,
        SUM(CASE WHEN days_since_cohort <= 2 THEN daily_purchase_rmb ELSE 0 END) AS ltv_3,
        SUM(CASE WHEN days_since_cohort <= 6 THEN daily_purchase_rmb ELSE 0 END) AS ltv_7,
        SUM(CASE WHEN days_since_cohort <= 13 THEN daily_purchase_rmb ELSE 0 END) AS ltv_14,
        SUM(CASE WHEN days_since_cohort <= 29 THEN daily_purchase_rmb ELSE 0 END) AS ltv_30,
        SUM(CASE WHEN days_since_cohort <= 59 THEN daily_purchase_rmb ELSE 0 END) AS ltv_60,
        SUM(CASE WHEN days_since_cohort <= 89 THEN daily_purchase_rmb ELSE 0 END) AS ltv_90,
        SUM(CASE WHEN days_since_cohort <= 179 THEN daily_purchase_rmb ELSE 0 END) AS ltv_180,
        MAX(CASE WHEN days_since_cohort = 1 THEN 1 ELSE 0 END) AS ret_1,
        MAX(CASE WHEN days_since_cohort = 3 THEN 1 ELSE 0 END) AS ret_3,
        MAX(CASE WHEN days_since_cohort = 7 THEN 1 ELSE 0 END) AS ret_7,
        MAX(CASE WHEN days_since_cohort = 14 THEN 1 ELSE 0 END) AS ret_14,
        MAX(CASE WHEN days_since_cohort = 30 THEN 1 ELSE 0 END) AS ret_30,
        MAX(CASE WHEN days_since_cohort = 60 THEN 1 ELSE 0 END) AS ret_60,
        MAX(CASE WHEN days_since_cohort = 90 THEN 1 ELSE 0 END) AS ret_90,
        MAX(CASE WHEN days_since_cohort = 180 THEN 1 ELSE 0 END) AS ret_180
    FROM activity
    GROUP BY cohort_date, country_code, os, "#account_id"
),

raw_combined AS (
    -- 1. Daily active events for DAU/Rev
    SELECT
        v."$part_date" AS report_date,
        COALESCE(u.fixed_countrycode, 'UNKNOWN') AS country_code,
        COALESCE(u.fixed_os, 'UNKNOWN') AS os,
        v."#account_id" AS dau_user,
        COALESCE(
            SUM(CASE WHEN v."$part_event" = 'PURCHASE' AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
                 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange
                 ELSE 0.0
            END), 0.0) AS daily_rev,
        NULL AS nuu_user,
        -1 AS current_days_since_cohort,
        0.0 AS ltv_1, 0.0 AS ltv_3, 0.0 AS ltv_7, 0.0 AS ltv_14, 0.0 AS ltv_30, 0.0 AS ltv_60, 0.0 AS ltv_90, 0.0 AS ltv_180,
        0 AS ret_1, 0 AS ret_3, 0 AS ret_7, 0 AS ret_14, 0 AS ret_30, 0 AS ret_60, 0 AS ret_90, 0 AS ret_180
    FROM TargetGameEvents v
    LEFT JOIN UserProfileDetail u ON v."#account_id" = u."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    GROUP BY v."$part_date", COALESCE(u.fixed_countrycode, 'UNKNOWN'), COALESCE(u.fixed_os, 'UNKNOWN'), v."#account_id"

    UNION ALL

    -- 2. Cohort LTV/RR events
    SELECT
        cohort_date AS report_date,
        country_code,
        os,
        NULL AS dau_user,
        0.0 AS daily_rev,
        "#account_id" AS nuu_user,
        current_days_since_cohort,
        ltv_1, ltv_3, ltv_7, ltv_14, ltv_30, ltv_60, ltv_90, ltv_180,
        ret_1, ret_3, ret_7, ret_14, ret_30, ret_60, ret_90, ret_180
    FROM user_ltv_ret
)

SELECT
    COALESCE(CAST(report_date AS VARCHAR), '【阶段汇总】') AS "日期",
    COALESCE(country_code, '汇总') AS "国家代码",
    COALESCE(os, '汇总') AS "系统",

    COUNT(DISTINCT nuu_user) AS "新增用户",
    COUNT(DISTINCT dau_user) AS "活跃用户",
    ROUND(SUM(daily_rev), 2) AS "当日付费金额_RMB",
    COUNT(DISTINCT CASE WHEN daily_rev > 0 THEN dau_user END) AS "当日付费人数",
    ROUND(COUNT(DISTINCT CASE WHEN daily_rev > 0 THEN dau_user END) * 1.0 / NULLIF(COUNT(DISTINCT dau_user), 0), 4) AS "付费率",
    ROUND(SUM(daily_rev) * 1.0 / NULLIF(COUNT(DISTINCT dau_user), 0), 4) AS "ARPU",
    ROUND(SUM(daily_rev) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN daily_rev > 0 THEN dau_user END), 0), 4) AS "ARPPU",

    ROUND(SUM(ret_1) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 1 THEN nuu_user END), 0), 4) AS "次留",
    ROUND(SUM(ret_3) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 3 THEN nuu_user END), 0), 4) AS "3留",
    ROUND(SUM(ret_7) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 7 THEN nuu_user END), 0), 4) AS "7留",
    ROUND(SUM(ret_14) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 14 THEN nuu_user END), 0), 4) AS "14留",
    ROUND(SUM(ret_30) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 30 THEN nuu_user END), 0), 4) AS "30留",
    ROUND(SUM(ret_60) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 60 THEN nuu_user END), 0), 4) AS "60留",
    ROUND(SUM(ret_90) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 90 THEN nuu_user END), 0), 4) AS "90留",
    ROUND(SUM(ret_180) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 180 THEN nuu_user END), 0), 4) AS "180留",

    ROUND(SUM(ltv_1) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 0 THEN nuu_user END), 0), 2) AS "LTV_1",
    ROUND(SUM(ltv_3) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 2 THEN nuu_user END), 0), 2) AS "LTV_3",
    ROUND(SUM(ltv_7) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 6 THEN nuu_user END), 0), 2) AS "LTV_7",
    ROUND(SUM(ltv_14) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 13 THEN nuu_user END), 0), 2) AS "LTV_14",
    ROUND(SUM(ltv_30) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 29 THEN nuu_user END), 0), 2) AS "LTV_30",
    ROUND(SUM(ltv_60) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 59 THEN nuu_user END), 0), 2) AS "LTV_60",
    ROUND(SUM(ltv_90) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 89 THEN nuu_user END), 0), 2) AS "LTV_90",
    ROUND(SUM(ltv_180) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 179 THEN nuu_user END), 0), 2) AS "LTV_180"
FROM raw_combined
GROUP BY GROUPING SETS (
    (report_date, country_code, os),
    (report_date, country_code),
    (report_date, os),
    (report_date),
    (country_code, os),
    (country_code),
    (os),
    ()
)
ORDER BY
    CASE WHEN report_date IS NULL THEN 0 ELSE 1 END,
    report_date DESC,
    country_code,
    os;
