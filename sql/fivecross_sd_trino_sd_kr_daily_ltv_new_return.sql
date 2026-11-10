/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计各时间聚合维度下各群组用户（新用户、回流用户60天、新用户+回流用户、老用户）的 LTV 追踪
           1. 支持周期自适应聚合：支持 日(D)、周(W)、月(M)、季度(S)、全部合并(A) 维度。
           2. 完整生命周期达标（Matured）过滤：仅统计对应天数生命周期已达标（DATE_ADD('day', N-1, cohort_date) <= mature_end_date）
              的用户数作为分母，消除近期注册/回流用户对长期 LTV 指标的拉低与稀释。
           3. 包含“完整生命周期到第几天” (date_gap) 监控字段，方便确认所选周期中哪些 LTV 指标是 100% 完整达标的。
           4. LTV1 ~ LTV90 (包含 ltv1, ltv2, ltv3, ltv4, ltv5, ltv6, ltv7, ltv14, ltv30, ltv60, ltv90)。
           5. 金额单位：人民币 (RMB)。

运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
  - 汇率表: ta_dim.ta_exchange
时间宏与选择器 : 
  - ${PartDate:date1} (适配数数后台自定义时间筛选)
  - ${Selector:timetype} (时间维度选择器: 'D'-日, 'W'-周, 'M'-月, 'S'-季, 'A'-全部)

用户分类定义:
  1. 新用户 (New Users)           : 首次在此日志中活跃的日期 = 当天
  2. 回流用户(60天) (Return Users) : 距上一次活跃日期 (prev_log_date) >= 60 天
  3. 新用户+回流用户              : 新用户 与 60天回流用户 的合并汇总
  4. 老用户 (Existing Old Users)  : 距上一次活跃日期 (prev_log_date) < 60 天的常规活跃老用户

输出列名 :
  时间维度, 日期范围, 用户类型, 用户数, 完整生命周期到第几天, ltv1, ltv2, ltv3, ltv4, ltv5, ltv6, ltv7, ltv14, ltv30, ltv60, ltv90
================================================================================
*/

WITH ScanConfig AS (
    -- 1. 自动计算扫描边界与留存/LTV的真实观察截止日 (current_date - 1)
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date,
        DATE_ADD('day', -1, CURRENT_DATE) AS mature_end_date
    FROM ta.v_event_22
    WHERE ${PartDate:date1}
),

UserRegDate AS (
    -- 2. 提取用户的 NUU 事件首发时间 (作为注册/新用户日期 reg_date)
    SELECT
        CAST("#account_id" AS VARCHAR) AS user_id,
        MIN(CAST("$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_22
    WHERE "$part_event" = 'NUU'
      AND "#account_id" IS NOT NULL
      AND "#account_id" <> ''
    GROUP BY 1
),

-- 3. 提取活跃日志 (向前预留 65 天历史日志以精确计算 60 天回流)
DailyLogins AS (
    SELECT DISTINCT
        CAST(v."#account_id" AS VARCHAR) AS user_id,
        CAST(v."$part_date" AS DATE) AS log_date
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE v."#account_id" IS NOT NULL 
      AND v."#account_id" <> ''
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND v."$part_date" >= CAST(DATE_ADD('day', -65, sc.target_start_date) AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
),

-- 4. 关联 NUU 注册日期，并计算上一次活跃日期
UserStatus AS (
    SELECT
        d.user_id,
        d.log_date,
        COALESCE(r.reg_date, MIN(d.log_date) OVER (PARTITION BY d.user_id)) AS first_log_date,
        LAG(d.log_date, 1) OVER (PARTITION BY d.user_id ORDER BY d.log_date) AS prev_log_date
    FROM DailyLogins d
    LEFT JOIN UserRegDate r ON d.user_id = r.user_id
),

-- 5. 划分选定时间范围内的用户群组类型 (新用户 / 60天回流用户 / 老用户)
CohortUsers AS (
    SELECT
        u.user_id,
        u.log_date AS cohort_date,
        CASE
            WHEN u.log_date = u.first_log_date THEN 'new'
            WHEN u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 60 THEN 'return'
            WHEN u.prev_log_date IS NULL AND DATE_DIFF('day', u.first_log_date, u.log_date) >= 60 THEN 'return'
            ELSE 'old'
        END AS cohort_type
    FROM UserStatus u
    CROSS JOIN ScanConfig sc
    WHERE u.log_date BETWEEN sc.target_start_date AND sc.target_end_date
),

-- 5. 提取充值流水并换算为人民币 (RMB)
UserRevenue AS (
    SELECT
        CAST(r."#account_id" AS VARCHAR) AS user_id,
        CAST(r."$part_date" AS DATE) AS pay_date,
        SUM(
            TRY_CAST(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.curamt') AS DOUBLE) 
            / COALESCE(ex.exchange, 1.0) 
            * COALESCE(cny.exchange, 1.0)
        ) AS rev_rmb
    FROM ta.v_event_22 r
    CROSS JOIN ScanConfig sc
    LEFT JOIN (
        SELECT ex_date, UPPER(currency) AS currency, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        GROUP BY 1, 2
    ) ex ON r."$part_date" = ex.ex_date 
        AND UPPER(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.cur')) = ex.currency
    LEFT JOIN (
        SELECT ex_date, ANY_VALUE(exchange) AS exchange
        FROM ta_dim.ta_exchange
        WHERE UPPER(currency) = 'CNY'
        GROUP BY 1
    ) cny ON r."$part_date" = cny.ex_date
    WHERE r."$part_event" = 'PURCHASE'
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND TRY_CAST(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.curamt') AS DOUBLE) > 0
      AND r."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND r."$part_date" <= CAST(DATE_ADD('day', 90, sc.target_end_date) AS VARCHAR)
      AND r."#account_id" IS NOT NULL
      AND r."#account_id" <> ''
    GROUP BY 1, 2
),

-- 6. 关联用户群组与充值流水，计算相对充值天数
CohortRevenue AS (
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        COALESCE(r.rev_rmb, 0.0) AS rev_rmb,
        DATE_DIFF('day', c.cohort_date, r.pay_date) AS ltv_day
    FROM CohortUsers c
    LEFT JOIN UserRevenue r
        ON c.user_id = r.user_id
       AND r.pay_date >= c.cohort_date
       AND DATE_DIFF('day', c.cohort_date, r.pay_date) <= 89 -- LTV90 覆盖 Day 0 到 Day 89
),

-- 7. 按单个用户与 cohort_date 计算各阶段 LTV 的累计付费
UserLtvAgg AS (
    SELECT
        user_id,
        cohort_date,
        cohort_type,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 0  THEN rev_rmb ELSE 0.0 END) AS rev_ltv1,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 1  THEN rev_rmb ELSE 0.0 END) AS rev_ltv2,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 2  THEN rev_rmb ELSE 0.0 END) AS rev_ltv3,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 3  THEN rev_rmb ELSE 0.0 END) AS rev_ltv4,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 4  THEN rev_rmb ELSE 0.0 END) AS rev_ltv5,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 5  THEN rev_rmb ELSE 0.0 END) AS rev_ltv6,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 6  THEN rev_rmb ELSE 0.0 END) AS rev_ltv7,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 13 THEN rev_rmb ELSE 0.0 END) AS rev_ltv14,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 29 THEN rev_rmb ELSE 0.0 END) AS rev_ltv30,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 59 THEN rev_rmb ELSE 0.0 END) AS rev_ltv60,
        SUM(CASE WHEN ltv_day BETWEEN 0 AND 89 THEN rev_rmb ELSE 0.0 END) AS rev_ltv90
    FROM CohortRevenue
    GROUP BY 1, 2, 3
),

-- 8. 按自适应时间维度与群组类型进行完整生命周期达标（Matured）聚合
CohortAggregation AS (
    -- 基础群组: 新用户、60天回流用户、老用户
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
            ELSE CAST(DATE_TRUNC('day', cohort_date) AS VARCHAR)
        END AS time_dimension,

        MAX(CONCAT(
            CAST(GREATEST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', cohort_date)
                    WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', cohort_date)
                    WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', cohort_date)
                    WHEN ${Selector:timetype} = 'S' THEN DATE_TRUNC('quarter', cohort_date)
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                    ELSE DATE_TRUNC('day', cohort_date)
                END, 
                sc.target_start_date
            ) AS VARCHAR),
            ' ~ ',
            CAST(LEAST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', cohort_date)
                    WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', cohort_date))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', cohort_date)))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, DATE_TRUNC('quarter', cohort_date)))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                    ELSE DATE_TRUNC('day', cohort_date)
                END,
                sc.target_end_date
            ) AS VARCHAR)
        )) AS date_range,

        MIN(DATE_DIFF('day', cohort_date, CURRENT_DATE)) AS date_gap,

        cohort_type,

        COUNT(DISTINCT user_id) AS total_users,
        COUNT_IF(rev_ltv90 > 0) AS paying_users,

        -- 各阶段仅对生命周期达标 (DATE_ADD <= mature_end_date) 的用户统计分子与分母
        SUM(CASE WHEN DATE_ADD('day', 0, cohort_date)  <= sc.mature_end_date THEN rev_ltv1  ELSE 0.0 END) AS rev_ltv1,
        COUNT_IF(DATE_ADD('day', 0, cohort_date)  <= sc.mature_end_date) AS users_ltv1,

        SUM(CASE WHEN DATE_ADD('day', 1, cohort_date)  <= sc.mature_end_date THEN rev_ltv2  ELSE 0.0 END) AS rev_ltv2,
        COUNT_IF(DATE_ADD('day', 1, cohort_date)  <= sc.mature_end_date) AS users_ltv2,

        SUM(CASE WHEN DATE_ADD('day', 2, cohort_date)  <= sc.mature_end_date THEN rev_ltv3  ELSE 0.0 END) AS rev_ltv3,
        COUNT_IF(DATE_ADD('day', 2, cohort_date)  <= sc.mature_end_date) AS users_ltv3,

        SUM(CASE WHEN DATE_ADD('day', 3, cohort_date)  <= sc.mature_end_date THEN rev_ltv4  ELSE 0.0 END) AS rev_ltv4,
        COUNT_IF(DATE_ADD('day', 3, cohort_date)  <= sc.mature_end_date) AS users_ltv4,

        SUM(CASE WHEN DATE_ADD('day', 4, cohort_date)  <= sc.mature_end_date THEN rev_ltv5  ELSE 0.0 END) AS rev_ltv5,
        COUNT_IF(DATE_ADD('day', 4, cohort_date)  <= sc.mature_end_date) AS users_ltv5,

        SUM(CASE WHEN DATE_ADD('day', 5, cohort_date)  <= sc.mature_end_date THEN rev_ltv6  ELSE 0.0 END) AS rev_ltv6,
        COUNT_IF(DATE_ADD('day', 5, cohort_date)  <= sc.mature_end_date) AS users_ltv6,

        SUM(CASE WHEN DATE_ADD('day', 6, cohort_date)  <= sc.mature_end_date THEN rev_ltv7  ELSE 0.0 END) AS rev_ltv7,
        COUNT_IF(DATE_ADD('day', 6, cohort_date)  <= sc.mature_end_date) AS users_ltv7,

        SUM(CASE WHEN DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date THEN rev_ltv14 ELSE 0.0 END) AS rev_ltv14,
        COUNT_IF(DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date) AS users_ltv14,

        SUM(CASE WHEN DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date THEN rev_ltv30 ELSE 0.0 END) AS rev_ltv30,
        COUNT_IF(DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date) AS users_ltv30,

        SUM(CASE WHEN DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date THEN rev_ltv60 ELSE 0.0 END) AS rev_ltv60,
        COUNT_IF(DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date) AS users_ltv60,

        SUM(CASE WHEN DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date THEN rev_ltv90 ELSE 0.0 END) AS rev_ltv90,
        COUNT_IF(DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date) AS users_ltv90

    FROM UserLtvAgg u
    CROSS JOIN ScanConfig sc
    GROUP BY 1, 4

    UNION ALL

    -- 合并群组: 新用户 + 回流用户
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', cohort_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
            ELSE CAST(DATE_TRUNC('day', cohort_date) AS VARCHAR)
        END AS time_dimension,

        MAX(CONCAT(
            CAST(GREATEST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', cohort_date)
                    WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', cohort_date)
                    WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', cohort_date)
                    WHEN ${Selector:timetype} = 'S' THEN DATE_TRUNC('quarter', cohort_date)
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                    ELSE DATE_TRUNC('day', cohort_date)
                END, 
                sc.target_start_date
            ) AS VARCHAR),
            ' ~ ',
            CAST(LEAST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', cohort_date)
                    WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', cohort_date))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', cohort_date)))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, DATE_TRUNC('quarter', cohort_date)))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                    ELSE DATE_TRUNC('day', cohort_date)
                END,
                sc.target_end_date
            ) AS VARCHAR)
        )) AS date_range,

        MIN(DATE_DIFF('day', cohort_date, CURRENT_DATE)) AS date_gap,

        'new+return' AS cohort_type,

        COUNT(DISTINCT user_id) AS total_users,
        COUNT_IF(rev_ltv90 > 0) AS paying_users,

        SUM(CASE WHEN DATE_ADD('day', 0, cohort_date)  <= sc.mature_end_date THEN rev_ltv1  ELSE 0.0 END) AS rev_ltv1,
        COUNT_IF(DATE_ADD('day', 0, cohort_date)  <= sc.mature_end_date) AS users_ltv1,

        SUM(CASE WHEN DATE_ADD('day', 1, cohort_date)  <= sc.mature_end_date THEN rev_ltv2  ELSE 0.0 END) AS rev_ltv2,
        COUNT_IF(DATE_ADD('day', 1, cohort_date)  <= sc.mature_end_date) AS users_ltv2,

        SUM(CASE WHEN DATE_ADD('day', 2, cohort_date)  <= sc.mature_end_date THEN rev_ltv3  ELSE 0.0 END) AS rev_ltv3,
        COUNT_IF(DATE_ADD('day', 2, cohort_date)  <= sc.mature_end_date) AS users_ltv3,

        SUM(CASE WHEN DATE_ADD('day', 3, cohort_date)  <= sc.mature_end_date THEN rev_ltv4  ELSE 0.0 END) AS rev_ltv4,
        COUNT_IF(DATE_ADD('day', 3, cohort_date)  <= sc.mature_end_date) AS users_ltv4,

        SUM(CASE WHEN DATE_ADD('day', 4, cohort_date)  <= sc.mature_end_date THEN rev_ltv5  ELSE 0.0 END) AS rev_ltv5,
        COUNT_IF(DATE_ADD('day', 4, cohort_date)  <= sc.mature_end_date) AS users_ltv5,

        SUM(CASE WHEN DATE_ADD('day', 5, cohort_date)  <= sc.mature_end_date THEN rev_ltv6  ELSE 0.0 END) AS rev_ltv6,
        COUNT_IF(DATE_ADD('day', 5, cohort_date)  <= sc.mature_end_date) AS users_ltv6,

        SUM(CASE WHEN DATE_ADD('day', 6, cohort_date)  <= sc.mature_end_date THEN rev_ltv7  ELSE 0.0 END) AS rev_ltv7,
        COUNT_IF(DATE_ADD('day', 6, cohort_date)  <= sc.mature_end_date) AS users_ltv7,

        SUM(CASE WHEN DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date THEN rev_ltv14 ELSE 0.0 END) AS rev_ltv14,
        COUNT_IF(DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date) AS users_ltv14,

        SUM(CASE WHEN DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date THEN rev_ltv30 ELSE 0.0 END) AS rev_ltv30,
        COUNT_IF(DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date) AS users_ltv30,

        SUM(CASE WHEN DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date THEN rev_ltv60 ELSE 0.0 END) AS rev_ltv60,
        COUNT_IF(DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date) AS users_ltv60,

        SUM(CASE WHEN DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date THEN rev_ltv90 ELSE 0.0 END) AS rev_ltv90,
        COUNT_IF(DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date) AS users_ltv90

    FROM UserLtvAgg u
    CROSS JOIN ScanConfig sc
    WHERE cohort_type IN ('new', 'return')
    GROUP BY 1
),

-- 9. 格式化最终输出报表
FinalOutput AS (
    SELECT
        time_dimension AS "时间维度",
        date_range AS "日期范围",
        CASE 
            WHEN cohort_type = 'new' THEN '1.新用户'
            WHEN cohort_type = 'return' THEN '2.回流用户(60天)'
            WHEN cohort_type = 'new+return' THEN '3.新用户+回流用户'
            WHEN cohort_type = 'old' THEN '4.老用户'
        END AS "用户类型",
        total_users AS "用户数",
        paying_users AS "付费用户数",
        date_gap AS "完整生命周期到第几天",

        -- 人均 LTV (人民币 RMB)，若该阶段无生命周期达标用户则输出 NULL
        ROUND(TRY(rev_ltv1  / NULLIF(users_ltv1,  0)), 2) AS "ltv1",
        ROUND(TRY(rev_ltv2  / NULLIF(users_ltv2,  0)), 2) AS "ltv2",
        ROUND(TRY(rev_ltv3  / NULLIF(users_ltv3,  0)), 2) AS "ltv3",
        ROUND(TRY(rev_ltv4  / NULLIF(users_ltv4,  0)), 2) AS "ltv4",
        ROUND(TRY(rev_ltv5  / NULLIF(users_ltv5,  0)), 2) AS "ltv5",
        ROUND(TRY(rev_ltv6  / NULLIF(users_ltv6,  0)), 2) AS "ltv6",
        ROUND(TRY(rev_ltv7  / NULLIF(users_ltv7,  0)), 2) AS "ltv7",
        ROUND(TRY(rev_ltv14 / NULLIF(users_ltv14, 0)), 2) AS "ltv14",
        ROUND(TRY(rev_ltv30 / NULLIF(users_ltv30, 0)), 2) AS "ltv30",
        ROUND(TRY(rev_ltv60 / NULLIF(users_ltv60, 0)), 2) AS "ltv60",
        ROUND(TRY(rev_ltv90 / NULLIF(users_ltv90, 0)), 2) AS "ltv90"
    FROM CohortAggregation
)

SELECT * 
FROM FinalOutput
ORDER BY "时间维度" DESC, "用户类型";
