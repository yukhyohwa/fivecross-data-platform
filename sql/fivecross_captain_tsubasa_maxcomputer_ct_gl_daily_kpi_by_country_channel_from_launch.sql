/*
================================================================================
Game    : Captain Tsubasa / 足球小将 GL
App ID  : 65002005
Purpose : 开服至今，按日 x 国家 x 渠道(iOS / GG)输出 LTV 与 留存率 以及 基础DAU/充值
Metrics : DAU、当日付费、新增、留存率 (次留到180留)、LTV (1到180)
Engine  : MaxCompute (ODPS)
Table   : dm_platform.daily_lcx_user_info
================================================================================
*/

WITH cohort AS (
    SELECT DISTINCT
        lcm_id,
        reg_day AS cohort_date,
        COALESCE(country_code, 'UNKNOWN') AS country_code,
        COALESCE(os, 'UNKNOWN') AS os
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 65002005
      AND day >= 20231205
      AND reg_day >= '20231205'
      AND is_water = '不是水'
      AND reg_day = day
),

activity AS (
    SELECT
        c.lcm_id,
        c.cohort_date,
        c.country_code,
        c.os,
        COALESCE(CAST(u.purchase AS DOUBLE), 0.0) AS daily_purchase,
        DATEDIFF(TO_DATE('20260527', 'yyyymmdd'), TO_DATE(CAST(c.cohort_date AS STRING), 'yyyymmdd'), 'dd') AS current_days_since_cohort,
        DATEDIFF(TO_DATE(CAST(u.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(c.cohort_date AS STRING), 'yyyymmdd'), 'dd') AS days_since_cohort
    FROM cohort c
    LEFT JOIN dm_platform.daily_lcx_user_info u
        ON c.lcm_id = u.lcm_id
        AND u.app_id = 65002005
        AND u.day >= 20231205
        AND u.day >= c.cohort_date
        AND u.is_water = '不是水'
),

user_ltv_ret AS (
    SELECT
        cohort_date,
        country_code,
        os,
        lcm_id,
        MAX(current_days_since_cohort) AS current_days_since_cohort,
        SUM(CASE WHEN days_since_cohort <= 0 THEN daily_purchase ELSE 0 END) AS ltv_1,
        SUM(CASE WHEN days_since_cohort <= 2 THEN daily_purchase ELSE 0 END) AS ltv_3,
        SUM(CASE WHEN days_since_cohort <= 6 THEN daily_purchase ELSE 0 END) AS ltv_7,
        SUM(CASE WHEN days_since_cohort <= 13 THEN daily_purchase ELSE 0 END) AS ltv_14,
        SUM(CASE WHEN days_since_cohort <= 29 THEN daily_purchase ELSE 0 END) AS ltv_30,
        SUM(CASE WHEN days_since_cohort <= 59 THEN daily_purchase ELSE 0 END) AS ltv_60,
        SUM(CASE WHEN days_since_cohort <= 89 THEN daily_purchase ELSE 0 END) AS ltv_90,
        SUM(CASE WHEN days_since_cohort <= 179 THEN daily_purchase ELSE 0 END) AS ltv_180,
        MAX(CASE WHEN days_since_cohort = 1 THEN 1 ELSE 0 END) AS ret_1,
        MAX(CASE WHEN days_since_cohort = 3 THEN 1 ELSE 0 END) AS ret_3,
        MAX(CASE WHEN days_since_cohort = 7 THEN 1 ELSE 0 END) AS ret_7,
        MAX(CASE WHEN days_since_cohort = 14 THEN 1 ELSE 0 END) AS ret_14,
        MAX(CASE WHEN days_since_cohort = 30 THEN 1 ELSE 0 END) AS ret_30,
        MAX(CASE WHEN days_since_cohort = 60 THEN 1 ELSE 0 END) AS ret_60,
        MAX(CASE WHEN days_since_cohort = 90 THEN 1 ELSE 0 END) AS ret_90,
        MAX(CASE WHEN days_since_cohort = 180 THEN 1 ELSE 0 END) AS ret_180
    FROM activity
    GROUP BY cohort_date, country_code, os, lcm_id
),

raw_combined AS (
    -- 1. 每日活跃与充值明细
    SELECT
        CAST(day AS BIGINT) AS report_date,
        COALESCE(country_code, 'UNKNOWN') AS country_code,
        COALESCE(os, 'UNKNOWN') AS os,
        lcm_id AS dau_user,
        COALESCE(CAST(purchase AS DOUBLE), 0.0) AS daily_rev,
        NULL AS nuu_user,
        -1 AS current_days_since_cohort,
        0.0 AS ltv_1, 0.0 AS ltv_3, 0.0 AS ltv_7, 0.0 AS ltv_14, 0.0 AS ltv_30, 0.0 AS ltv_60, 0.0 AS ltv_90, 0.0 AS ltv_180,
        0 AS ret_1, 0 AS ret_3, 0 AS ret_7, 0 AS ret_14, 0 AS ret_30, 0 AS ret_60, 0 AS ret_90, 0 AS ret_180
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 65002005
      AND day >= 20231205
      AND is_water = '不是水'

    UNION ALL

    -- 2. 新增留存与LTV明细
    SELECT
        CAST(cohort_date AS BIGINT) AS report_date,
        country_code,
        os,
        NULL AS dau_user,
        0.0 AS daily_rev,
        lcm_id AS nuu_user,
        current_days_since_cohort,
        ltv_1, ltv_3, ltv_7, ltv_14, ltv_30, ltv_60, ltv_90, ltv_180,
        ret_1, ret_3, ret_7, ret_14, ret_30, ret_60, ret_90, ret_180
    FROM user_ltv_ret
)

SELECT
    COALESCE(CAST(report_date AS STRING), '【阶段汇总】') AS `日期`,
    COALESCE(country_code, '汇总') AS `国家代码`,
    COALESCE(os, '汇总') AS `系统`,

    COUNT(DISTINCT nuu_user) AS `新增用户`,
    COUNT(DISTINCT dau_user) AS `活跃用户`,
    ROUND(SUM(daily_rev), 2) AS `当日付费金额_RMB`,
    COUNT(DISTINCT CASE WHEN daily_rev > 0 THEN dau_user END) AS `当日付费人数`,
    ROUND(COUNT(DISTINCT CASE WHEN daily_rev > 0 THEN dau_user END) * 1.0 / NULLIF(COUNT(DISTINCT dau_user), 0), 4) AS `付费率`,
    ROUND(SUM(daily_rev) * 1.0 / NULLIF(COUNT(DISTINCT dau_user), 0), 4) AS `ARPU`,
    ROUND(SUM(daily_rev) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN daily_rev > 0 THEN dau_user END), 0), 4) AS `ARPPU`,

    ROUND(SUM(ret_1) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 1 THEN nuu_user END), 0), 4) AS `次留`,
    ROUND(SUM(ret_3) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 3 THEN nuu_user END), 0), 4) AS `3留`,
    ROUND(SUM(ret_7) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 7 THEN nuu_user END), 0), 4) AS `7留`,
    ROUND(SUM(ret_14) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 14 THEN nuu_user END), 0), 4) AS `14留`,
    ROUND(SUM(ret_30) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 30 THEN nuu_user END), 0), 4) AS `30留`,
    ROUND(SUM(ret_60) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 60 THEN nuu_user END), 0), 4) AS `60留`,
    ROUND(SUM(ret_90) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 90 THEN nuu_user END), 0), 4) AS `90留`,
    ROUND(SUM(ret_180) * 1.0 / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 180 THEN nuu_user END), 0), 4) AS `180留`,

    ROUND(SUM(ltv_1) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 0 THEN nuu_user END), 0), 2) AS `LTV_1`,
    ROUND(SUM(ltv_3) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 2 THEN nuu_user END), 0), 2) AS `LTV_3`,
    ROUND(SUM(ltv_7) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 6 THEN nuu_user END), 0), 2) AS `LTV_7`,
    ROUND(SUM(ltv_14) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 13 THEN nuu_user END), 0), 2) AS `LTV_14`,
    ROUND(SUM(ltv_30) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 29 THEN nuu_user END), 0), 2) AS `LTV_30`,
    ROUND(SUM(ltv_60) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 59 THEN nuu_user END), 0), 2) AS `LTV_60`,
    ROUND(SUM(ltv_90) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 89 THEN nuu_user END), 0), 2) AS `LTV_90`,
    ROUND(SUM(ltv_180) / NULLIF(COUNT(DISTINCT CASE WHEN current_days_since_cohort >= 179 THEN nuu_user END), 0), 2) AS `LTV_180`
FROM raw_combined
GROUP BY
    report_date, country_code, os
GROUPING SETS (
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
