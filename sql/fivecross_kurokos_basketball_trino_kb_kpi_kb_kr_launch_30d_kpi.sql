/*
================================================================================
Game    : Kuroko's Basketball (黑子の篮球)
Region  : KR (韩国, v_event_12)
Report  : 开服前30日核心KPI汇总 (基于 uuid 唯一用户标识)
Launch  : 2024-06-19
Window  : 2024-06-19 ~ 2024-07-18 (开服后30天)
Metrics :
  - 统计时间范围、累计收入(USD)、累计新用户、日均DAU
  - 加权平均付费率(%)、加权平均ARPU、加权平均ARPPU
  - 次留(D2)、3留(D3)、4留(D4)、6留(D6)、7留(D7)、8留(D8)
  - 加权LTV1、加权LTV3、加权LTV7（仅开服前7天注册用户）
Engine  : Trino (TA) — v_event_12
Notes   :
  - 用户标识: uuid
  - 付费事件: charge + scroin_buy + srcoin_buy
  - 黑名单: cohort_20231116_224917, cohort_waternew
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 黑名单
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_12
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- 2. 用户基础表（开服30天内首次出现的 uuid，排除黑名单）
--------------------------------------------------------------------------------
UserBase AS (
    SELECT
        s1.uuid AS user_id,
        MIN(s1."$part_date") AS reg_date
    FROM ta.v_event_12 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" BETWEEN '2024-06-19' AND '2024-07-18'
      AND b."#user_id" IS NULL
      AND s1.uuid IS NOT NULL
      AND s1.uuid <> ''
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 3. 用户留存数组（覆盖 D8 所需窗口）
--------------------------------------------------------------------------------
UserRetentionArrays AS (
    SELECT
        s1.user_id,
        s2.reg_date,
        TRANSFORM(
            ARRAY_SORT(s1.return_date_array),
            d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)
        ) AS return_days_array
    FROM (
        SELECT
            uuid AS user_id,
            ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_12
        WHERE "$part_event" = 'login'
          AND "$part_date" BETWEEN '2024-06-19' AND '2024-07-26'  -- 覆盖 D8
          AND uuid IS NOT NULL
          AND uuid <> ''
        GROUP BY 1
    ) s1
    INNER JOIN UserBase s2 ON s1.user_id = s2.user_id
),

--------------------------------------------------------------------------------
-- 4. 用户 LTV 映射（仅开服前7天注册用户）
--------------------------------------------------------------------------------
UserLtvMap AS (
    SELECT
        s1.uuid AS user_id,
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            CAST(s1.pay_amount / COALESCE(ex.exchange, 1) AS DOUBLE)
        ) AS revenue_map
    FROM ta.v_event_12 s1
    INNER JOIN UserBase s2 ON s1.uuid = s2.user_id
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE (
              (s1."$part_event" = 'charge'
               AND s1.pay_currency <> 'kuroko_pay'
               AND (s1.sandbox = FALSE OR s1.sandbox IS NULL))
           OR s1."$part_event" IN ('scroin_buy', 'srcoin_buy')
          )
      AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
      AND s1."$part_date" BETWEEN '2024-06-19' AND '2024-07-18'
      AND s2.reg_date < '2024-06-26'   -- 仅前7天注册用户
      AND s1.uuid IS NOT NULL
      AND s1.uuid <> ''
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 5. 每日大盘 KPI（DAU、付费用户、流水）
--------------------------------------------------------------------------------
DailyKPI AS (
    SELECT
        s1."$part_date"                                                         AS day,
        COUNT(DISTINCT CASE
            WHEN s1."$part_event" = 'login'
             AND s1.uuid IS NOT NULL
             AND s1.uuid <> ''
            THEN s1.uuid END)                                                   AS dau,
        COUNT(DISTINCT CASE
            WHEN (
                     (s1."$part_event" = 'charge'
                      AND s1.pay_currency <> 'kuroko_pay'
                      AND (s1.sandbox = FALSE OR s1.sandbox IS NULL))
                  OR s1."$part_event" IN ('scroin_buy', 'srcoin_buy')
                 )
             AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL)
             AND s1.uuid IS NOT NULL
             AND s1.uuid <> ''
            THEN s1.uuid END)                                                   AS pdu,
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
    FROM ta.v_event_12 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_event" IN ('login', 'charge', 'scroin_buy', 'srcoin_buy')
      AND s1."$part_date" BETWEEN '2024-06-19' AND '2024-07-18'
      AND b."#user_id" IS NULL
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 6. 新用户每日 KPI（新用户数、留存、LTV）
--------------------------------------------------------------------------------
NewUserMetrics AS (
    SELECT
        s1.reg_date                                                             AS day,
        COUNT(DISTINCT s1.user_id)                                              AS nuu,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 1)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1.user_id), 0)                             AS rr_d2,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 2)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1.user_id), 0)                             AS rr_d3,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 3)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1.user_id), 0)                             AS rr_d4,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 5)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1.user_id), 0)                             AS rr_d6,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 6)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1.user_id), 0)                             AS rr_d7,
        CAST(COUNT_IF(CONTAINS(r.return_days_array, 7)) AS DOUBLE)
            / NULLIF(COUNT(DISTINCT s1.user_id), 0)                             AS rr_d8,
        CAST(AVG(COALESCE(REDUCE(
            MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 1)),
            0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE)              AS ltv1,
        CAST(AVG(COALESCE(REDUCE(
            MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 3)),
            0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE)              AS ltv3,
        CAST(AVG(COALESCE(REDUCE(
            MAP_VALUES(MAP_FILTER(l.revenue_map, (k, v) -> k < 7)),
            0.0, (acc, v) -> acc + v, acc -> acc), 0)) AS DOUBLE)              AS ltv7
    FROM UserBase s1
    LEFT JOIN UserRetentionArrays r ON s1.user_id = r.user_id
    LEFT JOIN UserLtvMap l          ON s1.user_id = l.user_id
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 7. 最终输出：30天汇总一行
--------------------------------------------------------------------------------
SELECT
    '2024-06-19'                                                                AS "开服日",
    MIN(dk.day)                                                                 AS "统计开始日",
    MAX(dk.day)                                                                 AS "统计结束日",
    ROUND(SUM(dk.revenue), 2)                                                   AS "前30日累计收入(USD)",
    SUM(nd.nuu)                                                                 AS "前30日累计新用户",
    ROUND(SUM(dk.dau) * 1.0 / COUNT(DISTINCT dk.day), 0)                       AS "日均DAU",
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
        SUM(CASE WHEN nd.day < '2024-06-26' THEN nd.nuu * nd.ltv1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2024-06-26' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV1(前7天cohort)",
    ROUND(
        SUM(CASE WHEN nd.day < '2024-06-26' THEN nd.nuu * nd.ltv3 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2024-06-26' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV3(前7天cohort)",
    ROUND(
        SUM(CASE WHEN nd.day < '2024-06-26' THEN nd.nuu * nd.ltv7 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN nd.day < '2024-06-26' THEN nd.nuu ELSE 0 END), 0)
    , 4)                                                                        AS "加权LTV7(前7天cohort)"

FROM DailyKPI dk
LEFT JOIN NewUserMetrics nd ON dk.day = nd.day;
