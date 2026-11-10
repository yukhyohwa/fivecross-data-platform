/*
================================================================================
Game    : Slam Dunk 灌篮高手
Region  : TC (繁体 23002013) 开服日 2020-05-27
          KR (韩国 33002013) 开服日 2020-07-29
          GL (全球 63002013) 开服日 2020-11-25
Purpose : 开服后前 13 个月，分月流水 & 分月 NUU
Metrics :
  - 月流水 : 当月所有真实用户 purchase 汇总 (RMB)
  - 月NUU  : 当月新注册用户数 (来自 lcx_user_reg)
  - 开服第N月: 1 = 开服当月
Engine  : MaxCompute (ODPS)
Notes   :
  - TC 前13月: 202005 ~ 202105  (day: 20200527 ~ 20210531)
  - KR 前13月: 202007 ~ 202107  (day: 20200729 ~ 20210731)
  - GL 前13月: 202011 ~ 202111  (day: 20201125 ~ 20211130)
================================================================================
*/

SET odps.sql.hive.compatible = TRUE;

WITH

-- ── 分月流水 ────────────────────────────────────────────────
monthly_rev AS (
    -- TC: 开服 20200527, 前13个月 day 范围
    SELECT
        '23002013'              AS app_id,
        CAST(day / 100 AS BIGINT) AS month,
        ROUND(SUM(purchase), 2) AS monthly_revenue
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 23002013
      AND day BETWEEN 20200527 AND 20210531  -- 分区谓词
      AND is_water = '不是水'
    GROUP BY CAST(day / 100 AS BIGINT)

    UNION ALL

    -- KR: 开服 20200729, 前13个月 day 范围
    SELECT
        '33002013'              AS app_id,
        CAST(day / 100 AS BIGINT) AS month,
        ROUND(SUM(purchase), 2) AS monthly_revenue
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 33002013
      AND day BETWEEN 20200729 AND 20210731  -- 分区谓词
      AND is_water = '不是水'
    GROUP BY CAST(day / 100 AS BIGINT)

    UNION ALL

    -- GL: 开服 20201125, 前13个月 day 范围
    SELECT
        '63002013'              AS app_id,
        CAST(day / 100 AS BIGINT) AS month,
        ROUND(SUM(purchase), 2) AS monthly_revenue
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND day BETWEEN 20201125 AND 20211130  -- 分区谓词
      AND is_water = '不是水'
    GROUP BY CAST(day / 100 AS BIGINT)
),

-- ── 分月 NUU ────────────────────────────────────────────────
monthly_nuu AS (
    -- TC: 注册当天 reg_day = day, 只扫注册窗口分区
    SELECT
        '23002013'             AS app_id,
        CAST(day / 100 AS BIGINT) AS month,
        COUNT(DISTINCT lcm_id) AS nuu
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 23002013
      AND day BETWEEN 20200527 AND 20210531  -- 分区谓词
      AND CAST(reg_day AS BIGINT) = day      -- 仅取注册当天记录 = NUU
      AND is_water = '不是水'
    GROUP BY CAST(day / 100 AS BIGINT)

    UNION ALL

    -- KR: 注册当天 reg_day = day, 只扫注册窗口分区
    SELECT
        '33002013'             AS app_id,
        CAST(day / 100 AS BIGINT) AS month,
        COUNT(DISTINCT lcm_id) AS nuu
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 33002013
      AND day BETWEEN 20200729 AND 20210731  -- 分区谓词
      AND CAST(reg_day AS BIGINT) = day      -- 仅取注册当天记录 = NUU
      AND is_water = '不是水'
    GROUP BY CAST(day / 100 AS BIGINT)

    UNION ALL

    -- GL
    SELECT
        '63002013'             AS app_id,
        CAST(day / 100 AS BIGINT) AS month,
        COUNT(DISTINCT lcm_id) AS nuu
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND day BETWEEN 20201125 AND 20211130  -- 分区谓词
      AND CAST(reg_day AS BIGINT) = day      -- 仅取注册当天记录 = NUU
      AND is_water = '不是水'
    GROUP BY CAST(day / 100 AS BIGINT)
)

-- ── 输出 ────────────────────────────────────────────────────
SELECT
    CASE r.app_id
        WHEN '23002013' THEN '灌篮繁体(TC)'
        WHEN '33002013' THEN '灌篮韩国(KR)'
        WHEN '63002013' THEN '灌篮全球(GL)'
    END                                     AS "游戏",
    r.month                                 AS "月份(YYYYMM)",
    -- 开服第N月: (年差*12 + 月差 + 1)
    CASE r.app_id
        WHEN '23002013' THEN (r.month / 100 - 2020) * 12 + (r.month % 100 - 5)  + 1
        WHEN '33002013' THEN (r.month / 100 - 2020) * 12 + (r.month % 100 - 7)  + 1
        WHEN '63002013' THEN (r.month / 100 - 2020) * 12 + (r.month % 100 - 11) + 1
    END                                     AS "开服第N月",
    COALESCE(n.nuu, 0)                      AS "月NUU",
    COALESCE(r.monthly_revenue, 0)          AS "月流水(RMB)"

FROM monthly_rev r
LEFT JOIN monthly_nuu n
    ON  r.app_id = n.app_id
    AND r.month  = n.month

-- 只保留前13个月 (防止边界多出1行)
WHERE
    CASE r.app_id
        WHEN '23002013' THEN (r.month / 100 - 2020) * 12 + (r.month % 100 - 5)  + 1
        WHEN '33002013' THEN (r.month / 100 - 2020) * 12 + (r.month % 100 - 7)  + 1
        WHEN '63002013' THEN (r.month / 100 - 2020) * 12 + (r.month % 100 - 11) + 1
    END BETWEEN 1 AND 13

ORDER BY
    r.app_id ASC,
    r.month  ASC;
