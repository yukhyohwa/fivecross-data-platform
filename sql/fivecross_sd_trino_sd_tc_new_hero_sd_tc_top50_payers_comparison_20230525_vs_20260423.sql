-- ================================================================================
-- Report  : Slam Dunk TC — Top 50 Payers Comparison
-- Game    : Slam Dunk TC (app_id=23002013)
-- Dates   : 2023-05-25  vs  2026-04-23
-- Metrics : Rank, LCM ID, Pay Count, Revenue(CNY), Is New User,
--           2023-05-25 Top50 users active on 2026-04-23
-- Engine  : MaxCompute (ODPS)
-- ================================================================================

WITH

ExRate AS (
    SELECT
        SUBSTR(day_hour, 1, 6)  AS month,
        trans_from,
        exchange_rate,
        ROW_NUMBER() OVER (
            PARTITION BY trans_from, SUBSTR(day_hour, 1, 6)
            ORDER BY day_hour
        )                       AS rk
    FROM dm_platform.itunes_exchange_rate_fmp
    WHERE trans_to = 'cny'
      AND day >= 20230101
),

PurchaseRaw AS (
    SELECT
        p.day,
        p.lcm_id,
        e.exchange_rate * p.price_show                                  AS sales_cny
    FROM dm_platform.daily_lcx_user_purchase p
    LEFT JOIN ExRate e
        ON SUBSTR(p.day, 1, 6) = e.month
       AND UPPER(p.unit_show)  = e.trans_from
       AND e.rk = 1
    WHERE p.app_id    = 23002013
      AND p.day       IN (20230525, 20260423)
      AND p.price_show > 0
),

NewUsers AS (
    SELECT DISTINCT
        day,
        lcm_id
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 23002013
      AND day    IN (20230525, 20260423)
      AND CAST(reg_day AS BIGINT) = CAST(day AS BIGINT)
),

UserPaySummary AS (
    SELECT
        p.day,
        p.lcm_id,
        COUNT(*)                                                        AS pay_count,
        ROUND(SUM(p.sales_cny), 2)                                      AS revenue_cny,
        CASE WHEN n.lcm_id IS NOT NULL THEN '是' ELSE '否' END          AS is_new_user
    FROM PurchaseRaw p
    LEFT JOIN NewUsers n
        ON p.day = n.day AND p.lcm_id = n.lcm_id
    GROUP BY p.day, p.lcm_id, CASE WHEN n.lcm_id IS NOT NULL THEN '是' ELSE '否' END
),

Ranked AS (
    SELECT
        day,
        lcm_id,
        pay_count,
        revenue_cny,
        is_new_user,
        ROW_NUMBER() OVER (PARTITION BY day ORDER BY revenue_cny DESC)  AS rank
    FROM UserPaySummary
),

-- 2023-05-25 Top50 用户在 2026-04-23 是否活跃
ActiveOn20260423 AS (
    SELECT DISTINCT lcm_id
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 23002013
      AND day    = 20260423
)

SELECT
    COALESCE(a.rank, b.rank)                                            AS "排名",

    a.lcm_id                                                            AS "账号(2023-05-25)",
    a.pay_count                                                         AS "付费次数(2023-05-25)",
    a.revenue_cny                                                       AS "付费金额CNY(2023-05-25)",
    a.is_new_user                                                       AS "是否新用户(2023-05-25)",
    CASE WHEN ac.lcm_id IS NOT NULL THEN '是' ELSE '否' END             AS "4月23日是否活跃",

    b.lcm_id                                                            AS "账号(2026-04-23)",
    b.pay_count                                                         AS "付费次数(2026-04-23)",
    b.revenue_cny                                                       AS "付费金额CNY(2026-04-23)",
    b.is_new_user                                                       AS "是否新用户(2026-04-23)"

FROM
    (SELECT * FROM Ranked WHERE day = 20230525 AND rank <= 50) a
FULL OUTER JOIN
    (SELECT * FROM Ranked WHERE day = 20260423 AND rank <= 50) b
    ON a.rank = b.rank
LEFT JOIN ActiveOn20260423 ac
    ON a.lcm_id = ac.lcm_id

ORDER BY COALESCE(a.rank, b.rank) ASC;
