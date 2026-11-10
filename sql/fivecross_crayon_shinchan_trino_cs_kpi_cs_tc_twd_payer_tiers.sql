/*
小新台湾 CBT：按用户累计有效充值（折算 TWD）分层
统计周期：2026-07-29 ~ 2026-08-04（含首尾）

口径：
- 仅 charge；排除 sandbox、is_freebuy，以及 internal_users / is_windows / is_water 黑名单
- 用交易币种当天汇率先折算 USD，再用当天 TWD 汇率折算台币：
  pay_amount / source_exchange * twd_exchange
- 小R：<= 33；中R：> 33 且 <= 500；大R：> 500 且 <= 2000；超R：> 2000
*/
WITH Blacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),
UserRevenue AS (
    SELECT
        CAST(e."#account_id" AS VARCHAR) AS account_id,
        SUM(
            TRY_CAST(e.pay_amount AS DOUBLE)
            / NULLIF(source_exchange.exchange, 0)
            * twd_exchange.exchange
        ) AS total_revenue_twd
    FROM ta.v_event_18 e
    LEFT JOIN Blacklist b
        ON e."#user_id" = b.user_id
    LEFT JOIN ta_dim.ta_exchange source_exchange
        ON e."$part_date" = source_exchange.ex_date
       AND e.pay_currency = source_exchange.currency
    LEFT JOIN ta_dim.ta_exchange twd_exchange
        ON e."$part_date" = twd_exchange.ex_date
       AND twd_exchange.currency = 'TWD'
    WHERE e."$part_event" = 'charge'
      AND CAST(e."$part_date" AS DATE) BETWEEN DATE '2026-07-29' AND DATE '2026-08-04'
      AND e."#account_id" IS NOT NULL
      AND b.user_id IS NULL
      AND CAST(e."#account_id" AS VARCHAR) NOT IN ('4100002', '91110', '91111')
      AND (e.sandbox IS NULL OR e.sandbox = FALSE)
      AND (e.is_freebuy IS NULL OR e.is_freebuy = FALSE)
      AND source_exchange.exchange IS NOT NULL
      AND twd_exchange.exchange IS NOT NULL
    GROUP BY 1
),
TieredRevenue AS (
    SELECT
        account_id,
        total_revenue_twd,
        CASE
            WHEN total_revenue_twd <= 33 THEN '小R（≤33）'
            WHEN total_revenue_twd <= 500 THEN '中R（>33–500）'
            WHEN total_revenue_twd <= 2000 THEN '大R（>500–2000）'
            ELSE '超R（>2000）'
        END AS payer_tier
    FROM UserRevenue
)
SELECT
    payer_tier AS "付费档位",
    COUNT(*) AS "人数",
    ROUND(SUM(total_revenue_twd), 2) AS "流水TWD",
    ROUND(
        100.0 * SUM(total_revenue_twd)
        / SUM(SUM(total_revenue_twd)) OVER (),
        2
    ) AS "流水占比(%)"
FROM TieredRevenue
GROUP BY 1
ORDER BY CASE payer_tier
    WHEN '小R（≤33）' THEN 1
    WHEN '中R（>33–500）' THEN 2
    WHEN '大R（>500–2000）' THEN 3
    ELSE 4
END;
