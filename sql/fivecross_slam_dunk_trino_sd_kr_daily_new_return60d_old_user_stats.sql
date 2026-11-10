/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计每日 新用户、老用户、回流用户（60天）的人数 (DAU) 与 收入 (人民币 RMB)
运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
  - 汇率表: ta_dim.ta_exchange
时间宏   : ${PartDate:date1} (适配数数后台自定义时间筛选)

核心更新说明:
  1. 新用户定义: 基于 '$part_event' = 'NUU' 事件判定用户的注册日期 (reg_date)。
  2. 性能优化: 自动扫描 ScanConfig 选定时间范围，提前预留 65 天历史日志做精准回流判定，避免无索引全表扫描。
  3. 用户分类定义 (互斥且完备):
     - 1. 新用户 (New Users)           : 当天触发 NUU 注册事件 (log_date = reg_date)
     - 2. 回流用户(60天) (Return Users) : 距上一次活跃日期 (prev_log_date) >= 60 天 (或距注册日 >= 60天)
     - 3. 老用户 (Existing Old Users)  : 距上一次活跃日期 (prev_log_date) < 60 天
================================================================================
*/

WITH ScanConfig AS (
    -- 1. [性能优化] 自动计算选定时间范围边界
    SELECT
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
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
    -- 3. 提取每日活跃日志 (向前预留 65 天历史日志以精确计算 60 天回流)
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

TargetDAU AS (
    -- 5. 划分选定时间范围内的活跃用户分类
    SELECT
        u.user_id,
        u.log_date,
        CASE
            WHEN u.log_date = u.first_log_date THEN '1.新用户'
            WHEN u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 60 THEN '2.回流用户(60天)'
            WHEN u.prev_log_date IS NULL AND DATE_DIFF('day', u.first_log_date, u.log_date) >= 60 THEN '2.回流用户(60天)'
            ELSE '3.老用户'
        END AS user_type
    FROM UserStatus u
    CROSS JOIN ScanConfig sc
    WHERE u.log_date BETWEEN sc.target_start_date AND sc.target_end_date
),

DailyRevenue AS (
    -- 6. 提取充值流水并转换为人民币 (RMB)
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
    LEFT JOIN ta_dim.ta_exchange ex
        ON r."$part_date" = ex.ex_date
       AND UPPER(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.cur')) = UPPER(ex.currency)
    LEFT JOIN ta_dim.ta_exchange cny
        ON r."$part_date" = cny.ex_date
       AND UPPER(cny.currency) = 'CNY'
    WHERE r."$part_event" = 'PURCHASE'
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND TRY_CAST(JSON_EXTRACT_SCALAR(CAST(r.payload AS JSON), '$.curamt') AS DOUBLE) > 0
      AND r."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND r."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND r."#account_id" IS NOT NULL
      AND r."#account_id" <> ''
    GROUP BY 1, 2
),

UserDailyStats AS (
    -- 7. 合并每日活跃与充值数据
    SELECT
        d.log_date AS stat_date,
        d.user_id,
        d.user_type,
        COALESCE(r.rev_rmb, 0.0) AS rev_rmb,
        CASE WHEN r.rev_rmb > 0 THEN 1 ELSE 0 END AS is_paying
    FROM TargetDAU d
    LEFT JOIN DailyRevenue r
        ON d.user_id = r.user_id
       AND d.log_date = r.pay_date
),

DailyAgg AS (
    -- 8. 按日期聚合各类型用户的人数与收入
    SELECT
        stat_date,
        -- 人数
        COUNT(DISTINCT CASE WHEN user_type = '1.新用户' THEN user_id END)       AS new_dau,
        COUNT(DISTINCT CASE WHEN user_type = '2.回流用户(60天)' THEN user_id END) AS return_dau,
        COUNT(DISTINCT CASE WHEN user_type = '3.老用户' THEN user_id END)     AS old_dau,
        COUNT(DISTINCT user_id)                                               AS total_dau,

        -- 收入 (RMB)
        SUM(CASE WHEN user_type = '1.新用户' THEN rev_rmb ELSE 0.0 END)       AS new_rev_rmb,
        SUM(CASE WHEN user_type = '2.回流用户(60天)' THEN rev_rmb ELSE 0.0 END) AS return_rev_rmb,
        SUM(CASE WHEN user_type = '3.老用户' THEN rev_rmb ELSE 0.0 END)     AS old_rev_rmb,
        SUM(rev_rmb)                                                          AS total_rev_rmb,

        -- 付费人数
        COUNT(DISTINCT CASE WHEN user_type = '1.新用户' AND is_paying = 1 THEN user_id END)       AS new_pu,
        COUNT(DISTINCT CASE WHEN user_type = '2.回流用户(60天)' AND is_paying = 1 THEN user_id END) AS return_pu,
        COUNT(DISTINCT CASE WHEN user_type = '3.老用户' AND is_paying = 1 THEN user_id END)     AS old_pu,
        COUNT(DISTINCT CASE WHEN is_paying = 1 THEN user_id END)                                  AS total_pu
    FROM UserDailyStats
    GROUP BY stat_date
)

-- 9. 宽表格式输出最终报表
SELECT
    CAST(stat_date AS VARCHAR) AS "日期",

    -- 人数 (DAU)
    new_dau AS "新用户人数",
    old_dau AS "老用户人数",
    return_dau AS "回流用户人数(60天)",
    total_dau AS "总活跃人数(DAU)",

    -- 收入 (RMB 人民币)
    ROUND(new_rev_rmb, 2) AS "新用户收入(RMB)",
    ROUND(old_rev_rmb, 2) AS "老用户收入(RMB)",
    ROUND(return_rev_rmb, 2) AS "回流用户收入(RMB)",
    ROUND(total_rev_rmb, 2) AS "总收入(RMB)",

    -- 收入占比 (%)
    -- ROUND(TRY(new_rev_rmb * 100.0 / NULLIF(total_rev_rmb, 0.0)), 2) AS "新用户收入占比(%)",
    -- ROUND(TRY(old_rev_rmb * 100.0 / NULLIF(total_rev_rmb, 0.0)), 2) AS "老用户收入占比(%)",
    -- ROUND(TRY(return_rev_rmb * 100.0 / NULLIF(total_rev_rmb, 0.0)), 2) AS "回流用户收入占比(%)",

    -- ARPU (RMB)
    ROUND(TRY(new_rev_rmb / NULLIF(new_dau, 0)), 2) AS "新用户ARPU(RMB)",
    ROUND(TRY(old_rev_rmb / NULLIF(old_dau, 0)), 2) AS "老用户ARPU(RMB)",
    ROUND(TRY(return_rev_rmb / NULLIF(return_dau, 0)), 2) AS "回流用户ARPU(RMB)",
    ROUND(TRY(total_rev_rmb / NULLIF(total_dau, 0)), 2) AS "总ARPU(RMB)"

FROM DailyAgg
ORDER BY stat_date DESC;

/*
-- 附录：如需长表格式 (按 日期 x 用户类型 拆分):
SELECT
    CAST(d.stat_date AS VARCHAR) AS "日期",
    d.user_type AS "用户类型",
    COUNT(DISTINCT d.user_id) AS "人数",
    ROUND(SUM(d.rev_rmb), 2) AS "收入(RMB)",
    COUNT(DISTINCT CASE WHEN d.is_paying = 1 THEN d.user_id END) AS "付费人数",
    ROUND(TRY(SUM(d.rev_rmb) / NULLIF(COUNT(DISTINCT d.user_id), 0)), 2) AS "ARPU(RMB)"
FROM UserDailyStats d
GROUP BY d.stat_date, d.user_type
ORDER BY d.stat_date DESC, d.user_type;
*/
