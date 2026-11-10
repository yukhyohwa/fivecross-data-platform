-- ================================================================================
-- 游戏   : 灌篮高手 (Slam Dunk)
-- 区域   : 全球版 GL (63002013)
-- 国家   : 泰国 (TH, country_code = 'TH')
-- 描述   : 泰国开服至今（2020-11-25 至今）每日 Cohort 的新增用户留存率与 LTV 指标
-- 指标   : 新用户数, 留存率 (D1/D7/D30/D60/D90/D180/D360), LTV (LTV_D1/D7/D30/D60/D90/D180/D360)
-- 引擎   : MaxCompute (ODPS)
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

WITH 
--------------------------------------------------------------------------------
-- Step 1: 筛选 20201125 至今的泰国纯新注册用户群 (排除黑名单/水号)
--------------------------------------------------------------------------------
CohortRaw AS (
    SELECT
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND country_code = 'TH'
      AND day >= 20201125 -- 限制分区扫描
      AND CAST(reg_day AS BIGINT) >= 20201125
      AND is_water = '不是水'
),

Cohort AS (
    SELECT DISTINCT 
        lcm_id, 
        reg_day
    FROM CohortRaw
),

--------------------------------------------------------------------------------
-- Step 2: 关联活跃与付费流水，计算注册后第 N 天的偏置
--------------------------------------------------------------------------------
Activity AS (
    SELECT
        c.lcm_id,
        c.reg_day,
        u.day AS activity_day,
        COALESCE(u.purchase, 0) AS daily_purchase,
        DATEDIFF(
            TO_DATE(CAST(u.day AS STRING), 'yyyymmdd'),
            TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd'),
            'dd'
        ) AS days_since_reg
    FROM Cohort c
    INNER JOIN dm_platform.daily_lcx_user_info u
        ON c.lcm_id = u.lcm_id
        AND u.app_id = 63002013
        AND u.country_code = 'TH'
        AND u.day >= c.reg_day
        AND u.day >= 20201125 -- 限制分区扫描
        AND u.is_water = '不是水'
)

--------------------------------------------------------------------------------
-- Step 3: 按注册日期汇总输出新用户数、留存率 (%) 及 LTV (RMB)
--------------------------------------------------------------------------------
SELECT
    TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd')                                                        AS `注册日期`,
    COUNT(DISTINCT c.lcm_id)                                                                              AS `新用户数`,

    -- ── 留存率 (%) ──
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 1   THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `次留(%)`,
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 7   THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `7留(%)`,
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 30  THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `30留(%)`,
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 60  THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `60留(%)`,
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 90  THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `90留(%)`,
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 180 THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `180留(%)`,
    ROUND(COUNT(DISTINCT CASE WHEN a.days_since_reg = 360 THEN a.lcm_id END) * 100.0 / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 2) AS `360留(%)`,

    -- ── LTV (人民币 RMB) ──
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 0   THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D1`,
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 6   THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D7`,
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 29  THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D30`,
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 59  THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D60`,
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 89  THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D90`,
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 179 THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D180`,
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 359 THEN a.daily_purchase ELSE 0 END) / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS `LTV_D360`

FROM Cohort c
LEFT JOIN Activity a
    ON c.lcm_id = a.lcm_id
GROUP BY
    c.reg_day
ORDER BY
    c.reg_day;
