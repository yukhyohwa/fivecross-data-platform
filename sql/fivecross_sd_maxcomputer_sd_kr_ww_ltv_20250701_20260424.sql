-- odps sql
-- ============================================================
-- Game   : Slam Dunk 灌篮高手
-- Region : KR (韩国 33002013) & WW/GL (全球 63002013)
-- Cohort : 按注册日分组，每日队列 LTV (1,3,7,14,30,60,90,120,150,180)
-- 时间范围: 注册日 20250701 - 20260424
-- 维度   : 注册日期, OS (Android, iOS, 汇总), 以及阶段汇总
-- Engine : MaxCompute (ODPS)
-- ============================================================

SET odps.sql.hive.compatible = TRUE;

WITH cohort_raw AS (
    -- 韩国 KR 注册用户
    SELECT
        'KR' AS region,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day,
        CASE WHEN LOWER(os) LIKE '%android%' THEN 'Android'
             WHEN LOWER(os) LIKE '%ios%' THEN 'iOS'
             ELSE 'Other' END AS os_group
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 33002013
      AND day BETWEEN 20250701 AND 20260424
      AND CAST(reg_day AS BIGINT) BETWEEN 20250701 AND 20260424
      AND is_water = '不是水'
      
    UNION ALL

    -- 全球 WW 注册用户
    SELECT
        'WW' AS region,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day,
        CASE WHEN LOWER(os) LIKE '%android%' THEN 'Android'
             WHEN LOWER(os) LIKE '%ios%' THEN 'iOS'
             ELSE 'Other' END AS os_group
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND day BETWEEN 20250701 AND 20260424
      AND CAST(reg_day AS BIGINT) BETWEEN 20250701 AND 20260424
      AND is_water = '不是水'
),
cohort AS (
    -- 去重
    SELECT DISTINCT region, lcm_id, reg_day, os_group
    FROM cohort_raw
),
activity AS (
    SELECT 
        c.region,
        c.lcm_id,
        c.reg_day,
        c.os_group,
        COALESCE(u.purchase, 0) AS daily_purchase,
        -- 使用当前时间判断队列的成熟天数，用于后续阶段汇总剔除
        DATEDIFF(GETDATE(), TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd'), 'dd') AS current_days_since_reg,
        -- 计算发生付费时距离注册的天数
        DATEDIFF(TO_DATE(CAST(u.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd'), 'dd') AS days_since_reg
    FROM cohort c
    LEFT JOIN dm_platform.daily_lcx_user_info u
        ON  c.lcm_id = u.lcm_id
        AND u.app_id IN (33002013, 63002013)
        AND u.day >= c.reg_day
        AND u.day >= 20250701
        AND u.is_water = '不是水'
        -- 确保 WW 和 KR 的 app_id 正确匹配
        AND ( (c.region = 'KR' AND u.app_id = 33002013) OR (c.region = 'WW' AND u.app_id = 63002013) )
),
user_ltv AS (
    -- 将用户在指定期限内的 LTV 进行摊平汇总
    SELECT 
        region,
        reg_day,
        os_group,
        lcm_id,
        MAX(current_days_since_reg) AS current_days_since_reg,
        SUM(CASE WHEN days_since_reg <= 0 THEN daily_purchase ELSE 0 END) AS ltv_1,
        SUM(CASE WHEN days_since_reg <= 2 THEN daily_purchase ELSE 0 END) AS ltv_3,
        SUM(CASE WHEN days_since_reg <= 6 THEN daily_purchase ELSE 0 END) AS ltv_7,
        SUM(CASE WHEN days_since_reg <= 13 THEN daily_purchase ELSE 0 END) AS ltv_14,
        SUM(CASE WHEN days_since_reg <= 29 THEN daily_purchase ELSE 0 END) AS ltv_30,
        SUM(CASE WHEN days_since_reg <= 59 THEN daily_purchase ELSE 0 END) AS ltv_60,
        SUM(CASE WHEN days_since_reg <= 89 THEN daily_purchase ELSE 0 END) AS ltv_90,
        SUM(CASE WHEN days_since_reg <= 119 THEN daily_purchase ELSE 0 END) AS ltv_120,
        SUM(CASE WHEN days_since_reg <= 149 THEN daily_purchase ELSE 0 END) AS ltv_150,
        SUM(CASE WHEN days_since_reg <= 179 THEN daily_purchase ELSE 0 END) AS ltv_180
    FROM activity
    GROUP BY region, reg_day, os_group, lcm_id
)

/*
================================================================================
单一 SQL 联合输出每日明细与阶段汇总 (MaxCompute)
利用 GROUPING SETS，当“注册日期”为 NULL 时，即为【阶段汇总】。
已包含成熟度校验（如队列距今未达 180 天，则不计入 D180_分母，LTV_180 算空缺）。
================================================================================
*/
SELECT 
    region AS "地区",
    COALESCE(CAST(reg_day AS STRING), '【阶段汇总】') AS "注册日期",
    COALESCE(os_group, '汇总') AS "OS",
    COUNT(DISTINCT lcm_id) AS "总注册人数",

    -- LTV 1
    -- SUM(CASE WHEN current_days_since_reg >= 0 THEN 1 ELSE 0 END) AS "D1_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 0 THEN ltv_1 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 0 THEN 1 ELSE 0 END), 0), 2) AS "LTV_1",
    
    -- LTV 3
    -- SUM(CASE WHEN current_days_since_reg >= 2 THEN 1 ELSE 0 END) AS "D3_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 2 THEN ltv_3 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 2 THEN 1 ELSE 0 END), 0), 2) AS "LTV_3",
    
    -- LTV 7
    -- SUM(CASE WHEN current_days_since_reg >= 6 THEN 1 ELSE 0 END) AS "D7_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 6 THEN ltv_7 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 6 THEN 1 ELSE 0 END), 0), 2) AS "LTV_7",
    
    -- LTV 14
    -- SUM(CASE WHEN current_days_since_reg >= 13 THEN 1 ELSE 0 END) AS "D14_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 13 THEN ltv_14 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 13 THEN 1 ELSE 0 END), 0), 2) AS "LTV_14",
    
    -- LTV 30
    -- SUM(CASE WHEN current_days_since_reg >= 29 THEN 1 ELSE 0 END) AS "D30_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 29 THEN ltv_30 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 29 THEN 1 ELSE 0 END), 0), 2) AS "LTV_30",
    
    -- LTV 60
    -- SUM(CASE WHEN current_days_since_reg >= 59 THEN 1 ELSE 0 END) AS "D60_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 59 THEN ltv_60 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 59 THEN 1 ELSE 0 END), 0), 2) AS "LTV_60",
    
    -- LTV 90
    -- SUM(CASE WHEN current_days_since_reg >= 89 THEN 1 ELSE 0 END) AS "D90_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 89 THEN ltv_90 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 89 THEN 1 ELSE 0 END), 0), 2) AS "LTV_90",
    
    -- LTV 120
    -- SUM(CASE WHEN current_days_since_reg >= 119 THEN 1 ELSE 0 END) AS "D120_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 119 THEN ltv_120 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 119 THEN 1 ELSE 0 END), 0), 2) AS "LTV_120",

    -- LTV 150
    -- SUM(CASE WHEN current_days_since_reg >= 149 THEN 1 ELSE 0 END) AS "D150_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 149 THEN ltv_150 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 149 THEN 1 ELSE 0 END), 0), 2) AS "LTV_150",
    
    -- LTV 180
    -- SUM(CASE WHEN current_days_since_reg >= 179 THEN 1 ELSE 0 END) AS "D180_分母(人)",
    ROUND(SUM(CASE WHEN current_days_since_reg >= 179 THEN ltv_180 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_reg >= 179 THEN 1 ELSE 0 END), 0), 2) AS "LTV_180"

FROM user_ltv
GROUP BY 
    region, reg_day, os_group
GROUPING SETS (
    (region, reg_day, os_group),
    (region, reg_day),
    (region, os_group),
    (region)
)
ORDER BY 
    region, 
    CASE WHEN reg_day IS NULL THEN 0 ELSE 1 END, 
    reg_day DESC, 
    os_group;
