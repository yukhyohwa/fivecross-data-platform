
/*
================================================================================
Game    : Slam Dunk  灌篮高手
Region  : TC (繁体 23002013) 开服日 2020-05-27
          KR (韩国 33002013) 开服日 2020-07-29
          GL (全球 63002013) 开服日 2020-11-25
Purpose : 开服前30日 首批用户 队列分析
Cohort  : reg_day 落在开服日起 30 天内 [开服日, 开服日+29]
Metrics :
  - 留存率 : D1 / D3 / D7 / D14 / D30 / D60 / D90
  - LTV    : LTV1 / LTV3 / LTV7 / LTV14 / LTV30 / LTV60 / LTV90
             (首日起累计付费 / 队列人数, RMB)
  - DARPU  : 加权均值 (所有有效活跃日的 purchase / DAU, 然后对日期做平均)
             = SUM(日付费总额) / SUM(日活跃人数), 取 D0-D89 窗口
Engine  : MaxCompute (ODPS)
Notes   :
  - 留存定义: 第 N 天当日登录 (精确日, 非范围)
  - purchase 字段已为当日付费金额 (RMB)
  - DATEDIFF(end, start, 'dd') in MaxCompute returns end - start in days
================================================================================
*/

SET odps.sql.hive.compatible = TRUE;

-- ============================================================
-- Step 1: 定义两款游戏的首批用户 (开服后 30 日内注册)
-- ============================================================
WITH cohort_raw AS (
    -- 灌篮繁体 TC: 开服 20200527, 首批 = 20200527 ~ 20200625
    SELECT
        '23002013'  AS app_id,
        '灌篮繁体(TC)' AS game_name,
        20200527    AS launch_day,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 23002013
      AND day BETWEEN 20200527 AND 20200625  -- 分区谓词: 只扫注册窗口30天
      AND CAST(reg_day AS BIGINT) BETWEEN 20200527 AND 20200625
      AND is_water = '不是水'   -- 排除水号/内部账号

    UNION ALL

    -- 灌蓝全球 GL: 开服 20201125, 首批 = 20201125 ~ 20201224
    SELECT
        '63002013'  AS app_id,
        '灌篮全球(GL)' AS game_name,
        20201125    AS launch_day,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013
      AND day BETWEEN 20201125 AND 20201224  -- 分区谓词: 只扫注册窗口30天
      AND CAST(reg_day AS BIGINT) BETWEEN 20201125 AND 20201224
      AND is_water = '不是水'   -- 排除水号/内部账号

    UNION ALL

    -- 灌篮韩国 KR: 开服 20200729, 首批 = 20200729 ~ 20200827
    SELECT
        '33002013'  AS app_id,
        '灌篮韩国(KR)' AS game_name,
        20200729    AS launch_day,
        lcm_id,
        CAST(reg_day AS BIGINT) AS reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 33002013
      AND day BETWEEN 20200729 AND 20200827  -- 分区谓词: 只扫注册窗口30天
      AND CAST(reg_day AS BIGINT) BETWEEN 20200729 AND 20200827
      AND is_water = '不是水'   -- 排除水号/内部账号
),

-- 去重: 同一用户在同一游戏中只取一条注册记录
cohort AS (
    SELECT DISTINCT app_id, game_name, launch_day, lcm_id, reg_day
    FROM cohort_raw
),

-- ============================================================
-- Step 2: 关联每位队列用户在 D0~D89 内的每日活跃 & 付费记录
-- ============================================================
activity AS (
    SELECT
        c.app_id,
        c.game_name,
        c.launch_day,
        c.lcm_id,
        c.reg_day,
        u.day         AS activity_day,
        COALESCE(u.purchase, 0) AS daily_purchase,
        DATEDIFF(
            TO_DATE(CAST(u.day    AS STRING), 'yyyymmdd'),
            TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd'),
            'dd'
        ) AS days_since_reg
    FROM cohort c
    INNER JOIN dm_platform.daily_lcx_user_info u
        ON  c.lcm_id  = u.lcm_id
        AND CAST(u.app_id AS STRING) = c.app_id
        AND u.day BETWEEN 20200527 AND 20210228 -- 分区谓词: TC D0(20200527) ~ GL D89(20210223)
        AND u.day >= c.reg_day          -- 精确: 从各自注册日起
        AND u.is_water = '不是水'       -- 活跃记录同样过滤水号
        AND DATEDIFF(
                TO_DATE(CAST(u.day    AS STRING), 'yyyymmdd'),
                TO_DATE(CAST(c.reg_day AS STRING), 'yyyymmdd'),
                'dd'
            ) <= 90                     -- 最多到 D89 (LTV90 / D90留存窗口)
),

-- ============================================================
-- Step 3: 按游戏汇总留存 / LTV / DARPU
-- ============================================================
agg AS (
    SELECT
        c.app_id,
        c.game_name,
        c.launch_day,

        -- 队列总人数
        COUNT(DISTINCT c.lcm_id) AS cohort_size,

        -- ── 留存率 (精确日登录) ──────────────────────────────
        -- D1 次留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 1  THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d1,
        -- D3 三留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 3  THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d3,
        -- D7 七留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 7  THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d7,
        -- D14 十四留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 14 THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d14,
        -- D30 三十留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 30 THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d30,
        -- D60 六十留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 60 THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d60,
        -- D90 九十留
        COUNT(DISTINCT CASE WHEN a.days_since_reg = 90 THEN a.lcm_id END) * 1.0
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0) AS retention_d90,

        -- ── LTV (RMB, 累计付费 / 队列人数) ───────────────────
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 0  THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv1,
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 2  THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv3,
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 6  THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv7,
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 13 THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv14,
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 29 THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv30,
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 59 THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv60,
        ROUND(
            SUM(CASE WHEN a.days_since_reg BETWEEN 0 AND 89 THEN a.daily_purchase ELSE 0 END)
            / NULLIF(COUNT(DISTINCT c.lcm_id), 0), 4) AS ltv90,

        -- ── DARPU 加权均值 (D0-D89 窗口) ──────────────────────
        -- 定义: DARPU = SUM(所有日付费总额) / SUM(所有日活跃人次)
        --        对跨日数据加权: 分子是总流水, 分母是总活跃人次(可以理解为日均 ARPU 的人次加权均值)
        ROUND(
            SUM(a.daily_purchase)
            / NULLIF(COUNT(a.lcm_id), 0),   -- COUNT(non-null) = 活跃记录条数 = 活跃人次
        4) AS darpu_d0_d89_weighted

    FROM cohort c
    LEFT JOIN activity a
        ON  c.app_id  = a.app_id
        AND c.lcm_id  = a.lcm_id
    GROUP BY
        c.app_id,
        c.game_name,
        c.launch_day
)

-- ============================================================
-- Step 4: 最终输出
-- ============================================================
SELECT
    game_name                                    AS "游戏",
    launch_day                                   AS "开服日",
    cohort_size                                  AS "首批用户数(前30日注册)",

    -- 留存率
    ROUND(retention_d1  * 100, 2)               AS "次留D1(%)",
    ROUND(retention_d3  * 100, 2)               AS "三留D3(%)",
    ROUND(retention_d7  * 100, 2)               AS "七留D7(%)",
    ROUND(retention_d14 * 100, 2)               AS "十四留D14(%)",
    ROUND(retention_d30 * 100, 2)               AS "三十留D30(%)",
    ROUND(retention_d60 * 100, 2)               AS "六十留D60(%)",
    ROUND(retention_d90 * 100, 2)               AS "九十留D90(%)",

    -- LTV (RMB)
    ltv1                                         AS "LTV1(RMB)",
    ltv3                                         AS "LTV3(RMB)",
    ltv7                                         AS "LTV7(RMB)",
    ltv14                                        AS "LTV14(RMB)",
    ltv30                                        AS "LTV30(RMB)",
    ltv60                                        AS "LTV60(RMB)",
    ltv90                                        AS "LTV90(RMB)",

    -- DARPU
    darpu_d0_d89_weighted                        AS "DARPU加权均值(D0-D89,RMB)"

FROM agg
ORDER BY launch_day ASC;
