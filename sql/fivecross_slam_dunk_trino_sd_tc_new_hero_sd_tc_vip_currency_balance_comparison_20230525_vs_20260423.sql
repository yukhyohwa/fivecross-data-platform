-- ================================================================================
-- Report  : Slam Dunk TC — VIP Currency Balance Comparison
-- Game    : Slam Dunk TC (g23002013)
-- Dates   : 2023-05-25  vs  2026-04-23
-- Metrics : Per VIP tier — user count, avg/total paid stamps, free stamps, diamonds
-- Engine  : MaxCompute (ODPS)
-- Notes   :
--   Currency obj keys confirmed from codebase:
--     dmp:stamps      = paid stamps  (付费点券)
--     dmp:freestamps  = free stamps  (免费点券)
--     dmp:money       = diamonds     (钻石)
--   Balance = last "after" value recorded on that day per user per currency
--   VIP tier derived from total_pay (cumulative RMB) in daily_user_snapshot
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

WITH

-- ────────────────────────────────────────────────────────────────────────────
-- Step 1: Active users on each target date (AU) + VIP tier
--         Active = appeared in daily_lcx_user_info on that day
--         VIP tier from daily_user_snapshot (same day)
-- ────────────────────────────────────────────────────────────────────────────
ActiveUsers AS (
    SELECT
        CAST(day AS BIGINT)                                             AS day,
        lcm_id
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 23002013
      AND day IN (20230525, 20260423)
      AND is_water = '不是水'
),

UserVip AS (
    SELECT
        day,
        lcm_id,
        user_id,
        CASE
            WHEN total_pay_max = 0                        THEN 'V0'
            WHEN total_pay_max BETWEEN 1     AND 6        THEN 'V1'
            WHEN total_pay_max BETWEEN 7     AND 30       THEN 'V2'
            WHEN total_pay_max BETWEEN 31    AND 100      THEN 'V3'
            WHEN total_pay_max BETWEEN 101   AND 500      THEN 'V4'
            WHEN total_pay_max BETWEEN 501   AND 1000     THEN 'V5'
            WHEN total_pay_max BETWEEN 1001  AND 3000     THEN 'V6'
            WHEN total_pay_max BETWEEN 3001  AND 10000    THEN 'V7'
            WHEN total_pay_max BETWEEN 10001 AND 30000    THEN 'V8'
            WHEN total_pay_max >= 30001                   THEN 'V9'
            ELSE 'V0'
        END                                                             AS vip
    FROM (
        -- 核心优化：确保每个用户每天只有一条最高付费记录，防止 AU 和存量翻倍
        SELECT 
            s.day, 
            s.mbga_uid as lcm_id, 
            MAX(s.user_id) as user_id, 
            MAX(CAST(s.total_pay AS DOUBLE)) as total_pay_max
        FROM g23002013.daily_user_snapshot s
        INNER JOIN ActiveUsers a ON s.day = a.day AND s.mbga_uid = a.lcm_id
        GROUP BY s.day, s.mbga_uid
    ) t
),

-- ────────────────────────────────────────────────────────────────────────────
-- Step 2: Currency balance — last "after" value per user per currency per day
--         a_rst fields: obj, diff, before, after
-- ────────────────────────────────────────────────────────────────────────────
CurrencyRaw AS (
    SELECT
        day,
        user_id,
        obj,
        CAST(after_val AS BIGINT)                                       AS balance,
        ROW_NUMBER() OVER (
            PARTITION BY day, user_id, obj
            ORDER BY CAST(log_t AS BIGINT) ASC
        )                                                               AS rn
    FROM g23002013.daily_game_log
    LATERAL VIEW EXPLODE(a_rst) t AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'after') j AS obj, after_val
    WHERE day IN (20230525, 20260423)
      AND obj IN ('dmp:stamps', 'dmp:freestamps', 'dmp:money')
),

-- Keep only the last entry per user / currency / day
CurrencyBalance AS (
    SELECT
        day,
        user_id,
        MAX(CASE WHEN obj = 'dmp:stamps'     THEN balance END)         AS stamps,
        MAX(CASE WHEN obj = 'dmp:freestamps' THEN balance END)         AS free_stamps,
        MAX(CASE WHEN obj = 'dmp:money'      THEN balance END)         AS diamond
    FROM CurrencyRaw
    WHERE rn = 1
    GROUP BY day, user_id
),

-- ────────────────────────────────────────────────────────────────────────────
-- Step 3: Join VIP (active users only) + currency balance
-- ────────────────────────────────────────────────────────────────────────────
Combined AS (
    SELECT
        v.day,
        v.vip,
        COALESCE(c.stamps,      0)                                      AS stamps,
        COALESCE(c.free_stamps, 0)                                      AS free_stamps,
        COALESCE(c.diamond,     0)                                      AS diamond
    FROM UserVip v
    LEFT JOIN CurrencyBalance c
        ON v.day = c.day AND v.user_id = c.user_id
)
-- Note: UserVip is already filtered to active users (INNER JOIN with ActiveUsers)

-- ────────────────────────────────────────────────────────────────────────────
-- Final: Aggregate by date + VIP tier
-- ────────────────────────────────────────────────────────────────────────────
SELECT
    day                                                                 AS "日期",
    vip                                                                 AS "VIP等级",
    COUNT(*)                                                            AS "用户数",

    -- 付费点券 (dmp:stamps)
    SUM(stamps)                                                         AS "点券总存量",
    ROUND(AVG(stamps), 2)                                               AS "人均点券",
    MAX(stamps)                                                         AS "点券最大值",
    PERCENTILE_APPROX(stamps, 0.5)                                      AS "点券中位数",

    -- 免费点券 (dmp:freestamps)
    SUM(free_stamps)                                                    AS "免费点券总存量",
    ROUND(AVG(free_stamps), 2)                                          AS "人均免费点券",
    MAX(free_stamps)                                                    AS "免费点券最大值",
    PERCENTILE_APPROX(free_stamps, 0.5)                                 AS "免费点券中位数",

    -- 点券合计 (付费 + 免费)
    SUM(stamps + free_stamps)                                           AS "点券合计总存量",
    ROUND(AVG(stamps + free_stamps), 2)                                 AS "人均点券合计",

    -- 钻石 (dmp:money)
    SUM(diamond)                                                        AS "钻石总存量",
    ROUND(AVG(diamond), 2)                                              AS "人均钻石",
    MAX(diamond)                                                        AS "钻石最大值",
    PERCENTILE_APPROX(diamond, 0.5)                                     AS "钻石中位数"

FROM Combined
GROUP BY day, vip
ORDER BY
    day ASC,
    CAST(REPLACE(vip, 'V', '') AS INT) ASC;
