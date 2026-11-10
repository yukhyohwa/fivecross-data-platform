-- =================================================================================
-- 目的：对比 蜡笔小新（13项目）中 菇勇者用户（is_lom=Y）与 非菇勇者用户 的核心数据
-- 指标包含：次留、3留、LTV1-3、D+0~D+2平均在线时长、加权日ARPU、加权日付费率
-- =================================================================================

WITH new_roles AS (
    -- 1. 圈定 2026-05-08 至 2026-05-10 期间注册的新角色，并标记是否为菇勇者
    SELECT 
        DISTINCT v."#user_id",
        DATE(v."$part_date") AS reg_date,
        CASE WHEN lm."#account_id@lom" = 'A' THEN 'Y' ELSE 'N' END AS is_lom
    FROM ta.v_event_13 v
    INNER JOIN ta_dim.dim_13_0_18164 lm 
        ON v."#account_id" = lm."#account_id@role_id"
    WHERE v."$part_date" BETWEEN '2026-05-08' AND '2026-05-10'
      AND v."$part_event" = 'new_role'
),

-- 2. 提取这些用户在回访周期内的所有非应用层事件，计算每次操作与下一次操作的时间差（心跳法计算时长）
user_logs AS (
    SELECT 
        v."#user_id",
        DATE(v."$part_date") AS event_date,
        LEAD(to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))) OVER (
            PARTITION BY v."#user_id", v."$part_date"
            ORDER BY v."#event_time"
        ) 
        - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) AS gap
    FROM ta.v_event_13 v
    INNER JOIN new_roles n ON v."#user_id" = n."#user_id"
    WHERE v."$part_date" BETWEEN '2026-05-08' AND '2026-05-14'
      AND v."#event_name" NOT LIKE '%snapshot%'
),

-- 3. 按人按日汇总当天的总时长（间距小于 120 秒累加）
user_daily_duration AS (
    SELECT 
        "#user_id",
        event_date,
        SUM(CASE WHEN gap < 120 THEN gap ELSE 0 END) AS daily_online_time
    FROM user_logs
    GROUP BY 1, 2
),

-- 4. 提取充值数据（真实事件为 charge，字段为 pay_amount_usd）
user_daily_charge AS (
    SELECT 
        v."#user_id",
        DATE(v."$part_date") AS event_date,
        SUM(TRY_CAST(v.pay_amount_usd AS DOUBLE)) AS daily_revenue
    FROM ta.v_event_13 v
    INNER JOIN new_roles n ON v."#user_id" = n."#user_id"
    WHERE v."$part_date" BETWEEN '2026-05-08' AND '2026-05-14'
      AND v."$part_event" = 'charge'
    GROUP BY 1, 2
),

-- 5. 合并每天活跃和充值状态
-- 若有产生时长，或有充值，或只上了线没时长，都视作当日活跃
daily_active_dates AS (
    SELECT DISTINCT "#user_id", DATE("$part_date") AS event_date
    FROM ta.v_event_13
    WHERE "$part_date" BETWEEN '2026-05-08' AND '2026-05-14'
     AND  "$part_event" IN ('login','new_role')
),

agg_base AS (
    SELECT 
        n.is_lom,
        n."#user_id",
        n.reg_date,
        a.event_date,
        date_diff('day', n.reg_date, a.event_date) AS diff_days,
        COALESCE(d.daily_online_time, 0) AS daily_online_time,
        COALESCE(c.daily_revenue, 0.0) AS daily_revenue,
        CASE WHEN c.daily_revenue > 0 THEN 1 ELSE 0 END AS is_pay
    FROM new_roles n
    INNER JOIN daily_active_dates a ON n."#user_id" = a."#user_id"
    LEFT JOIN user_daily_duration d ON n."#user_id" = d."#user_id" AND a.event_date = d.event_date
    LEFT JOIN user_daily_charge c ON n."#user_id" = c."#user_id" AND a.event_date = c.event_date
),

agg_metrics AS (
    SELECT 
        is_lom,
        COUNT(DISTINCT "#user_id") AS new_user_cnt,
        
        -- 留存人数
        COUNT(DISTINCT CASE WHEN diff_days = 0 THEN "#user_id" END) AS ret_d0_cnt,
        COUNT(DISTINCT CASE WHEN diff_days = 1 THEN "#user_id" END) AS ret_d1_cnt,
        COUNT(DISTINCT CASE WHEN diff_days = 2 THEN "#user_id" END) AS ret_d2_cnt,
        COUNT(DISTINCT CASE WHEN diff_days = 3 THEN "#user_id" END) AS ret_d3_cnt,
        COUNT(DISTINCT CASE WHEN diff_days = 4 THEN "#user_id" END) AS ret_d4_cnt,
        COUNT(DISTINCT CASE WHEN diff_days = 5 THEN "#user_id" END) AS ret_d5_cnt,
        COUNT(DISTINCT CASE WHEN diff_days = 6 THEN "#user_id" END) AS ret_d6_cnt,
        
        -- 分母（有资格到达该天数的人）
        -- 这里假设结束统计日期为 2026-05-14
        COUNT(DISTINCT CASE WHEN date_diff('day', reg_date, DATE '2026-05-14') >= 1 THEN "#user_id" END) AS base_d1_cnt,
        COUNT(DISTINCT CASE WHEN date_diff('day', reg_date, DATE '2026-05-14') >= 2 THEN "#user_id" END) AS base_d2_cnt,
        COUNT(DISTINCT CASE WHEN date_diff('day', reg_date, DATE '2026-05-14') >= 3 THEN "#user_id" END) AS base_d3_cnt,
        COUNT(DISTINCT CASE WHEN date_diff('day', reg_date, DATE '2026-05-14') >= 4 THEN "#user_id" END) AS base_d4_cnt,
        COUNT(DISTINCT CASE WHEN date_diff('day', reg_date, DATE '2026-05-14') >= 5 THEN "#user_id" END) AS base_d5_cnt,
        COUNT(DISTINCT CASE WHEN date_diff('day', reg_date, DATE '2026-05-14') >= 6 THEN "#user_id" END) AS base_d6_cnt,
        
        -- LTV 分子
        SUM(CASE WHEN diff_days = 0 THEN daily_revenue ELSE 0 END) AS rev_d0,
        SUM(CASE WHEN diff_days <= 1 THEN daily_revenue ELSE 0 END) AS rev_d01,
        SUM(CASE WHEN diff_days <= 2 THEN daily_revenue ELSE 0 END) AS rev_d012,
        
        -- 时长分子（累计秒数）和分母（有在线时长记录的人）
        COUNT(DISTINCT CASE WHEN diff_days = 0 AND daily_online_time > 0 THEN "#user_id" END) AS active_d0_cnt,
        SUM(CASE WHEN diff_days = 0 THEN daily_online_time ELSE 0 END) AS duration_d0,
        
        COUNT(DISTINCT CASE WHEN diff_days = 1 AND daily_online_time > 0 THEN "#user_id" END) AS active_d1_cnt,
        SUM(CASE WHEN diff_days = 1 THEN daily_online_time ELSE 0 END) AS duration_d1,
        
        COUNT(DISTINCT CASE WHEN diff_days = 2 AND daily_online_time > 0 THEN "#user_id" END) AS active_d2_cnt,
        SUM(CASE WHEN diff_days = 2 THEN daily_online_time ELSE 0 END) AS duration_d2,
        
        -- 加权 ARPU / 付费率
        COUNT(DISTINCT CAST("#user_id" AS VARCHAR) || CAST(event_date AS VARCHAR)) AS total_active_days, 
        SUM(daily_revenue) AS total_revenue,
        SUM(is_pay) AS total_pay_days
    FROM agg_base
    GROUP BY 1
)

SELECT 
    is_lom,
    new_user_cnt AS "新增人数",
    TRY(CAST(ret_d0_cnt AS DOUBLE) / new_user_cnt) AS "首日活跃率",
    TRY(CAST(ret_d1_cnt AS DOUBLE) / NULLIF(base_d1_cnt, 0)) AS "次留",
    TRY(CAST(ret_d2_cnt AS DOUBLE) / NULLIF(base_d2_cnt, 0)) AS "3留(rr2)",
    TRY(CAST(ret_d3_cnt AS DOUBLE) / NULLIF(base_d3_cnt, 0)) AS "4留(rr3)",
    TRY(CAST(ret_d4_cnt AS DOUBLE) / NULLIF(base_d4_cnt, 0)) AS "5留(rr4)",
    TRY(CAST(ret_d5_cnt AS DOUBLE) / NULLIF(base_d5_cnt, 0)) AS "6留(rr5)",
    TRY(CAST(ret_d6_cnt AS DOUBLE) / NULLIF(base_d6_cnt, 0)) AS "7留(rr6)",
    
    TRY(rev_d0 / new_user_cnt) AS "ltv1",
    TRY(rev_d01 / new_user_cnt) AS "ltv2",
    TRY(rev_d012 / new_user_cnt) AS "ltv3",
    
    -- 输出平均在线时长（转换为分钟）
    TRY((duration_d0 / 60.0) / active_d0_cnt) AS "d+0 平均在线时长(分钟)",
    TRY((duration_d1 / 60.0) / active_d1_cnt) AS "d+1 平均在线时长(分钟)",
    TRY((duration_d2 / 60.0) / active_d2_cnt) AS "d+2 平均在线时长(分钟)",
    
    TRY(total_revenue / total_active_days) AS "加权日arpu",
    TRY(CAST(total_pay_days AS DOUBLE) / total_active_days) AS "加权日付费率"
FROM agg_metrics
ORDER BY is_lom;
