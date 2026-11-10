-- odps sql
-- ============================================================
-- Game   : Slam Dunk 灌篮高手
-- Region : GL/WW (全球 63002013) - Thailand (泰国, country_code = 'TH')
-- Cohort : 按事件日(注册日)分组，新用户每日队列留存(%)与LTV (1,3,7,14,30,60,90,120,150,180)
-- 时间范围: 注册日 20250701 - 20260430
-- 维度   : 地区, 注册日期, OS (Android, iOS, 汇总), 以及阶段汇总
-- Engine : MaxCompute (ODPS)
-- ============================================================

SET odps.sql.hive.compatible = TRUE;

WITH cohort AS (
    -- 1. 筛选目标周期内的纯新注册用户（新增）
    SELECT DISTINCT
        'WW-TH' AS region,
        lcm_id,
        day AS cohort_date,
        CASE WHEN LOWER(os) LIKE '%android%' THEN 'Android'
             WHEN LOWER(os) LIKE '%ios%' THEN 'iOS'
             ELSE 'Other' END AS os_group
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND country_code = 'TH'
      AND day BETWEEN 20250701 AND 20260430
      AND CAST(reg_day AS BIGINT) = CAST(day AS BIGINT)
      AND is_water = '不是水'
),

activity AS (
    -- 2. 关联新增用户的付费与登录记录
    SELECT 
        c.region,
        c.lcm_id,
        c.cohort_date,
        c.os_group,
        COALESCE(u.purchase, 0) AS daily_purchase,
        -- 使用当前时间判断队列的成熟天数，用于后续阶段汇总及留存剔除
        DATEDIFF(GETDATE(), TO_DATE(CAST(c.cohort_date AS STRING), 'yyyymmdd'), 'dd') AS current_days_since_cohort,
        -- 计算发生付费或登录时距离注册的天数
        DATEDIFF(TO_DATE(CAST(u.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(c.cohort_date AS STRING), 'yyyymmdd'), 'dd') AS days_since_cohort
    FROM cohort c
    LEFT JOIN dm_platform.daily_lcx_user_info u
        ON  c.lcm_id = u.lcm_id
        AND u.app_id = 63002013
        AND u.country_code = 'TH'
        AND u.day >= c.cohort_date
        AND u.is_water = '不是水'
),

user_ltv_ret AS (
    -- 3. 汇总每个用户在各阶段 of LTV 付费与留存标志
    SELECT 
        region,
        cohort_date,
        os_group,
        lcm_id,
        MAX(current_days_since_cohort) AS current_days_since_cohort,
        -- LTV
        SUM(CASE WHEN days_since_cohort <= 0 THEN daily_purchase ELSE 0 END) AS ltv_1,
        SUM(CASE WHEN days_since_cohort <= 2 THEN daily_purchase ELSE 0 END) AS ltv_3,
        SUM(CASE WHEN days_since_cohort <= 6 THEN daily_purchase ELSE 0 END) AS ltv_7,
        SUM(CASE WHEN days_since_cohort <= 13 THEN daily_purchase ELSE 0 END) AS ltv_14,
        SUM(CASE WHEN days_since_cohort <= 29 THEN daily_purchase ELSE 0 END) AS ltv_30,
        SUM(CASE WHEN days_since_cohort <= 59 THEN daily_purchase ELSE 0 END) AS ltv_60,
        SUM(CASE WHEN days_since_cohort <= 89 THEN daily_purchase ELSE 0 END) AS ltv_90,
        SUM(CASE WHEN days_since_cohort <= 119 THEN daily_purchase ELSE 0 END) AS ltv_120,
        SUM(CASE WHEN days_since_cohort <= 149 THEN daily_purchase ELSE 0 END) AS ltv_150,
        SUM(CASE WHEN days_since_cohort <= 179 THEN daily_purchase ELSE 0 END) AS ltv_180,
        -- Retention Flags
        MAX(CASE WHEN days_since_cohort = 1 THEN 1 ELSE 0 END) AS ret_1,
        MAX(CASE WHEN days_since_cohort = 3 THEN 1 ELSE 0 END) AS ret_3,
        MAX(CASE WHEN days_since_cohort = 7 THEN 1 ELSE 0 END) AS ret_7,
        MAX(CASE WHEN days_since_cohort = 14 THEN 1 ELSE 0 END) AS ret_14,
        MAX(CASE WHEN days_since_cohort = 30 THEN 1 ELSE 0 END) AS ret_30,
        MAX(CASE WHEN days_since_cohort = 60 THEN 1 ELSE 0 END) AS ret_60,
        MAX(CASE WHEN days_since_cohort = 90 THEN 1 ELSE 0 END) AS ret_90,
        MAX(CASE WHEN days_since_cohort = 120 THEN 1 ELSE 0 END) AS ret_120,
        MAX(CASE WHEN days_since_cohort = 150 THEN 1 ELSE 0 END) AS ret_150,
        MAX(CASE WHEN days_since_cohort = 180 THEN 1 ELSE 0 END) AS ret_180
    FROM activity
    GROUP BY region, cohort_date, os_group, lcm_id
)

-- 4. 联合输出每日明细与多维阶段汇总
SELECT 
    region AS "地区",
    COALESCE(CAST(cohort_date AS STRING), '【阶段汇总】') AS "日期",
    COALESCE(os_group, '汇总') AS "OS",
    COUNT(DISTINCT lcm_id) AS "人数",

    -- ── 留存率 (%) ──
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 1 THEN ret_1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 1 THEN 1 ELSE 0 END), 0), 2) AS "次留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 3 THEN ret_3 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 3 THEN 1 ELSE 0 END), 0), 2) AS "3留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 7 THEN ret_7 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 7 THEN 1 ELSE 0 END), 0), 2) AS "7留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 14 THEN ret_14 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 14 THEN 1 ELSE 0 END), 0), 2) AS "14留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 30 THEN ret_30 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 30 THEN 1 ELSE 0 END), 0), 2) AS "30留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 60 THEN ret_60 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 60 THEN 1 ELSE 0 END), 0), 2) AS "60留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 90 THEN ret_90 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 90 THEN 1 ELSE 0 END), 0), 2) AS "90留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 120 THEN ret_120 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 120 THEN 1 ELSE 0 END), 0), 2) AS "120留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 150 THEN ret_150 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 150 THEN 1 ELSE 0 END), 0), 2) AS "150留(%)",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 180 THEN ret_180 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 180 THEN 1 ELSE 0 END), 0), 2) AS "180留(%)",

    -- ── LTV ──
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 0 THEN ltv_1 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 0 THEN 1 ELSE 0 END), 0), 2) AS "LTV_1",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 2 THEN ltv_3 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 2 THEN 1 ELSE 0 END), 0), 2) AS "LTV_3",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 6 THEN ltv_7 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 6 THEN 1 ELSE 0 END), 0), 2) AS "LTV_7",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 13 THEN ltv_14 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 13 THEN 1 ELSE 0 END), 0), 2) AS "LTV_14",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 29 THEN ltv_30 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 29 THEN 1 ELSE 0 END), 0), 2) AS "LTV_30",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 59 THEN ltv_60 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 59 THEN 1 ELSE 0 END), 0), 2) AS "LTV_60",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 89 THEN ltv_90 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 89 THEN 1 ELSE 0 END), 0), 2) AS "LTV_90",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 119 THEN ltv_120 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 119 THEN 1 ELSE 0 END), 0), 2) AS "LTV_120",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 149 THEN ltv_150 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 149 THEN 1 ELSE 0 END), 0), 2) AS "LTV_150",
    ROUND(SUM(CASE WHEN current_days_since_cohort >= 179 THEN ltv_180 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_cohort >= 179 THEN 1 ELSE 0 END), 0), 2) AS "LTV_180"

FROM user_ltv_ret
GROUP BY 
    region, cohort_date, os_group
GROUPING SETS (
    (region, cohort_date, os_group),
    (region, cohort_date),
    (region, os_group),
    (region)
)
ORDER BY 
    region, 
    CASE WHEN cohort_date IS NULL THEN 0 ELSE 1 END, 
    cohort_date DESC, 
    os_group;
