-- ================================================================================
-- 游戏: 灌篮高手 繁体 (Slam Dunk TC, app_id=23002013)
-- 描述: 单日 KPI 对比 — 2023-05-25 vs 2026-04-23
-- 指标:
--   全体用户: AU、付费金额(RMB)、付费率、DARPU、DARPPU
--   新用户:   NUU、付费金额(RMB)、付费率、DARPU、DARPPU
-- 引擎: MaxCompute (ODPS)
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

SELECT
    day                                                                         AS "日期",

    -- ── 全体用户 ──────────────────────────────────────────────────────────────
    COUNT(DISTINCT lcm_id)                                                      AS "AU",
    COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END)                     AS "付费人数",
    ROUND(SUM(purchase), 2)                                                     AS "付费金额(RMB)",
    ROUND(
        COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END) * 1.0
        / NULLIF(COUNT(DISTINCT lcm_id), 0)
    , 4)                                                                        AS "付费率",
    -- DARPU = 付费金额 / AU
    ROUND(
        SUM(purchase) * 1.0
        / NULLIF(COUNT(DISTINCT lcm_id), 0)
    , 4)                                                                        AS "DARPU",
    -- DARPPU = 付费金额 / 付费人数
    ROUND(
        SUM(purchase) * 1.0
        / NULLIF(COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END), 0)
    , 4)                                                                        AS "DARPPU",

    -- ── 新用户 ────────────────────────────────────────────────────────────────
    COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day THEN lcm_id END)    AS "NUU",
    COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day AND purchase > 0
                        THEN lcm_id END)                                        AS "新用户付费人数",
    ROUND(SUM(CASE WHEN CAST(reg_day AS BIGINT) = day THEN purchase ELSE 0 END), 2)
                                                                                AS "新用户付费金额(RMB)",
    ROUND(
        COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day AND purchase > 0
                            THEN lcm_id END) * 1.0
        / NULLIF(COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day
                                     THEN lcm_id END), 0)
    , 4)                                                                        AS "新用户付费率",
    -- 新用户 DARPU = 新用户付费金额 / NUU
    ROUND(
        SUM(CASE WHEN CAST(reg_day AS BIGINT) = day THEN purchase ELSE 0 END) * 1.0
        / NULLIF(COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day
                                     THEN lcm_id END), 0)
    , 4)                                                                        AS "新用户DARPU",
    -- 新用户 DARPPU = 新用户付费金额 / 新用户付费人数
    ROUND(
        SUM(CASE WHEN CAST(reg_day AS BIGINT) = day THEN purchase ELSE 0 END) * 1.0
        / NULLIF(COUNT(DISTINCT CASE WHEN CAST(reg_day AS BIGINT) = day AND purchase > 0
                                     THEN lcm_id END), 0)
    , 4)                                                                        AS "新用户DARPPU"

FROM dm_platform.daily_lcx_user_info
WHERE app_id = 23002013
  AND day IN (20230525, 20260423)
  AND is_water = '不是水'
GROUP BY day
ORDER BY day ASC;
