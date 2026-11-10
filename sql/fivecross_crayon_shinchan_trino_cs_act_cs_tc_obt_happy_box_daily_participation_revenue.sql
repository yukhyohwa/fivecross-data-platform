WITH
-- 基础黑名单
UserBlacklist AS (
    SELECT DISTINCT
        TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN (
        'is_water_new',
        'is_windows_new'
    )
),

-- 晶钻购买额外排除内部用户
InternalUsers AS (
    SELECT DISTINCT
        TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name = 'internal_users_new'
),

-- 礼包维表：每个商品 ID 只保留一行
GiftProducts AS (
    SELECT DISTINCT
        TRY_CAST("product_id@product_id" AS BIGINT) AS product_id
    FROM ta_dim.dim_18_0_52801
    WHERE "product_id@product_name_tc" LIKE '%開心禮盒機%'
       OR "product_id@product_name_tc" LIKE '%开心礼盒机%'
       OR "product_id@product_name_tc" LIKE '%幸運許願池%'
       OR "product_id@product_name_tc" LIKE '%幸运许愿池%'
),

-- 汇率按日期、币种去重
ExchangeRates AS (
    SELECT
        CAST(ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
        CASE
            WHEN MIN(TRY_CAST(exchange AS DOUBLE)) > 0
             AND MIN(TRY_CAST(exchange AS DOUBLE))
                 = MAX(TRY_CAST(exchange AS DOUBLE))
             AND COUNT(*) = COUNT(TRY_CAST(exchange AS DOUBLE))
            THEN MAX(TRY_CAST(exchange AS DOUBLE))
        END AS exchange
    FROM ta_dim.ta_exchange
    GROUP BY 1, 2
),

-- 每日活跃账号
DailyAU AS (
    SELECT
        v."$part_date" AS dt,
        COUNT(
            DISTINCT TRIM(CAST(v.fc_id AS VARCHAR))
        ) AS active_users
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'login'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),

-- 每条道具变动中的实际消耗量
ConsumeEvents AS (
    SELECT
        v."$part_date" AS dt,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        REDUCE(
            v.a_rst,
            CAST(0 AS BIGINT),
            (s, x) -> s + CASE
                WHEN TRY_CAST(x.id AS BIGINT) = 10268
                 AND TRY_CAST(x.before AS BIGINT)
                     > TRY_CAST(x.after AS BIGINT)
                THEN CAST(x.before AS BIGINT)
                     - CAST(x.after AS BIGINT)
                ELSE 0
            END,
            s -> s
        ) AS consume_amount
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'item_change'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),

-- 每日消耗人数、消耗总数
ConsumeLogs AS (
    SELECT
        dt,
        COUNT(DISTINCT fc_id) AS consume_users,
        SUM(consume_amount) AS total_consume
    FROM ConsumeEvents
    WHERE consume_amount > 0
    GROUP BY 1
),

-- 每日礼包现金收入
GiftRevenue AS (
    SELECT
        v."$part_date" AS dt,
        CASE
            WHEN COUNT_IF(x.exchange IS NULL) > 0
                THEN CAST(NULL AS DOUBLE)
            ELSE SUM(
                TRY_CAST(v.pay_amount AS DOUBLE)
                / NULLIF(x.exchange, 0)
            )
        END AS gift_revenue_usd,
        COUNT_IF(x.exchange IS NULL) AS missing_fx_orders
    FROM ta.v_event_18 v
    INNER JOIN GiftProducts p
        ON TRY_CAST(v.product_id AS BIGINT) = p.product_id
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ExchangeRates x
        ON v."$part_date" = x.ex_date
       AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = x.currency
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'charge'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(
            UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))),
            ''
          ) <> 'COIN'
      AND TRY_CAST(v.pay_amount AS DOUBLE) > 0
    GROUP BY 1
),

-- 每日晶钻购买礼包
GiftGems AS (
    SELECT
        v."$part_date" AS dt,
        COUNT(
            DISTINCT TRIM(CAST(v.fc_id AS VARCHAR))
        ) AS gems_users,
        COUNT(*) AS gems_buy_count,
        SUM(
            TRY_CAST(v.shop_item[1].num AS DOUBLE)
        ) / 100.0 AS gems_amount
    FROM ta.v_event_18 v
    INNER JOIN GiftProducts p
        ON TRY_CAST(v.shop_item[1].shop_id AS BIGINT) = p.product_id
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN InternalUsers i
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = i.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'shop_buy'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND i.fc_id IS NULL
      AND TRY_CAST(v.shop_item[1].item_id AS BIGINT) = 10206
      AND TRY_CAST(v.shop_item[1].num AS DOUBLE) > 0
    GROUP BY 1
)

-- 各每日聚合只引用一次，避免 AllDates 再引用相同查询
SELECT
    COALESCE(a.dt, c.dt, g.dt, j.dt) AS "日期",
    COALESCE(c.consume_users, 0) AS "参与人数(消耗人数)",
    COALESCE(c.total_consume, 0) AS "抽奖币消耗总数",
    COALESCE(a.active_users, 0) AS "全服活跃人数(AU)",
    ROUND(
        CAST(COALESCE(c.consume_users, 0) AS DOUBLE)
        / NULLIF(a.active_users, 0),
        4
    ) AS "参与渗透率",
    ROUND(
        CAST(COALESCE(c.total_consume, 0) AS DOUBLE)
        / NULLIF(c.consume_users, 0),
        2
    ) AS "人均消耗数",
    CASE
        WHEN g.dt IS NULL THEN 0.0
        ELSE ROUND(g.gift_revenue_usd, 2)
    END AS "礼包当日收入(USD)",
    COALESCE(j.gems_users, 0) AS "礼包晶钻购买人数",
    COALESCE(j.gems_buy_count, 0) AS "礼包晶钻购买笔数",
    ROUND(
        COALESCE(j.gems_amount, 0),
        2
    ) AS "礼包消耗晶钻总数",
    COALESCE(g.missing_fx_orders, 0) AS "礼包汇率异常订单数"
FROM DailyAU a
FULL OUTER JOIN ConsumeLogs c
    ON a.dt = c.dt
FULL OUTER JOIN GiftRevenue g
    ON COALESCE(a.dt, c.dt) = g.dt
FULL OUTER JOIN GiftGems j
    ON COALESCE(a.dt, c.dt, g.dt) = j.dt
ORDER BY 1 DESC;