/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计各时间聚合维度下群组用户（新用户、回流用户60天、新用户+回流用户，不包含老用户）的 留存率 (Retention Rate) 追踪
           1. 支持周期自适应聚合：支持 日(D)、周(W)、月(M)、季度(S)、全部合并(A) 维度。
           2. 完整生命周期达标（Matured）过滤：仅统计对应天数生命周期已达标（DATE_ADD('day', N-1, cohort_date) <= mature_end_date）
              的用户数作为分母，消除近期注册/回流用户对长期留存指标的拉低与稀释。
           3. 包含“完整生命周期到第几天” (date_gap) 监控字段，方便确认所选周期中哪些留存指标是 100% 完整达标的。
           4. 包含指标: 用户数, 付费用户数, 完整生命周期到第几天, rr1 (次留), rr3, rr4, rr5, rr6, rr7, rr14, rr30, rr60, rr90。

运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
  - 汇率表: ta_dim.ta_exchange
时间宏与选择器 : 
  - ${PartDate:date1} (适配数数后台自定义时间筛选)
  - ${Selector:timetype} (时间维度选择器: 'D'-日, 'W'-周, 'M'-月, 'S'-季, 'A'-全部)

用户分类定义 (排除老用户):
  1. 新用户 (New Users)           : 触发 NUU 事件日期 = 当天
  2. 回流用户(60天) (Return Users) : 距上一次活跃日期 (prev_log_date) >= 60 天
  3. 新用户+回流用户              : 新用户 与 60天回流用户 的合并汇总

输出列名 :
  时间维度, 日期范围, 用户类型, 用户数, 付费用户数, 完整生命周期到第几天, rr1, rr3, rr4, rr5, rr6, rr7, rr14, rr30, rr60, rr90
================================================================================
*/

WITH ScanConfig AS (
    -- 1. 自动计算扫描边界与留存的真实观察截止日 (current_date - 1)
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

DailyLogins AS (
    -- 3. 提取活跃日志 (向前预留 65 天历史日志做回流判定，向后延伸 90 天以覆盖留存观察期)
    SELECT DISTINCT
        CAST(v."#account_id" AS VARCHAR) AS user_id,
        CAST(v."$part_date" AS DATE) AS log_date
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE v."#account_id" IS NOT NULL 
      AND v."#account_id" <> ''
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND v."$part_date" >= CAST(DATE_ADD('day', -65, sc.target_start_date) AS VARCHAR)
      AND v."$part_date" <= CAST(DATE_ADD('day', 90, sc.target_end_date) AS VARCHAR)
),

UserStatus AS (
    -- 4. 关联 NUU 注册日期，并计算上一次活跃日期 (prev_log_date)
    SELECT
        d.user_id,
        d.log_date,
        COALESCE(r.reg_date, MIN(d.log_date) OVER (PARTITION BY d.user_id)) AS first_log_date,
        LAG(d.log_date, 1) OVER (PARTITION BY d.user_id ORDER BY d.log_date) AS prev_log_date
    FROM DailyLogins d
    LEFT JOIN UserRegDate r ON d.user_id = r.user_id
),

CohortUsers AS (
    -- 5. 划分选定时间范围内的目标群组类型 (仅筛选 新用户 与 60天回流用户，排除老用户)
    SELECT
        u.user_id,
        u.log_date AS cohort_date,
        CASE
            WHEN u.log_date = u.first_log_date THEN 'new'
            ELSE 'return'
        END AS cohort_type
    FROM UserStatus u
    CROSS JOIN ScanConfig sc
    WHERE u.log_date BETWEEN sc.target_start_date AND sc.target_end_date
      AND (
          u.log_date = u.first_log_date
          OR (u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 60)
          OR (u.prev_log_date IS NULL AND DATE_DIFF('day', u.first_log_date, u.log_date) >= 60)
      )
),

UserRevenue AS (
    -- 6. 提取观察期内的充值流水用户 (用来识别付费用户数)
    SELECT DISTINCT
        CAST(r."#account_id" AS VARCHAR) AS user_id
    FROM ta.v_event_22 r
    CROSS JOIN ScanConfig sc
    WHERE r."$part_event" = 'PURCHASE'
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND TRY_CAST(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.curamt') AS DOUBLE) > 0
      AND r."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND r."$part_date" <= CAST(DATE_ADD('day', 90, sc.target_end_date) AS VARCHAR)
      AND r."#account_id" IS NOT NULL
      AND r."#account_id" <> ''
),

CohortRetention AS (
    -- 7. 关联群组用户与活跃日志，计算相对留存天数
    SELECT
        c.user_id,
        c.cohort_date,
        c.cohort_type,
        CASE WHEN rev.user_id IS NOT NULL THEN 1 ELSE 0 END AS is_paying,
        DATE_DIFF('day', c.cohort_date, d.log_date) AS ret_day
    FROM CohortUsers c
    LEFT JOIN DailyLogins d
        ON c.user_id = d.user_id
       AND d.log_date >= c.cohort_date
       AND DATE_DIFF('day', c.cohort_date, d.log_date) <= 89
    LEFT JOIN UserRevenue rev
        ON c.user_id = rev.user_id
),

UserRetentionAgg AS (
    -- 8. 按单个用户与 cohort_date 统计各 Day 留存打标 (1:留存, 0:未留存)
    SELECT
        user_id,
        cohort_date,
        cohort_type,
        MAX(is_paying) AS is_paying,
        MAX(CASE WHEN ret_day = 1  THEN 1 ELSE 0 END) AS ret_1,   -- 次留 (Day 1)
        MAX(CASE WHEN ret_day = 2  THEN 1 ELSE 0 END) AS ret_3,   -- 3日留存 (Day 2)
        MAX(CASE WHEN ret_day = 3  THEN 1 ELSE 0 END) AS ret_4,   -- 4日留存 (Day 3)
        MAX(CASE WHEN ret_day = 4  THEN 1 ELSE 0 END) AS ret_5,   -- 5日留存 (Day 4)
        MAX(CASE WHEN ret_day = 5  THEN 1 ELSE 0 END) AS ret_6,   -- 6日留存 (Day 5)
        MAX(CASE WHEN ret_day = 6  THEN 1 ELSE 0 END) AS ret_7,   -- 7日留存 (Day 6)
        MAX(CASE WHEN ret_day = 13 THEN 1 ELSE 0 END) AS ret_14,  -- 14日留存 (Day 13)
        MAX(CASE WHEN ret_day = 29 THEN 1 ELSE 0 END) AS ret_30,  -- 30日留存 (Day 29)
        MAX(CASE WHEN ret_day = 59 THEN 1 ELSE 0 END) AS ret_60,  -- 60日留存 (Day 59)
        MAX(CASE WHEN ret_day = 89 THEN 1 ELSE 0 END) AS ret_90   -- 90日留存 (Day 89)
    FROM CohortRetention
    GROUP BY 1, 2, 3
),

CohortAggregation AS (
    -- 9. 按自适应时间维度与群组类型进行完整生命周期达标（Matured）留存率聚合
    -- 基础群组: 新用户、60天回流用户
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
        COUNT_IF(is_paying = 1) AS paying_users,

        -- 对应阶段达标用户的留存分子与分母
        SUM(CASE WHEN DATE_ADD('day', 1,  cohort_date) <= sc.mature_end_date THEN ret_1  ELSE 0 END) AS act_ret1,
        COUNT_IF(DATE_ADD('day', 1,  cohort_date) <= sc.mature_end_date) AS mat_ret1,

        SUM(CASE WHEN DATE_ADD('day', 2,  cohort_date) <= sc.mature_end_date THEN ret_3  ELSE 0 END) AS act_ret3,
        COUNT_IF(DATE_ADD('day', 2,  cohort_date) <= sc.mature_end_date) AS mat_ret3,

        SUM(CASE WHEN DATE_ADD('day', 3,  cohort_date) <= sc.mature_end_date THEN ret_4  ELSE 0 END) AS act_ret4,
        COUNT_IF(DATE_ADD('day', 3,  cohort_date) <= sc.mature_end_date) AS mat_ret4,

        SUM(CASE WHEN DATE_ADD('day', 4,  cohort_date) <= sc.mature_end_date THEN ret_5  ELSE 0 END) AS act_ret5,
        COUNT_IF(DATE_ADD('day', 4,  cohort_date) <= sc.mature_end_date) AS mat_ret5,

        SUM(CASE WHEN DATE_ADD('day', 5,  cohort_date) <= sc.mature_end_date THEN ret_6  ELSE 0 END) AS act_ret6,
        COUNT_IF(DATE_ADD('day', 5,  cohort_date) <= sc.mature_end_date) AS mat_ret6,

        SUM(CASE WHEN DATE_ADD('day', 6,  cohort_date) <= sc.mature_end_date THEN ret_7  ELSE 0 END) AS act_ret7,
        COUNT_IF(DATE_ADD('day', 6,  cohort_date) <= sc.mature_end_date) AS mat_ret7,

        SUM(CASE WHEN DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date THEN ret_14 ELSE 0 END) AS act_ret14,
        COUNT_IF(DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date) AS mat_ret14,

        SUM(CASE WHEN DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date THEN ret_30 ELSE 0 END) AS act_ret30,
        COUNT_IF(DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date) AS mat_ret30,

        SUM(CASE WHEN DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date THEN ret_60 ELSE 0 END) AS act_ret60,
        COUNT_IF(DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date) AS mat_ret60,

        SUM(CASE WHEN DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date THEN ret_90 ELSE 0 END) AS act_ret90,
        COUNT_IF(DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date) AS mat_ret90

    FROM UserRetentionAgg u
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
        COUNT_IF(is_paying = 1) AS paying_users,

        SUM(CASE WHEN DATE_ADD('day', 1,  cohort_date) <= sc.mature_end_date THEN ret_1  ELSE 0 END) AS act_ret1,
        COUNT_IF(DATE_ADD('day', 1,  cohort_date) <= sc.mature_end_date) AS mat_ret1,

        SUM(CASE WHEN DATE_ADD('day', 2,  cohort_date) <= sc.mature_end_date THEN ret_3  ELSE 0 END) AS act_ret3,
        COUNT_IF(DATE_ADD('day', 2,  cohort_date) <= sc.mature_end_date) AS mat_ret3,

        SUM(CASE WHEN DATE_ADD('day', 3,  cohort_date) <= sc.mature_end_date THEN ret_4  ELSE 0 END) AS act_ret4,
        COUNT_IF(DATE_ADD('day', 3,  cohort_date) <= sc.mature_end_date) AS mat_ret4,

        SUM(CASE WHEN DATE_ADD('day', 4,  cohort_date) <= sc.mature_end_date THEN ret_5  ELSE 0 END) AS act_ret5,
        COUNT_IF(DATE_ADD('day', 4,  cohort_date) <= sc.mature_end_date) AS mat_ret5,

        SUM(CASE WHEN DATE_ADD('day', 5,  cohort_date) <= sc.mature_end_date THEN ret_6  ELSE 0 END) AS act_ret6,
        COUNT_IF(DATE_ADD('day', 5,  cohort_date) <= sc.mature_end_date) AS mat_ret6,

        SUM(CASE WHEN DATE_ADD('day', 6,  cohort_date) <= sc.mature_end_date THEN ret_7  ELSE 0 END) AS act_ret7,
        COUNT_IF(DATE_ADD('day', 6,  cohort_date) <= sc.mature_end_date) AS mat_ret7,

        SUM(CASE WHEN DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date THEN ret_14 ELSE 0 END) AS act_ret14,
        COUNT_IF(DATE_ADD('day', 13, cohort_date) <= sc.mature_end_date) AS mat_ret14,

        SUM(CASE WHEN DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date THEN ret_30 ELSE 0 END) AS act_ret30,
        COUNT_IF(DATE_ADD('day', 29, cohort_date) <= sc.mature_end_date) AS mat_ret30,

        SUM(CASE WHEN DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date THEN ret_60 ELSE 0 END) AS act_ret60,
        COUNT_IF(DATE_ADD('day', 59, cohort_date) <= sc.mature_end_date) AS mat_ret60,

        SUM(CASE WHEN DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date THEN ret_90 ELSE 0 END) AS act_ret90,
        COUNT_IF(DATE_ADD('day', 89, cohort_date) <= sc.mature_end_date) AS mat_ret90

    FROM UserRetentionAgg u
    CROSS JOIN ScanConfig sc
    WHERE cohort_type IN ('new', 'return')
    GROUP BY 1
),

-- 10. 格式化最终输出报表 (% 留存率)
FinalOutput AS (
    SELECT
        time_dimension AS "时间维度",
        date_range AS "日期范围",
        CASE 
            WHEN cohort_type = 'new' THEN '1.新用户'
            WHEN cohort_type = 'return' THEN '2.回流用户(60天)'
            WHEN cohort_type = 'new+return' THEN '3.新用户+回流用户'
        END AS "用户类型",
        total_users AS "用户数",
        paying_users AS "付费用户数",
        date_gap AS "完整生命周期到第几天",

        -- 留存率 (%), 若无达标用户则输出 NULL
        ROUND(TRY(act_ret1  * 100.0 / NULLIF(mat_ret1,  0)), 2) AS "次留",
        ROUND(TRY(act_ret3  * 100.0 / NULLIF(mat_ret3,  0)), 2) AS "rr3",
        ROUND(TRY(act_ret4  * 100.0 / NULLIF(mat_ret4,  0)), 2) AS "rr4",
        ROUND(TRY(act_ret5  * 100.0 / NULLIF(mat_ret5,  0)), 2) AS "rr5",
        ROUND(TRY(act_ret6  * 100.0 / NULLIF(mat_ret6,  0)), 2) AS "rr6",
        ROUND(TRY(act_ret7  * 100.0 / NULLIF(mat_ret7,  0)), 2) AS "rr7",
        ROUND(TRY(act_ret14 * 100.0 / NULLIF(mat_ret14, 0)), 2) AS "rr14",
        ROUND(TRY(act_ret30 * 100.0 / NULLIF(mat_ret30, 0)), 2) AS "rr30",
        ROUND(TRY(act_ret60 * 100.0 / NULLIF(mat_ret60, 0)), 2) AS "rr60",
        ROUND(TRY(act_ret90 * 100.0 / NULLIF(mat_ret90, 0)), 2) AS "rr90"
    FROM CohortAggregation
)

SELECT * 
FROM FinalOutput
ORDER BY "时间维度" DESC, "用户类型";
