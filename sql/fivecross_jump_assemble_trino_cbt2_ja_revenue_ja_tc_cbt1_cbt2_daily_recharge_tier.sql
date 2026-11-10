/*
================================================================================
Game    : Jump Assemble (众星之聚)
Region  : TC (Traditional Chinese - TW/HK/MO)
Report  : 每日充值档位分布 — CBT1 & CBT2 合并
Tag     : ja_tc  cbt1  cbt2

时段说明：
  · CBT1：2025-11-25 ~ 2025-12-02（仅 Android 用户）
  · CBT2：2026-04-15 ~ 2026-04-23（仅 iOS 用户）

OS 过滤逻辑：
  · 通过 COALESCE(lcxsdkcommon.lcx_id, sdkcommon.lcx_id) 关联 user_result_cluster_16 取 fixed_os
  · CBT1 时段：fixed_os = 'Android'
  · CBT2 时段：fixed_os = 'iOS'

档位划分（按用户当日 USD 充值总额）：
  a.(0,1]  /  b.(1,10]  /  c.(10,50]  /  d.(50,100]  /  e.(100,500]  /  f.(500,∞]

注意：
  · 排除沙盒单据：validationtype <> 'SANDBOX_RECEIPT'
  · 排除内部用户 / 水军账号（黑名单）
  · 汇率换算来自 ta_dim.ta_exchange

Environment: Trino (TA) — v_event_16  表编号 16
================================================================================
*/

WITH

-- ──────────────────────────────────────────────────────────────
-- 1. 黑名单用户（排除内部测试号 & 水军）
-- ──────────────────────────────────────────────────────────────
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- ──────────────────────────────────────────────────────────────
-- 2. 用户 OS 标签（通过 lcxsdkcommon.lcx_id / sdkcommon.lcx_id 关联）
-- ──────────────────────────────────────────────────────────────
UserProfile AS (
    SELECT
        "#varchar_id"                                                               AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END)           AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END)           AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END)           AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END)           AS fixed_store
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store')
    GROUP BY "#varchar_id"
),

-- ──────────────────────────────────────────────────────────────
-- 3. CBT1 + CBT2 两个测试期的有效充值事件
--    · CBT1（2025-11-25 ~ 2025-12-02）：仅 Android
--    · CBT2（2026-04-15 ~ 2026-04-23）：仅 iOS
--    · 排除 SANDBOX_RECEIPT
--    · 排除黑名单账号
-- ──────────────────────────────────────────────────────────────
PurchaseEvents AS (
    SELECT
        v."$part_date"                                                              AS log_date,
        v."#account_id"                                                             AS account_id,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)    AS amt,
        JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur')                       AS cur
    FROM ta.v_event_16 v
    LEFT JOIN UserBlacklist ub
           ON v."#account_id" = ub."#account_id"
    LEFT JOIN UserProfile up
           ON v."#account_id" = up.lcx_id
    WHERE ub."#account_id" IS NULL
      AND v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND LENGTH(v."#account_id") = 36
      AND (
            (v."$part_date" BETWEEN '2025-11-25' AND '2025-12-02')
         OR (v."$part_date" BETWEEN '2026-04-15' AND '2026-04-23')
      )
      -- OS 过滤：CBT1 只取 Android，CBT2 只取 iOS
      AND (
          (v."$part_date" BETWEEN '2025-11-25' AND '2025-12-02' AND up.fixed_os = 'Android')
          OR
          (v."$part_date" BETWEEN '2026-04-15' AND '2026-04-23' AND up.fixed_os = 'iOS')
      )
),

-- ──────────────────────────────────────────────────────────────
-- 4. 每位用户每日充值总额（折合 USD）
-- ──────────────────────────────────────────────────────────────
DailyUserRevenue AS (
    SELECT
        p.log_date,
        p.account_id,
        SUM(p.amt / COALESCE(ex.exchange, 1)) AS daily_revenue_usd
    FROM PurchaseEvents p
    LEFT JOIN ta_dim.ta_exchange ex
           ON p.log_date = ex.ex_date
          AND p.cur      = ex.currency
    GROUP BY 1, 2
),

-- ──────────────────────────────────────────────────────────────
-- 5. 档位划分（按当日 USD 充值总额）
-- ──────────────────────────────────────────────────────────────
TierAssignment AS (
    SELECT
        log_date,
        account_id,
        daily_revenue_usd,
        CASE
            WHEN daily_revenue_usd <= 1   THEN 'a.(0,1]'
            WHEN daily_revenue_usd <= 10  THEN 'b.(1,10]'
            WHEN daily_revenue_usd <= 50  THEN 'c.(10,50]'
            WHEN daily_revenue_usd <= 100 THEN 'd.(50,100]'
            WHEN daily_revenue_usd <= 500 THEN 'e.(100,500]'
            ELSE                               'f.(500,∞]'
        END AS recharge_tier
    FROM DailyUserRevenue
)

-- ──────────────────────────────────────────────────────────────
-- 6. 汇总：每日 × 充值档位  →  付费人数 & 总流水
-- ──────────────────────────────────────────────────────────────
SELECT
    log_date                          AS "日期",
    recharge_tier                     AS "充值档位",
    COUNT(DISTINCT account_id)        AS "付费人数(PU)",
    ROUND(SUM(daily_revenue_usd), 2)  AS "总流水(USD)"
FROM TierAssignment
GROUP BY 1, 2
ORDER BY 1 DESC, 2 ASC;
