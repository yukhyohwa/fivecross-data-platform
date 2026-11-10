/*
小新繁体 App18 OBT：固定分R用户群的充值概览。

数数参数（在看板中分别配置）：
  ${PartDate:date1} = 分R定档充值日期范围。
  ${PartDate:date2} = 付费统计日期范围。
  ${Selector:timetype} = 统计维度：日 D、周 W、月 M、合并 A。
  下拉选项展示中文名称、实际值为 D/W/M/A；宏保持平台原有字符串表达式用法，不另加引号。

口径：
1. date1 内同一 fc_id 的累计有效充值 USD 决定固定档位，不按 date2 的日/周/月重新定档。
2. date2 只统计在 date1 内已完成有效付费定档的账号；仅在 date2 付费的新账号不纳入。
3. 直接使用事件 fc_id，不关联 new_role，不反推日期参数边界。仅额外限定 OBT 起点2026-10-14。
4. 保留原六档，下限包含、上限不包含；累计额必须>0。排除内部/水量/Windows。
5. 排除 sandbox、is_freebuy、COIN；USD = pay_amount / 当日币种汇率，不二次换算。
6. 汇率同日同币种先去重；缺失、非正数、冲突或金额无法转换的订单收入留空。
   定档期任一订单异常的账号整体不定档；其异常订单总数在最后一列重复展示，不能跨行相加。
   统计期异常订单不计充值金额和有效充值人数，在各时间/档位的异常订单数中展示。
7. 周按周一，月按每月1号；统计期只计算date2内订单，不为凑满自然周/月读取范围外数据。
8. 每个有充值事件的统计时间段显示六档，空档为0；不补无事件日期，不生成日历。
   合并维度用“合并”标签；无date2订单则不返回行。人数按当前时间段内有效正额订单fc_id去重。
9. 占比分母为同时间段已定档群体的金额/人数；同账号可跨多日付费，日人数不可相加当作全期去重人数。
*/
WITH
TierConfig (tier_order, tier_name, min_usd, max_usd) AS (
    VALUES
        (1, '微R', CAST(0 AS DOUBLE), CAST(3 AS DOUBLE)),
        (2, '小R', CAST(3 AS DOUBLE), CAST(20 AS DOUBLE)),
        (3, '中R', CAST(20 AS DOUBLE), CAST(50 AS DOUBLE)),
        (4, '大R', CAST(50 AS DOUBLE), CAST(200 AS DOUBLE)),
        (5, '巨R', CAST(200 AS DOUBLE), CAST(500 AS DOUBLE)),
        (6, '超R', CAST(500 AS DOUBLE), CAST(NULL AS DOUBLE))
),
AccountBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
ExchangeRates AS (
    SELECT
        CAST(ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
        CASE
            WHEN COUNT_IF(TRY_CAST(exchange AS DOUBLE) IS NULL OR TRY_CAST(exchange AS DOUBLE) <= 0) = 0
             AND MIN(TRY_CAST(exchange AS DOUBLE)) = MAX(TRY_CAST(exchange AS DOUBLE))
            THEN MAX(TRY_CAST(exchange AS DOUBLE))
        END AS exchange
    FROM ta_dim.ta_exchange
    GROUP BY 1, 2
),
-- 第一个时间筛选只决定档位。
TierChargeRows AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(x.exchange, 0) AS revenue_usd,
        CASE WHEN TRY_CAST(v.pay_amount AS DOUBLE) IS NULL OR x.exchange IS NULL
             THEN 1 ELSE 0 END AS invalid_revenue_count
    FROM ta.v_event_18 v
    LEFT JOIN AccountBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ExchangeRates x ON v."$part_date" = x.ex_date
      AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = x.currency
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'charge'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
),
UserTierRevenue AS (
    SELECT fc_id,
           SUM(revenue_usd) AS revenue_usd,
           SUM(invalid_revenue_count) AS invalid_revenue_count
    FROM TierChargeRows
    GROUP BY 1
),
TieredUsers AS (
    SELECT t.tier_order, u.fc_id
    FROM UserTierRevenue u
    INNER JOIN TierConfig t ON u.revenue_usd >= t.min_usd
      AND (t.max_usd IS NULL OR u.revenue_usd < t.max_usd)
    WHERE u.invalid_revenue_count = 0
      AND u.revenue_usd > 0
),
-- 第二个时间筛选只决定统计的订单；不影响上面的固定档位。
StatChargeRows AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(CAST(v."$part_date" AS DATE) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '合并'
        END AS time_dimension,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(x.exchange, 0) AS revenue_usd,
        CASE WHEN TRY_CAST(v.pay_amount AS DOUBLE) IS NULL OR x.exchange IS NULL
             THEN 1 ELSE 0 END AS invalid_revenue_count
    FROM ta.v_event_18 v
    LEFT JOIN AccountBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ExchangeRates x ON v."$part_date" = x.ex_date
      AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = x.currency
    WHERE v.${PartDate:date2}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'charge'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
),
StatPeriods AS (
    SELECT DISTINCT time_dimension
    FROM StatChargeRows
    WHERE time_dimension IS NOT NULL
),
TierSummary AS (
    SELECT
        s.time_dimension,
        u.tier_order,
        SUM(s.revenue_usd) AS revenue_usd,
        COUNT(DISTINCT CASE WHEN s.revenue_usd > 0 THEN s.fc_id END) AS payer_count,
        SUM(s.invalid_revenue_count) AS invalid_revenue_count
    FROM StatChargeRows s
    INNER JOIN TieredUsers u ON s.fc_id = u.fc_id
    GROUP BY 1, 2
),
PeriodTotals AS (
    SELECT time_dimension,
           SUM(revenue_usd) AS revenue_usd,
           SUM(payer_count) AS payer_count
    FROM TierSummary
    GROUP BY 1
),
TierDataQuality AS (
    SELECT COALESCE(SUM(invalid_revenue_count), 0) AS invalid_revenue_count
    FROM TierChargeRows
)
SELECT
    p.time_dimension AS "时间维度",
    t.tier_name AS "分R区间",
    CASE
        WHEN t.max_usd IS NULL THEN CONCAT('>= $', CAST(t.min_usd AS VARCHAR))
        ELSE CONCAT('$', CAST(t.min_usd AS VARCHAR), ' ~ < $', CAST(t.max_usd AS VARCHAR))
    END AS "区间定义",
    ROUND(COALESCE(s.revenue_usd, 0), 2) AS "充值额USD",
    COALESCE(s.payer_count, 0) AS "充值人数",
    ROUND(COALESCE(s.revenue_usd, 0) * 100.0 / NULLIF(a.revenue_usd, 0), 2) AS "充值额占比%",
    ROUND(COALESCE(s.payer_count, 0) * 100.0 / NULLIF(a.payer_count, 0), 2) AS "充值人数占比%",
    ROUND(COALESCE(s.revenue_usd, 0) / NULLIF(s.payer_count, 0), 2) AS "ARPPU_USD",
    COALESCE(s.invalid_revenue_count, 0) AS "异常汇率订单数",
    q.invalid_revenue_count AS "定档区间异常订单数"
FROM StatPeriods p
CROSS JOIN TierConfig t
LEFT JOIN TierSummary s ON p.time_dimension = s.time_dimension AND t.tier_order = s.tier_order
LEFT JOIN PeriodTotals a ON p.time_dimension = a.time_dimension
CROSS JOIN TierDataQuality q
ORDER BY p.time_dimension DESC, t.tier_order;
