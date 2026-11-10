/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 指定日新用户 D+0~D+7 每日付费统计（分商品 + 日汇总）
Cohort  : 由参数 ${PartDate:date1} 指定注册日的新用户（fixed_regdate 标签）
Window  : D+0 ~ D+7（注册日起共 8 天）
Metrics :
  - 每日付费人数（PU）
  - 每日付费金额（USD，扣除福利币）
  - 按商品明细拆分 + 每日汇总行
Notes   :
  - 新用户定义: fixed_regdate = 参数指定日期，排除黑名单，仅 iOS
  - 福利币抵扣: 通过 LCX_WALLET_SPEND_TRANSACTION 关联 purchaseid
  - 汇率换算: ta_dim.ta_exchange
  - 商品信息: ta_dim.dim_16_0_23989
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 0. 从参数解析注册日（D+0），生成 D+0 ~ D+7 日期序列
--------------------------------------------------------------------------------
StartDate AS (
    SELECT MIN(CAST("$part_date" AS DATE)) AS d0
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
),

DateRange AS (
    SELECT
        DATE_ADD('day', n, d0)  AS dt,
        n                       AS day_offset
    FROM StartDate
    CROSS JOIN UNNEST(SEQUENCE(0, 7)) AS t(n)
),

--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 目标新用户队列
--    fixed_regdate = 参数指定日期，fixed_os = 'iOS'，排除黑名单
--------------------------------------------------------------------------------
NewUsers AS (
    SELECT DISTINCT t1."#varchar_id" AS lcx_id
    FROM user_result_cluster_16 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND CAST(t1.tag_value AS DATE) = (SELECT d0 FROM StartDate)
      AND ub.lcx_id IS NULL
      AND EXISTS (
          SELECT 1
          FROM user_result_cluster_16 t2
          WHERE t2."#varchar_id" = t1."#varchar_id"
            AND t2.cluster_name  = 'fixed_os'
            AND t2.tag_value     = 'iOS'
      )
),

--------------------------------------------------------------------------------
-- 3. D+0~D+7 内这批新用户的购买事件（排除沙盒）
--------------------------------------------------------------------------------
PurchaseRaw AS (
    SELECT
        v."$part_date"              AS report_date,
        v."#account_id",
        v.payload.productid         AS productid,
        v.payload.curamt            AS amt,
        v.payload.cur               AS cur,
        v.payload.purchaseid        AS purchaseid
    FROM ta.v_event_16 v
    INNER JOIN NewUsers nu ON v."#account_id" = nu.lcx_id
    WHERE v."$part_date" BETWEEN CAST((SELECT d0 FROM StartDate) AS VARCHAR)
                              AND CAST(DATE_ADD('day', 7, (SELECT d0 FROM StartDate)) AS VARCHAR)
      AND v."$part_event" = 'PURCHASE'
      AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
),

--------------------------------------------------------------------------------
-- 4. 福利币抵扣记录
--------------------------------------------------------------------------------
WalletSpend AS (
    SELECT
        lcxtransactionid,
        ABS(freeamount) AS freeamount
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN CAST((SELECT d0 FROM StartDate) AS VARCHAR)
                            AND CAST(DATE_ADD('day', 7, (SELECT d0 FROM StartDate)) AS VARCHAR)
      AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
),

--------------------------------------------------------------------------------
-- 5. 关联汇率、商品维表，计算每笔实付 USD
--------------------------------------------------------------------------------
PurchaseDetail AS (
    SELECT
        p.report_date,
        p."#account_id",
        p.productid,
        COALESCE(d."payload.productid@product_category", '未知分类') AS product_category,
        COALESCE(d."payload.productid@product_name",     '未知商品') AS product_name,
        (CAST(p.amt AS DOUBLE) - COALESCE(w.freeamount, 0))
            / NULLIF(ex.exchange, 0)                                  AS revenue_usd
    FROM PurchaseRaw p
    LEFT JOIN WalletSpend w
        ON  p.purchaseid = w.lcxtransactionid
    LEFT JOIN ta_dim.ta_exchange ex
        ON  p.report_date = ex.ex_date
        AND p.cur         = ex.currency
    LEFT JOIN ta_dim.dim_16_0_23989 d
        ON  p.productid = d."payload.productid@product_id"
),

--------------------------------------------------------------------------------
-- 6. 按日 + 商品聚合，并追加每日汇总行
--------------------------------------------------------------------------------
DailyRevenue AS (
    -- 商品明细
    SELECT
        report_date,
        CAST(productid AS VARCHAR)  AS productid,
        product_name,
        product_category,
        COUNT(DISTINCT "#account_id") AS pu,
        ROUND(SUM(revenue_usd), 4)    AS revenue_usd
    FROM PurchaseDetail
    GROUP BY 1, 2, 3, 4

    UNION ALL

    -- 每日汇总行
    SELECT
        report_date,
        '—'                           AS productid,
        '【当日全部商品汇总】'           AS product_name,
        '—'                           AS product_category,
        COUNT(DISTINCT "#account_id") AS pu,
        ROUND(SUM(revenue_usd), 4)    AS revenue_usd
    FROM PurchaseDetail
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 7. 最终输出：以日期序列为主表，LEFT JOIN 付费数据
--------------------------------------------------------------------------------
SELECT
    CAST(dr.dt AS VARCHAR)                                              AS "日期",
    CONCAT('D+', CAST(dr.day_offset AS VARCHAR))                       AS "天数",
    COALESCE(rev.productid,        '—')                                AS "商品ID",
    COALESCE(rev.product_name,     '（无付费）')                        AS "商品名称",
    COALESCE(rev.product_category, '—')                                AS "商品类别",
    COALESCE(rev.pu,          0)                                        AS "付费人数(PU)",
    COALESCE(rev.revenue_usd, 0)                                        AS "付费金额(USD)"
FROM DateRange dr
LEFT JOIN DailyRevenue rev
    ON CAST(dr.dt AS VARCHAR) = rev.report_date
ORDER BY
    dr.day_offset ASC,
    -- 汇总行置顶
    CASE rev.product_name WHEN '【当日全部商品汇总】' THEN 0 ELSE 1 END ASC,
    rev.product_category ASC,
    rev.productid ASC;
