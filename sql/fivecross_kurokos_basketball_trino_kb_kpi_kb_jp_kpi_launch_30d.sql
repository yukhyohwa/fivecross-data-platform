/*
================================================================================
Game    : Kuroko's Basketball (黑子の篮球)
Region  : JP (日本, v_event_9)
Report  : 开服前30日核心KPI汇总
Launch  : 2023-11-16
Window  : 2023-11-16 ~ 2023-12-15 (开服后30天)
Metrics :
  - 统计时间范围、累计收入(USD)、累计NUU(新增设备)、日均DAU
  - 加权平均付费率(%)、加权平均ARPU、加权平均ARPPU
  - 次留(D2)、3留(D3)、4留(D4)、6留(D6)、7留(D7)、8留(D8)
  - 加权LTV1、加权LTV3、加权LTV7（仅开服前7天注册设备）
Engine  : Trino (TA) — v_event_9
Notes   :
  - 用户标识: #device_id（设备级）
  - 付费事件: charge（JP 无 scroin_buy/srcoin_buy）
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
        FROM ta.v_event_9
        WHERE "$part_event" = 'login'
          AND "$part_date" >= '2023-11-15'
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
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- 3. 设备基础表（开服30天内首次出现的设备，排除黑名单）
--------------------------------------------------------------------------------
DeviceBase AS (
    SELECT
        s1."#device_id",
        MIN(s1."$part_date") AS reg_date
    FROM ta.v_event_9 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" BETWEEN '2023-11-16' AND '2023-12-15'
      AND b."#user_id" IS NULL
      AND s1."#device_id" IS NOT NULL
      AND s1."#device_id" <> ''
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 4. 设备留存数组（覆盖 D8 所需窗口）
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
        FROM ta.v_event_9
        WHERE "$part_event" = 'login'
          AND "$part_date" BETWEEN '2023-11-16' AND '2023-12-23'  -- 覆盖 D8
        GROUP BY 1
    ) s1
    INNER JOIN DeviceBase s2 ON s1."#device_id" = s2."#device_id"
),

--------------------------------------------------------------------------------
-- 5. 设备 LTV 映射（仅开服前7天注册设备）
--------------------------------------------------------------------------------
DeviceLtvMap AS (
    SELECT
        m."#device_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE)
        ) AS revenue_map
    FROM ta.v_event_9 s1
    INNER JOIN UserDeviceMap m  ON s1."#user_id"  = m."#user_id"
    INNER JOIN DeviceBase s2    ON m."#device_id" = s2."#device_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_event" = 'charge'
      AND (s1.sandbox = FALSE OR s1.sandbox IS NULL)
      AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
      AND s1."$part_date" BETWEEN '2023-11-16' AND '2023-12-15'
      AND s2.reg_date < '2023-11-23'   -- 仅前7天注册设备
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
            WHEN s1."$part_event" = 'charge'
             AND (s1.sandbox = FALSE OR s1.sandbox IS NULL)
             AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN m."#device_id" END)                                            AS pdu,
        SUM(CASE
            WHEN s1."$part_event" = 'charge'
             AND (s1.sandbox = FALSE OR s1.sandbox IS NULL)
             AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
            THEN s1.pay_amount / COALESCE(ex.exchange, 1)
            ELSE 0 END)                                                         AS revenue
    FROM ta.v_event_9 s1
    LEFT JOIN UserDeviceMap m  ON s1."#user_id" = m."#user_id"
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_event" IN ('login', 'charge')
      AND s1."$part_date" BETWEEN '2023-11-16' AND '2023-12-15'
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
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 1)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d2,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 2)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d3,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 3)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d4,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 5)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d6,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 6)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d7,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 7)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1."#device_id"), 0)                       AS rr_d8,
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
    '2023-11-16'                                                                AS "开服日",
    MIN(dk.day)                                                                 AS "统计开始日",
    MAX(dk.day)                                                                 AS "统计结束日",
    ROUND(SUM(dk.revenue), 2)                                                   AS "前30日累计收入(USD)",
    SUM(nd.nuu)                                                                 AS "前30日累计NUU",
    ROUND(SUM(dk.dau) * 1.0 / COUNT(DISTINCT dk.day), 0)                       AS "日均DAU",
    -- 付费率：两位小数百分比
    CAST(ROUND(SUM(dk.pdu) * 100.0 / NULLIF(SUM(dk.dau), 0), 2) AS VARCHAR)
        || '%'                                                                  AS "加权平均付费率",
    ROUND(SUM(dk.revenue) * 1.0 / NULLIF(SUM(dk.dau), 0), 4)                  AS "加权平均ARPU(USD)",
    ROUND(SUM(dk.revenue) * 1.0 / NULLIF(SUM(dk.pdu), 0), 4)                  AS "加权平均ARPPU(USD)",
    ROUND(SUM(nd.nuu * nd.rr_d2) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "次留(D2)",
    ROUND(SUM(nd.nuu * nd.rr_d3) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "3留(D3)",
    ROUND(SUM(nd.nuu * nd.rr_d4) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "4留(D4)",
    ROUND(SUM(nd.nuu * nd.rr_d6) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "6留(D6)",
    ROUND(SUM(nd.nuu * nd.rr_d7) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "7留(D7)",
    ROUND(SUM(nd.nuu * nd.rr_d8) / NULLIF(SUM(nd.nuu), 0), 4)                 AS "8留(D8)",
    ROUND(
        SUM(CASE WHEN nd.day < '2023-11-23' THEN nd.nuu * nd.ltv1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2023-11-23' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV1(前7天cohort)",
    ROUND(
        SUM(CASE WHEN nd.day < '2023-11-23' THEN nd.nuu * nd.ltv3 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2023-11-23' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV3(前7天cohort)",
    ROUND(
        SUM(CASE WHEN nd.day < '2023-11-23' THEN nd.nuu * nd.ltv7 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2023-11-23' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV7(前7天cohort)"

FROM DailyKPI dk
LEFT JOIN NewDeviceMetrics nd ON dk.day = nd.day;
