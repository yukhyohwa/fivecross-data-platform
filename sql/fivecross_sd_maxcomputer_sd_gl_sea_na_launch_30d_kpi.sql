-- ================================================================================
-- 游戏: 灌篮高手 (Slam Dunk)
-- 区域: 全球版 GL (63002013)
--       東南亞 (SEA, zone 首位 = 1)  开服日: 2020-11-25
--       北美   (NA,  zone 首位 = 4)  开服日: 2021-12-08
-- 描述: 开服前30日核心KPI汇总
-- 指标:
--   统计时间范围、累计收入、累计NUU、日均DAU
--   加权平均付费率、加权平均ARPU、加权平均ARPPU
--   次留(D2)、3留(D3)、4留(D4)、6留(D6)、7留(D7)、8留(D8)
--   加权LTV1、加权LTV3、加权LTV7
-- 引擎: MaxCompute (ODPS)
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 区域归属：取用户在开服窗口内最早出现的 zone
-- ─────────────────────────────────────────────────────────────────────────────
UserZone AS (
    SELECT
        mbga_uid,
        MIN(zone) AS zone_id
    FROM g63002013.daily_user_snapshot
    WHERE day BETWEEN 20201125 AND 20220107   -- 覆盖两个开服窗口 + 30天
    GROUP BY mbga_uid
),

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 定义两个大区的开服参数
-- ─────────────────────────────────────────────────────────────────────────────
RegionConfig AS (
    SELECT '東南亞' AS region, '1' AS zone_prefix, 20201125 AS launch_day, 20201224 AS end_day
    UNION ALL
    SELECT '北美'   AS region, '4' AS zone_prefix, 20211208 AS launch_day, 20220106 AS end_day
),

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 提取两个大区开服30日内的每日用户数据
-- ─────────────────────────────────────────────────────────────────────────────
DailyBase AS (
    SELECT
        rc.region,
        rc.launch_day,
        rc.end_day,
        u.day,
        u.lcm_id,
        u.purchase,
        u.reg_day,
        -- 开服第N天（1-based）
        DATEDIFF(
            TO_DATE(CAST(u.day AS STRING), 'yyyyMMdd'),
            TO_DATE(CAST(rc.launch_day AS STRING), 'yyyyMMdd'),
            'dd'
        ) + 1 AS launch_day_no
    FROM dm_platform.daily_lcx_user_info u
    INNER JOIN UserZone uz ON u.lcm_id = uz.mbga_uid
    INNER JOIN RegionConfig rc
        ON SUBSTR(uz.zone_id, 1, 1) = rc.zone_prefix
        AND u.day BETWEEN rc.launch_day AND rc.end_day
    WHERE u.app_id = 63002013
),

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 每日聚合：DAU、NUU、付费人数、收入
-- ─────────────────────────────────────────────────────────────────────────────
DailyAgg AS (
    SELECT
        region,
        launch_day,
        end_day,
        day,
        launch_day_no,
        COUNT(DISTINCT lcm_id)                                          AS dau,
        COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day
                            THEN lcm_id END)                            AS nuu,
        COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END)         AS puu,
        SUM(purchase)                                                   AS revenue
    FROM DailyBase
    GROUP BY region, launch_day, end_day, day, launch_day_no
),

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. 留存 & LTV 基础：以注册日为 cohort，追踪后续活跃和付费
--    只取注册日在开服30日内的用户（NUU cohort）
-- ─────────────────────────────────────────────────────────────────────────────
CohortBase AS (
    SELECT
        rc.region,
        rc.launch_day,
        u.lcm_id,
        CAST(u.reg_day AS BIGINT) AS reg_day,
        u.day,
        u.purchase,
        DATEDIFF(
            TO_DATE(CAST(u.day AS STRING), 'yyyyMMdd'),
            TO_DATE(CAST(u.reg_day AS STRING), 'yyyyMMdd'),
            'dd'
        ) AS days_since_reg
    FROM dm_platform.daily_lcx_user_info u
    INNER JOIN UserZone uz ON u.lcm_id = uz.mbga_uid
    INNER JOIN RegionConfig rc
        ON SUBSTR(uz.zone_id, 1, 1) = rc.zone_prefix
    WHERE u.app_id = 63002013
      -- 注册日在开服30日内
      AND CAST(u.reg_day AS BIGINT) BETWEEN rc.launch_day AND rc.end_day
      -- 活跃日覆盖到注册后7天（LTV7 / D8留存需要）
      AND u.day <= rc.end_day + 7
),

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. 按注册日聚合留存人数 & 累计收入（用于 LTV）
--    留存：全30日注册用户
--    LTV ：仅取开服前7天（D1~D7）注册用户，与竞品口径对齐
-- ─────────────────────────────────────────────────────────────────────────────
CohortAgg AS (
    SELECT
        region,
        launch_day,
        reg_day,
        COUNT(DISTINCT lcm_id)                                                  AS cohort_size,
        -- 留存（全30日 cohort）
        COUNT(DISTINCT CASE WHEN days_since_reg = 1 THEN lcm_id END)           AS ret_d2,
        COUNT(DISTINCT CASE WHEN days_since_reg = 2 THEN lcm_id END)           AS ret_d3,
        COUNT(DISTINCT CASE WHEN days_since_reg = 3 THEN lcm_id END)           AS ret_d4,
        COUNT(DISTINCT CASE WHEN days_since_reg = 5 THEN lcm_id END)           AS ret_d6,
        COUNT(DISTINCT CASE WHEN days_since_reg = 6 THEN lcm_id END)           AS ret_d7,
        COUNT(DISTINCT CASE WHEN days_since_reg = 7 THEN lcm_id END)           AS ret_d8,
        -- LTV 收入（仅开服前7天注册用户参与计算，其余置 NULL 以便后续区分）
        CASE WHEN DATEDIFF(
                TO_DATE(CAST(reg_day AS STRING), 'yyyyMMdd'),
                TO_DATE(CAST(launch_day AS STRING), 'yyyyMMdd'),
                'dd') < 7
             THEN SUM(CASE WHEN days_since_reg < 1 THEN purchase ELSE 0 END)
             ELSE NULL END                                                      AS rev_ltv1,
        CASE WHEN DATEDIFF(
                TO_DATE(CAST(reg_day AS STRING), 'yyyyMMdd'),
                TO_DATE(CAST(launch_day AS STRING), 'yyyyMMdd'),
                'dd') < 7
             THEN SUM(CASE WHEN days_since_reg < 3 THEN purchase ELSE 0 END)
             ELSE NULL END                                                      AS rev_ltv3,
        CASE WHEN DATEDIFF(
                TO_DATE(CAST(reg_day AS STRING), 'yyyyMMdd'),
                TO_DATE(CAST(launch_day AS STRING), 'yyyyMMdd'),
                'dd') < 7
             THEN SUM(CASE WHEN days_since_reg < 7 THEN purchase ELSE 0 END)
             ELSE NULL END                                                      AS rev_ltv7,
        -- 前7天 cohort 人数（LTV 分母）
        CASE WHEN DATEDIFF(
                TO_DATE(CAST(reg_day AS STRING), 'yyyyMMdd'),
                TO_DATE(CAST(launch_day AS STRING), 'yyyyMMdd'),
                'dd') < 7
             THEN COUNT(DISTINCT lcm_id)
             ELSE NULL END                                                      AS ltv_cohort_size
    FROM CohortBase
    GROUP BY region, launch_day, reg_day
),

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. 汇总：30日整体指标
-- ─────────────────────────────────────────────────────────────────────────────
DailySummary AS (
    SELECT
        region,
        launch_day,
        end_day,
        MIN(day)                                                                AS stat_start,
        MAX(day)                                                                AS stat_end,
        SUM(revenue)                                                            AS total_revenue,
        SUM(nuu)                                                                AS total_nuu,
        -- 日均 DAU（30天平均）
        ROUND(SUM(dau) * 1.0 / COUNT(DISTINCT day), 0)                         AS avg_dau,
        -- 加权平均付费率 = SUM(puu) / SUM(dau)
        ROUND(SUM(puu) * 1.0 / NULLIF(SUM(dau), 0), 4)                        AS weighted_pay_rate,
        -- 加权平均 ARPU = SUM(revenue) / SUM(dau)
        ROUND(SUM(revenue) * 1.0 / NULLIF(SUM(dau), 0), 4)                    AS weighted_arpu,
        -- 加权平均 ARPPU = SUM(revenue) / SUM(puu)
        ROUND(SUM(revenue) * 1.0 / NULLIF(SUM(puu), 0), 4)                    AS weighted_arppu
    FROM DailyAgg
    GROUP BY region, launch_day, end_day
),

CohortSummary AS (
    SELECT
        region,
        launch_day,
        SUM(cohort_size)                                                        AS total_cohort,
        -- 加权留存率（全30日 cohort）
        ROUND(SUM(ret_d2) * 1.0 / NULLIF(SUM(cohort_size), 0), 4)             AS rr_d2,
        ROUND(SUM(ret_d3) * 1.0 / NULLIF(SUM(cohort_size), 0), 4)             AS rr_d3,
        ROUND(SUM(ret_d4) * 1.0 / NULLIF(SUM(cohort_size), 0), 4)             AS rr_d4,
        ROUND(SUM(ret_d6) * 1.0 / NULLIF(SUM(cohort_size), 0), 4)             AS rr_d6,
        ROUND(SUM(ret_d7) * 1.0 / NULLIF(SUM(cohort_size), 0), 4)             AS rr_d7,
        ROUND(SUM(ret_d8) * 1.0 / NULLIF(SUM(cohort_size), 0), 4)             AS rr_d8,
        -- 加权 LTV（仅前7天 cohort，rev_ltv* 和 ltv_cohort_size 只有前7天有值）
        ROUND(SUM(rev_ltv1) * 1.0 / NULLIF(SUM(ltv_cohort_size), 0), 4)       AS ltv1,
        ROUND(SUM(rev_ltv3) * 1.0 / NULLIF(SUM(ltv_cohort_size), 0), 4)       AS ltv3,
        ROUND(SUM(rev_ltv7) * 1.0 / NULLIF(SUM(ltv_cohort_size), 0), 4)       AS ltv7
    FROM CohortAgg
    GROUP BY region, launch_day
)

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. 最终输出
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    ds.region                   AS "大区",
    ds.launch_day               AS "开服日",
    ds.stat_start               AS "统计开始日",
    ds.stat_end                 AS "统计结束日",
    ds.total_revenue            AS "前30日累计收入(RMB)",
    ds.total_nuu                AS "前30日累计NUU",
    ds.avg_dau                  AS "日均DAU",
    ds.weighted_pay_rate        AS "加权平均付费率",
    ds.weighted_arpu            AS "加权平均ARPU",
    ds.weighted_arppu           AS "加权平均ARPPU",
    -- 留存（次留=D2，3留=D3，以此类推）
    cs.rr_d2                    AS "次留(D2)",
    cs.rr_d3                    AS "3留(D3)",
    cs.rr_d4                    AS "4留(D4)",
    cs.rr_d6                    AS "6留(D6)",
    cs.rr_d7                    AS "7留(D7)",
    cs.rr_d8                    AS "8留(D8)",
    -- LTV（前7日注册用户的加权均值）
    cs.ltv1                     AS "加权LTV1",
    cs.ltv3                     AS "加权LTV3",
    cs.ltv7                     AS "加权LTV7"
FROM DailySummary ds
LEFT JOIN CohortSummary cs
    ON ds.region = cs.region
   AND ds.launch_day = cs.launch_day
ORDER BY ds.launch_day ASC;
