/*
================================================================================
Game    : Kuroko's Basketball (黑子的篮球)
Region  : TC (繁体 台湾, app_id=10)
Report  : 开服前30日核心KPI汇总
Launch  : 2024-01-24
Window  : 2024-01-24 ~ 2024-02-22 (开服后30天)
Metrics :
  - 统计时间范围、累计收入(USD)、累计NUU(新增设备)、日均DAU
  - 加权平均付费率、加权平均ARPU、加权平均ARPPU
  - 次留(D2)、3留(D3)、4留(D4)、6留(D6)、7留(D7)、8留(D8)
  - 加权LTV1、加权LTV3、加权LTV7（仅开服前7天注册设备）
Engine  : Trino (TA) — v_event_10
Notes   :
  - 用户标识: #device_id（设备级）
  - 付费通过 UserDeviceMap 映射到设备
  - 黑名单: cohort_20231116_224917, cohort_waternew
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 用户-设备映射（取用户首次登录时的设备）
--------------------------------------------------------------------------------
UserDeviceMap AS (
    SELECT "#user_id", "#device_id"
    FROM (
        SELECT
            "#user_id",
            "#device_id",
            ROW_NUMBER() OVER (
                PARTITION BY "#user_id"
                ORDER BY "$part_date" ASC, "#event_time" ASC
            ) AS rn
        FROM ta.v_event_10
        WHERE "$part_event" = 'login'
          AND "$part_date" >= '2024-01-23'
          AND "#device_id" IS NOT NULL
          AND "#device_id" <> ''
    )
    WHERE rn = 1
),

--------------------------------------------------------------------------------
-- 2. 黑名单
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- 3. 设备基础表（开服30天内首次出现的设备，排除黑名单）
--------------------------------------------------------------------------------
DeviceBase AS (
    SELECT
        s1."#device_id",
        MIN(s1."$part_date") AS reg_date
    FROM ta.v_event_10 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" BETWEEN '2024-01-24' AND '2024-02-22'
      AND b."#user_id" IS NULL
      AND s1."#device_id" IS NOT NULL
      AND s1."#device_id" <> ''
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 4. 设备留存数组（扫描开服日起至 D+37，覆盖 D8 留存所需窗口）
--------------------------------------------------------------------------------
DeviceRetentionArrays AS (
    SELECT
        s1."#device_id",
        s2.reg_date,
        TRANSFORM(
            ARRAY_SORT(s1.return_date_array),
            d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)
        ) AS return_days_array
    FROM (
        SELECT
            "#device_id",
            ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_10
        WHERE "$part_event" = 'login'
          AND "$part_date" BETWEEN '2024-01-24' AND '2024-02-29'  -- 覆盖 D8
        GROUP BY 1
    ) s1
    INNER JOIN DeviceBase s2 ON s1."#device_id" = s2."#device_id"
),

--------------------------------------------------------------------------------
-- 5. 设备 LTV 映射（付费通过 UserDeviceMap 挂载到设备）
--    仅取开服前7天注册设备（与竞品 LTV 口径对齐）
--------------------------------------------------------------------------------
DeviceLtvMap AS (
    SELECT
        m."#device_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE)
        ) AS revenue_map
    FROM ta.v_event_10 s1
    INNER JOIN UserDeviceMap m   ON s1."#user_id"    = m."#user_id"
    INNER JOIN DeviceBase s2     ON m."#device_id"   = s2."#device_id"
    LEFT JOIN ta_dim.ta_exchange ex
        ON s1."$part_date" = ex.ex_date
       AND s1.pay_currency = ex.currency
    WHERE (
              (s1."$part_event" = 'charge'
               AND s1.pay_currency <> 'kuroko_pay'
               AND (s1.sandbox = FALSE OR s1.sandbox IS NULL))
           OR s1."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
      AND s1."$part_date" BETWEEN '2024-01-24' AND '2024-02-22'
      -- 仅前7天注册设备参与 LTV 计算
      AND s2.reg_date < '2024-01-31'
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 6. 每日大盘 KPI（DAU、付费设备、流水）
--------------------------------------------------------------------------------
DailyKPI AS (
    SELECT
        s1."$part_date"                                                         AS day,
        COUNT(DISTINCT CASE
            WHEN s1."$part_event" = 'login'
             AND s1."#device_id" IS NOT NULL
             AND s1."#device_id" <> ''
            THEN s1."#device_id" END)                                           AS dau,
        COUNT(DISTINCT CASE
            WHEN (
                     (s1."$part_event" = 'charge'
                      AND s1.pay_currency <> 'kuroko_pay'
                      AND (s1.sandbox = FALSE OR s1.sandbox IS NULL))
                  OR s1."$part_event" IN ('scroin_buy', 'srcoin_buy')
                 )
             AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN m."#device_id" END)                                            AS pdu,
        SUM(CASE
            WHEN (
                     (s1."$part_event" = 'charge'
                      AND s1.pay_currency <> 'kuroko_pay'
                      AND (s1.sandbox = FALSE OR s1.sandbox IS NULL))
                  OR s1."$part_event" IN ('scroin_buy', 'srcoin_buy')
                 )
             AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN s1.pay_amount / COALESCE(ex.exchange, 1)
            ELSE 0 END)                                                         AS revenue
    FROM ta.v_event_10 s1
    LEFT JOIN UserDeviceMap m   ON s1."#user_id" = m."#user_id"
    LEFT JOIN FinalBlacklist b  ON s1."#user_id" = b."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
      AND s1."$part_date" BETWEEN '2024-01-24' AND '2024-02-22'
      AND b."#user_id" IS NULL
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 7. 新增设备每日 KPI（NUU、留存、LTV）
--------------------------------------------------------------------------------
NewDeviceMetrics AS (
    SELECT
        s1.reg_date                                                             AS day,
        COUNT(DISTINCT s1."#device_id")                                        AS nuu,
        -- 留存
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 1))  AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d2,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 2))  AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d3,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 3))  AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d4,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 5))  AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d6,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 6))  AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d7,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 7))  AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d8,
        -- LTV（仅前7天注册设备有 revenue_map，其余为 NULL → AVG 自动忽略）
        CAST(AVG(COALESCE(REDUCE(
            MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 1)),
            0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE)              AS ltv1,
        CAST(AVG(COALESCE(REDUCE(
            MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 3)),
            0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE)              AS ltv3,
        CAST(AVG(COALESCE(REDUCE(
            MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 7)),
            0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE)              AS ltv7
    FROM DeviceBase s1
    LEFT JOIN DeviceRetentionArrays r ON s1."#device_id" = r."#device_id"
    LEFT JOIN DeviceLtvMap l          ON s1."#device_id" = l."#device_id"
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 8. 最终输出：30天汇总一行
--------------------------------------------------------------------------------
SELECT
    '2024-01-24'                                                                AS "开服日",
    MIN(dk.day)                                                                 AS "统计开始日",
    MAX(dk.day)                                                                 AS "统计结束日",
    ROUND(SUM(dk.revenue), 2)                                                   AS "前30日累计收入(USD)",
    SUM(nd.nuu)                                                                 AS "前30日累计NUU",
    ROUND(SUM(dk.dau) * 1.0 / COUNT(DISTINCT dk.day), 0)                       AS "日均DAU",
    -- 加权平均付费率 = SUM(付费设备) / SUM(DAU)
    CAST(ROUND(SUM(dk.pdu) * 100.0 / NULLIF(SUM(dk.dau), 0), 2) AS VARCHAR)
        || '%'                                                                  AS "加权平均付费率",
    -- 加权平均 ARPU = SUM(流水) / SUM(DAU)
    ROUND(SUM(dk.revenue) * 1.0 / NULLIF(SUM(dk.dau), 0), 4)                  AS "加权平均ARPU(USD)",
    -- 加权平均 ARPPU = SUM(流水) / SUM(付费设备)
    ROUND(SUM(dk.revenue) * 1.0 / NULLIF(SUM(dk.pdu), 0), 4)                  AS "加权平均ARPPU(USD)",
    -- 加权留存（SUM(各日留存人数) / SUM(各日NUU)）
    ROUND(SUM(nd.nuu * nd.rr_d2) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "次留(D2)",
    ROUND(SUM(nd.nuu * nd.rr_d3) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "3留(D3)",
    ROUND(SUM(nd.nuu * nd.rr_d4) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "4留(D4)",
    ROUND(SUM(nd.nuu * nd.rr_d6) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "6留(D6)",
    ROUND(SUM(nd.nuu * nd.rr_d7) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "7留(D7)",
    ROUND(SUM(nd.nuu * nd.rr_d8) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "8留(D8)",
    -- 加权 LTV（仅前7天注册设备，AVG 已在 NewDeviceMetrics 中按日计算）
    -- 这里再做跨日加权：SUM(各日NUU_前7天 * 各日LTV) / SUM(各日NUU_前7天)
    ROUND(
        SUM(CASE WHEN nd.day < '2024-01-31' THEN nd.nuu * nd.ltv1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2024-01-31' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV1(前7天cohort)",
    ROUND(
        SUM(CASE WHEN nd.day < '2024-01-31' THEN nd.nuu * nd.ltv3 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2024-01-31' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV3(前7天cohort)",
    ROUND(
        SUM(CASE WHEN nd.day < '2024-01-31' THEN nd.nuu * nd.ltv7 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2024-01-31' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV7(前7天cohort)"

FROM DailyKPI dk
LEFT JOIN NewDeviceMetrics nd ON dk.day = nd.day;
