/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 首充转化商品分布
描述：统计账号历史上第一笔有效订单购买的礼包分布，用于分析首充商品转化。
维度：时间周期、商品名称、商品分类、首充人数、首充收入

口径：
1. OBT 从 2026-10-14 开始；账号使用 fc_id，同账号多角色合并。
2. 先确定账号首次 OBT 创角，再寻找创角后的第一笔有效 charge。
3. 有效充值排除 sandbox、is_freebuy。
4. 充值黑名单为 is_water_new、is_windows_new，使用 #varchar_id 关联 fc_id。
5. ${PartDate:date1} 筛选的是首充发生日期。
6. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

ScanConfig AS (
    SELECT
        MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
        MAX(CAST(v."$part_date" AS DATE)) AS target_end_date,
        MAX(c.obt_start_date) AS obt_start_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'charge'
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定每个 fc_id 的首次创角
--------------------------------------------------------------------------------
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

EligibleAccounts AS (
    SELECT r.fc_id, r.reg_date, r.reg_event_time
    FROM AccountRegistrationRanked r
    LEFT JOIN UserBlacklist b ON r.fc_id = b.fc_id
    WHERE r.rn = 1
      AND b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- 汇率按日期和币种压成一行，避免维表重复导致订单被放大
--------------------------------------------------------------------------------
ExchangeRates AS (
    SELECT
        CAST(ex.ex_date AS VARCHAR) AS ex_date,
        UPPER(TRIM(CAST(ex.currency AS VARCHAR))) AS currency,
        MAX(TRY_CAST(ex.exchange AS DOUBLE)) AS exchange
    FROM ta_dim.ta_exchange ex
    CROSS JOIN ScanConfig sc
    WHERE CAST(ex.ex_date AS DATE) BETWEEN sc.obt_start_date AND sc.target_end_date
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 扫描 OBT 开服至报表结束日的有效充值，再按 fc_id 排出真正首笔订单
--------------------------------------------------------------------------------
AllUserFirstChargeRanked AS (
    SELECT
        p.fc_id,
        v.product_id,
        TRY_CAST(v.pay_amount AS DOUBLE) AS pay_amount,
        UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) AS pay_currency,
        v."$part_date",
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        TRY_CAST(v.role_lev AS DOUBLE) AS role_lev,
        ROW_NUMBER() OVER (
            PARTITION BY p.fc_id
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v.product_id AS VARCHAR) ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS charge_rank
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'charge'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
),

TargetFirstCharge AS (
    SELECT
        fc.fc_id,
        fc.product_id,
        fc.pay_amount / COALESCE(ex.exchange, 1.0) AS pay_amount_usd,
        fc."$part_date",
        fc.event_time,
        fc.role_lev
    FROM AllUserFirstChargeRanked fc
    CROSS JOIN ScanConfig sc
    LEFT JOIN ExchangeRates ex
        ON fc."$part_date" = ex.ex_date
       AND fc.pay_currency = ex.currency
    WHERE fc.charge_rank = 1
      AND CAST(fc."$part_date" AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
)

SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(t."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(t."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(t."$part_date" AS DATE)) AS VARCHAR)
        ELSE '已合并'
    END AS "时间维度",
    dp."product_id@product_name_tc" AS "商品名称",
    dp."product_id@product_type" AS "商品类型",
    t.product_id AS "商品ID",
    COUNT(DISTINCT t.fc_id) AS "首充人数",
    SUM(t.pay_amount_usd) AS "首充总收入(USD)",
    SUM(t.pay_amount_usd) / NULLIF(COUNT(DISTINCT t.fc_id), 0) AS "首充客单价",
    AVG(t.role_lev) AS "平均等级",
    APPROX_PERCENTILE(t.role_lev, 0.5) AS "等级中位数"
FROM TargetFirstCharge t
LEFT JOIN ta_dim.dim_18_0_52801 dp
    ON CAST(t.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER)
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 5 DESC;
