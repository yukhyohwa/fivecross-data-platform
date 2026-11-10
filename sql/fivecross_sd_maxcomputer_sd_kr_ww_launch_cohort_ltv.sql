-- odps sql
-- ============================================================
-- Game   : Slam Dunk 灌篮高手
-- Region : KR (韩国 33002013) 开服 2020-07-29
--          WW/GL (全球 63002013) 开服 2020-11-25
-- Cohort : 按注册日分组，每日队列 LTV
-- Metrics: 新用户数 / LTV_D1 / D7 / D30 / D60 / D90 / D180 / D360
--          单位: RMB (purchase 字段已为人民币)
-- Engine : MaxCompute (ODPS)
-- ============================================================

SET odps.sql.hive.compatible = TRUE;

WITH

-- ① 队列：开服至今所有注册用户，保留注册日
cohort_raw AS (

    -- 灌篮韩国 KR
    SELECT
        '33002013'     AS app_id,
        '灌篮韩国(KR)' AS game_name,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 33002013
      AND day BETWEEN 20200729 AND 20260518
      AND CAST(reg_day AS BIGINT) BETWEEN 20200729 AND 20260518
      AND is_water = '不是水'

    UNION ALL

    -- 灌篮全球 WW/GL
    SELECT
        '63002013'     AS app_id,
        '灌篮全球(WW)' AS game_name,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND day BETWEEN 20201125 AND 20260518
      AND CAST(reg_day AS BIGINT) BETWEEN 20201125 AND 20260518
      AND is_water = '不是水'
),

cohort AS (
    SELECT DISTINCT app_id, game_name, lcm_id, reg_day
    FROM cohort_raw
),

-- ② 关联每日活跃付费，计算注册后第 N 天
activity AS (
    SELECT
        c.app_id,
        c.lcm_id,
        c.reg_day,
        COALESCE(u.purchase, 0) AS daily_purchase,
        DATEDIFF(
            TO_DATE(CAST(u.day     AS STRING), 'yyyymmdd'),
            TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd'),
            'dd'
        ) AS days_since_reg
    FROM cohort c
    INNER JOIN dm_platform.daily_lcx_user_info u
        ON  c.lcm_id               = u.lcm_id
        AND CAST(u.app_id AS STRING) = c.app_id
        AND u.day    >= c.reg_day
        AND u.day    BETWEEN 20200729 AND 20260518
        AND u.is_water = '不是水'
)

-- ③ 按游戏 + 注册日 汇总，LTV 作列
SELECT
    c.game_name                                    AS "游戏",
    TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd') AS "注册日(day)",
    COUNT(DISTINCT c.lcm_id)                       AS "新用户数",

    -- LTV_D1 : D0 当天
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 0   THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D1(RMB)",

    -- LTV_D7 : D0~D6
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 6   THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D7(RMB)",

    -- LTV_D30: D0~D29
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 29  THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D30(RMB)",

    -- LTV_D60: D0~D59
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 59  THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D60(RMB)",

    -- LTV_D90: D0~D89
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 89  THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D90(RMB)",

    -- LTV_D180: D0~D179
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 179 THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D180(RMB)",

    -- LTV_D360: D0~D359
    ROUND(SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 359 THEN a.daily_purchase ELSE 0 END)
          / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS "LTV_D360(RMB)"

FROM cohort c
LEFT JOIN activity a
    ON  c.app_id  = a.app_id
    AND c.lcm_id  = a.lcm_id
GROUP BY
    c.app_id,
    c.game_name,
    c.reg_day
ORDER BY
    c.app_id,
    c.reg_day;
