-- ================================================================================
-- Report  : Slam Dunk TC — VIP KPI Comparison
-- Game    : Slam Dunk TC (app_id=23002013)
-- Dates   : 2023-05-25  vs  2026-04-23
-- Metrics : Per VIP tier — AU, payer count, pay rate, revenue(CNY), ARPU, ARPPU
-- Engine  : MaxCompute (ODPS)
-- ================================================================================

WITH

UserVip AS (
    SELECT
        u.day,
        u.lcm_id,
        CASE
            WHEN s.total_pay_max = 0                        THEN 'V0'
            WHEN s.total_pay_max BETWEEN 1     AND 6        THEN 'V1'
            WHEN s.total_pay_max BETWEEN 7     AND 30       THEN 'V2'
            WHEN s.total_pay_max BETWEEN 31    AND 100      THEN 'V3'
            WHEN s.total_pay_max BETWEEN 101   AND 500      THEN 'V4'
            WHEN s.total_pay_max BETWEEN 501   AND 1000     THEN 'V5'
            WHEN s.total_pay_max BETWEEN 1001  AND 3000     THEN 'V6'
            WHEN s.total_pay_max BETWEEN 3001  AND 10000    THEN 'V7'
            WHEN s.total_pay_max BETWEEN 10001 AND 30000    THEN 'V8'
            WHEN s.total_pay_max >= 30001                   THEN 'V9'
            ELSE 'V0'
        END                                                             AS vip,
        COALESCE(u.purchase, 0)                                         AS purchase
    FROM dm_platform.daily_lcx_user_info u
    LEFT JOIN (
        -- 核心优化：确保每天每个用户只有一条最高付费记录，防止 AU 和 Revenue 翻倍
        SELECT day, mbga_uid, MAX(CAST(total_pay AS DOUBLE)) as total_pay_max
        FROM g23002013.daily_user_snapshot
        WHERE day IN (20230525, 20260423)
        GROUP BY day, mbga_uid
    ) s ON u.lcm_id = s.mbga_uid AND u.day = s.day
    WHERE u.app_id    = 23002013
      AND u.day       IN (20230525, 20260423)
      AND u.is_water  = '不是水'
),

VipAgg AS (
    SELECT
        day,
        vip,
        COUNT(DISTINCT lcm_id)                                                  AS au,
        COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END)                  AS payer_cnt,
        ROUND(SUM(purchase), 2)                                                 AS revenue_cny,
        ROUND(
            COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END) * 100.0
            / NULLIF(COUNT(DISTINCT lcm_id), 0)
        , 2)                                                                    AS pay_rate,
        ROUND(SUM(purchase) / NULLIF(COUNT(DISTINCT lcm_id), 0), 4)            AS arpu,
        ROUND(
            SUM(purchase)
            / NULLIF(COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END), 0)
        , 4)                                                                    AS arppu
    FROM UserVip
    GROUP BY day, vip
),

Joined AS (
    SELECT
        COALESCE(a.vip, b.vip)                                                  AS vip,

        a.au                                                                    AS au_2023,
        a.payer_cnt                                                             AS payer_2023,
        a.pay_rate                                                              AS pay_rate_2023,
        a.revenue_cny                                                           AS rev_2023,
        a.arpu                                                                  AS arpu_2023,
        a.arppu                                                                 AS arppu_2023,

        b.au                                                                    AS au_2026,
        b.payer_cnt                                                             AS payer_2026,
        b.pay_rate                                                              AS pay_rate_2026,
        b.revenue_cny                                                           AS rev_2026,
        b.arpu                                                                  AS arpu_2026,
        b.arppu                                                                 AS arppu_2026
    FROM
        (SELECT * FROM VipAgg WHERE day = 20230525) a
    FULL OUTER JOIN
        (SELECT * FROM VipAgg WHERE day = 20260423) b
        ON a.vip = b.vip
)

SELECT
    vip                                                                         AS "VIP等级",

    au_2023                                                                     AS "活跃人数(2023-05-25)",
    payer_2023                                                                  AS "付费人数(2023-05-25)",
    CONCAT(CAST(pay_rate_2023 AS STRING), '%')                                  AS "付费率(2023-05-25)",
    rev_2023                                                                    AS "付费金额CNY(2023-05-25)",
    arpu_2023                                                                   AS "ARPU(2023-05-25)",
    arppu_2023                                                                  AS "ARPPU(2023-05-25)",

    au_2026                                                                     AS "活跃人数(2026-04-23)",
    payer_2026                                                                  AS "付费人数(2026-04-23)",
    CONCAT(CAST(pay_rate_2026 AS STRING), '%')                                  AS "付费率(2026-04-23)",
    rev_2026                                                                    AS "付费金额CNY(2026-04-23)",
    arpu_2026                                                                   AS "ARPU(2026-04-23)",
    arppu_2026                                                                  AS "ARPPU(2026-04-23)"

FROM Joined
ORDER BY CAST(REPLACE(vip, 'V', '') AS INT) ASC;
