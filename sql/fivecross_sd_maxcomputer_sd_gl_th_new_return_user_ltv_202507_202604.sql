-- odps sql
-- ============================================================
-- Game   : Slam Dunk 灌篮高手
-- Region : GL/WW (全球 63002013) - Thailand (泰国, country_code = 'TH')
-- Cohort : 按事件日(注册或回流日)分组，新增与60天以上回归用户的每日队列 LTV (1,3,7,14,30,60,90,120,150,180)
-- 时间范围: 注册/回流日 20250701 - 20260424
-- 维度   : 注册或回流日期, 用户类型(新增/回流), OS (Android, iOS, 汇总), 以及阶段汇总
-- Engine : MaxCompute (ODPS)
-- ============================================================

SET odps.sql.hive.compatible = TRUE;

WITH user_log AS (
    -- 1. 提取泰国用户的登录日志并计算上一次登录时间以识别回流
    SELECT
        lcm_id,
        day,
        CAST(reg_day AS BIGINT) AS reg_day,
        CASE WHEN LOWER(os) LIKE '%android%' THEN 'Android'
             WHEN LOWER(os) LIKE '%ios%' THEN 'iOS'
             ELSE 'Other' END AS os_group,
        LAG(day, 1) OVER (PARTITION BY lcm_id ORDER BY day) AS last_login_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND country_code = 'TH'
      AND day >= 20250501 -- 向前追溯以覆盖2025.05开始未登录的判定（60天）
      AND is_water = '不是水'
),

cohort AS (
    -- 2. 筛选目标周期内的纯新注册用户（新增）与 60天以上未登回归老用户（回流）
    SELECT DISTINCT
        lcm_id,
        day AS event_day,
        os_group,
        user_type
    FROM (
        SELECT
            lcm_id,
            day,
            reg_day,
            os_group,
            DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 'dd') AS days_since_last,
            DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(reg_day AS STRING), 'yyyymmdd'), 'dd') AS days_since_reg,
            last_login_day,
            CASE WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN '新增'
                 ELSE '回流' END AS user_type
        FROM user_log
    ) t
    WHERE day BETWEEN 20250701 AND 20260424
      AND (
          user_type = '新增'
          OR (user_type = '回流' AND (days_since_last > 60 OR (last_login_day IS NULL AND days_since_reg > 60)))
      )
),

activity AS (
    -- 3. 关联用户的付费记录
    SELECT 
        c.lcm_id,
        c.event_day,
        c.os_group,
        c.user_type,
        COALESCE(u.purchase, 0) AS daily_purchase,
        -- 使用当前时间判断队列的成熟天数，用于后续阶段汇总剔除
        DATEDIFF(GETDATE(), TO_DATE(CAST(c.event_day AS STRING), 'yyyymmdd'), 'dd') AS current_days_since_event,
        -- 计算发生付费时距离注册或回流的天数
        DATEDIFF(TO_DATE(CAST(u.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(c.event_day AS STRING), 'yyyymmdd'), 'dd') AS days_since_event
    FROM cohort c
    LEFT JOIN dm_platform.daily_lcx_user_info u
        ON  c.lcm_id = u.lcm_id
        AND u.app_id = 63002013
        AND u.country_code = 'TH'
        AND u.day >= c.event_day
        AND u.day >= 20250701
        AND u.is_water = '不是水'
),

user_ltv AS (
    -- 4. 汇总用户付费数据
    SELECT 
        event_day,
        os_group,
        user_type,
        lcm_id,
        MAX(current_days_since_event) AS current_days_since_event,
        SUM(CASE WHEN days_since_event <= 0 THEN daily_purchase ELSE 0 END) AS ltv_1,
        SUM(CASE WHEN days_since_event <= 2 THEN daily_purchase ELSE 0 END) AS ltv_3,
        SUM(CASE WHEN days_since_event <= 6 THEN daily_purchase ELSE 0 END) AS ltv_7,
        SUM(CASE WHEN days_since_event <= 13 THEN daily_purchase ELSE 0 END) AS ltv_14,
        SUM(CASE WHEN days_since_event <= 29 THEN daily_purchase ELSE 0 END) AS ltv_30,
        SUM(CASE WHEN days_since_event <= 59 THEN daily_purchase ELSE 0 END) AS ltv_60,
        SUM(CASE WHEN days_since_event <= 89 THEN daily_purchase ELSE 0 END) AS ltv_90,
        SUM(CASE WHEN days_since_event <= 119 THEN daily_purchase ELSE 0 END) AS ltv_120,
        SUM(CASE WHEN days_since_event <= 149 THEN daily_purchase ELSE 0 END) AS ltv_150,
        SUM(CASE WHEN days_since_event <= 179 THEN daily_purchase ELSE 0 END) AS ltv_180
    FROM activity
    GROUP BY event_day, os_group, user_type, lcm_id
)

-- 5. 联合输出每日明细与多维阶段汇总
SELECT 
    COALESCE(CAST(event_day AS STRING), '【阶段汇总】') AS "注册或回流日期",
    COALESCE(user_type, '全部') AS "用户类型",
    COALESCE(os_group, '汇总') AS "OS",
    COUNT(DISTINCT lcm_id) AS "总人数",

    -- LTV 1
    ROUND(SUM(CASE WHEN current_days_since_event >= 0 THEN ltv_1 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 0 THEN 1 ELSE 0 END), 0), 2) AS "LTV_1",
    
    -- LTV 3
    ROUND(SUM(CASE WHEN current_days_since_event >= 2 THEN ltv_3 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 2 THEN 1 ELSE 0 END), 0), 2) AS "LTV_3",
    
    -- LTV 7
    ROUND(SUM(CASE WHEN current_days_since_event >= 6 THEN ltv_7 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 6 THEN 1 ELSE 0 END), 0), 2) AS "LTV_7",
    
    -- LTV 14
    ROUND(SUM(CASE WHEN current_days_since_event >= 13 THEN ltv_14 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 13 THEN 1 ELSE 0 END), 0), 2) AS "LTV_14",
    
    -- LTV 30
    ROUND(SUM(CASE WHEN current_days_since_event >= 29 THEN ltv_30 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 29 THEN 1 ELSE 0 END), 0), 2) AS "LTV_30",
    
    -- LTV 60
    ROUND(SUM(CASE WHEN current_days_since_event >= 59 THEN ltv_60 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 59 THEN 1 ELSE 0 END), 0), 2) AS "LTV_60",
    
    -- LTV 90
    ROUND(SUM(CASE WHEN current_days_since_event >= 89 THEN ltv_90 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 89 THEN 1 ELSE 0 END), 0), 2) AS "LTV_90",
    
    -- LTV 120
    ROUND(SUM(CASE WHEN current_days_since_event >= 119 THEN ltv_120 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 119 THEN 1 ELSE 0 END), 0), 2) AS "LTV_120",

    -- LTV 150
    ROUND(SUM(CASE WHEN current_days_since_event >= 149 THEN ltv_150 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 149 THEN 1 ELSE 0 END), 0), 2) AS "LTV_150",
    
    -- LTV 180
    ROUND(SUM(CASE WHEN current_days_since_event >= 179 THEN ltv_180 ELSE 0 END) / NULLIF(SUM(CASE WHEN current_days_since_event >= 179 THEN 1 ELSE 0 END), 0), 2) AS "LTV_180"

FROM user_ltv
GROUP BY 
    event_day, user_type, os_group
GROUPING SETS (
    (event_day, user_type, os_group),
    (event_day, user_type),
    (event_day, os_group),
    (event_day),
    (user_type, os_group),
    (user_type),
    (os_group),
    ()
)
ORDER BY 
    CASE WHEN event_day IS NULL THEN 0 ELSE 1 END, 
    event_day DESC, 
    user_type, 
    os_group;
