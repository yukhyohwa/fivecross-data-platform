/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region (Traditional Chinese)
OBT Date: 2024-03-27
Purpose : 开服首 30 日每日及汇总指标分析 (DAU, DNU, ARPU, Retention, LTV)
Environment: MaxCompute (ODPS)
Optimizations:
    1. 显式在每个 CTE 中应用 `day` 分区键过滤，确保命中分区，避免全表扫描错误。
    2. 使用 app_id = '65002007' (以字符串形式引用，适配常见的字符串分区类型)。
    3. 移除 Cartesian Product (笛卡尔积) 逻辑，直接引用常量。
================================================================================
*/

-- @set odps.sql.type.system.odps2=true;

WITH CohortBase AS (
    -- 1. 确定公测首 30 日注册的目标用户 (这里必须显式指定 `day` 分区范围)
    SELECT DISTINCT
        lcm_id,
        reg_day,
        TO_DATE(CAST(reg_day AS STRING), 'yyyymmdd') AS reg_date,
        CASE 
            WHEN LOWER(os) LIKE '%android%' THEN 'Android'
            WHEN LOWER(os) LIKE '%ios%' THEN 'iOS'
            ELSE 'Others'
        END AS os_group
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = '65002007'
      AND `day` BETWEEN 20240327 AND 20240425 -- 显式、直接的分区过滤
      AND reg_day = `day` -- 业务逻辑：注册日期等于当天的记录为新增记录
),

DailyData AS (
    -- 2. 提取所有后续活跃和付费数据 (显式指定分区过滤起始点)
    SELECT 
        lcm_id,
        `day` as login_day,
        TO_DATE(CAST(`day` AS STRING), 'yyyymmdd') AS day_date,
        purchase AS revenue_amt
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = '65002007'
      AND `day` >= 20240327 -- 显式分区过滤，从开服日起
),

DailyMetricsRaw AS (
    -- 3. 基础指标计算
    SELECT 
        d.login_day,
        c.os_group,
        COUNT(DISTINCT d.lcm_id) AS dau,
        COUNT(DISTINCT CASE WHEN c.reg_day = d.login_day THEN d.lcm_id END) AS dnu,
        COUNT(DISTINCT CASE WHEN d.revenue_amt > 0 THEN d.lcm_id END) AS dau_pu,
        SUM(d.revenue_amt) AS daily_revenue
    FROM DailyData d
    INNER JOIN CohortBase c ON d.lcm_id = c.lcm_id
    GROUP BY d.login_day, c.os_group
),

CohortMetricsRaw AS (
    -- 4. 留存与 LTV 计算 (基于 Cohort)
    SELECT 
        c.reg_day,
        c.os_group,
        COUNT(DISTINCT c.lcm_id) AS new_users,
        -- 留存核心逻辑
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 1 THEN d.lcm_id END) AS ret_1,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 2 THEN d.lcm_id END) AS ret_2,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 3 THEN d.lcm_id END) AS ret_3,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 4 THEN d.lcm_id END) AS ret_4,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 5 THEN d.lcm_id END) AS ret_5,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 6 THEN d.lcm_id END) AS ret_6,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 7 THEN d.lcm_id END) AS ret_7,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 14 THEN d.lcm_id END) AS ret_14,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 30 THEN d.lcm_id END) AS ret_30,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 60 THEN d.lcm_id END) AS ret_60,
        COUNT(DISTINCT CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 90 THEN d.lcm_id END) AS ret_90,
        -- LTV 核心逻辑
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') = 0 THEN d.revenue_amt ELSE 0 END) AS rev_1,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 1 THEN d.revenue_amt ELSE 0 END) AS rev_2,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 2 THEN d.revenue_amt ELSE 0 END) AS rev_3,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 3 THEN d.revenue_amt ELSE 0 END) AS rev_4,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 4 THEN d.revenue_amt ELSE 0 END) AS rev_5,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 5 THEN d.revenue_amt ELSE 0 END) AS rev_6,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 6 THEN d.revenue_amt ELSE 0 END) AS rev_7,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 13 THEN d.revenue_amt ELSE 0 END) AS rev_14,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 29 THEN d.revenue_amt ELSE 0 END) AS rev_30,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 59 THEN d.revenue_amt ELSE 0 END) AS rev_60,
        SUM(CASE WHEN DATEDIFF(d.day_date, c.reg_date, 'dd') <= 89 THEN d.revenue_amt ELSE 0 END) AS rev_90
    FROM CohortBase c
    LEFT JOIN DailyData d ON c.lcm_id = d.lcm_id
    GROUP BY c.reg_day, c.os_group
)

-- 5. 组装输出
SELECT 
    '每日详情' AS report_type,
    d.login_day AS day_val,
    d.os_group,
    d.dau,
    d.dnu,
    ROUND(d.daily_revenue, 2) AS revenue,
    ROUND(d.daily_revenue / NULLIF(d.dau, 0), 2) AS arpu,
    ROUND(d.daily_revenue / NULLIF(d.dau_pu, 0), 2) AS arppu,
    ROUND(CAST(d.dau_pu AS DOUBLE) / NULLIF(d.dau, 0), 4) AS pay_rate,
    ROUND(CAST(c.ret_1 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_1,
    ROUND(CAST(c.ret_2 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_2,
    ROUND(CAST(c.ret_3 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_3,
    ROUND(CAST(c.ret_4 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_4,
    ROUND(CAST(c.ret_5 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_5,
    ROUND(CAST(c.ret_6 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_6,
    ROUND(CAST(c.ret_7 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_7,
    ROUND(CAST(c.ret_14 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_14,
    ROUND(CAST(c.ret_30 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_30,
    ROUND(CAST(c.ret_60 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_60,
    ROUND(CAST(c.ret_90 AS DOUBLE) / NULLIF(c.new_users, 0), 4) AS rr_90,
    ROUND(c.rev_1 / NULLIF(c.new_users, 0), 2) AS ltv_1,
    ROUND(c.rev_2 / NULLIF(c.new_users, 0), 2) AS ltv_2,
    ROUND(c.rev_3 / NULLIF(c.new_users, 0), 2) AS ltv_3,
    ROUND(c.rev_4 / NULLIF(c.new_users, 0), 2) AS ltv_4,
    ROUND(c.rev_5 / NULLIF(c.new_users, 0), 2) AS ltv_5,
    ROUND(c.rev_6 / NULLIF(c.new_users, 0), 2) AS ltv_6,
    ROUND(c.rev_7 / NULLIF(c.new_users, 0), 2) AS ltv_7,
    ROUND(c.rev_14 / NULLIF(c.new_users, 0), 2) AS ltv_14,
    ROUND(c.rev_30 / NULLIF(c.new_users, 0), 2) AS ltv_30,
    ROUND(c.rev_60 / NULLIF(c.new_users, 0), 2) AS ltv_60,
    ROUND(c.rev_90 / NULLIF(c.new_users, 0), 2) AS ltv_90
FROM DailyMetricsRaw d
JOIN CohortMetricsRaw c ON d.login_day = c.reg_day AND d.os_group = c.os_group

UNION ALL

-- 开服首 30 日整体汇总行
SELECT 
    '30日汇总' AS report_type,
    20240327 AS day_val, -- 使用 OBT 首日代表汇总周期
    os_group,
    NULL AS dau,
    SUM(new_users) AS dnu,
    ROUND(SUM(rev_30), 2) AS revenue,
    ROUND(SUM(rev_30) / NULLIF(SUM(new_users), 0), 2) AS arpu,
    NULL AS arppu,
    NULL AS pay_rate,
    ROUND(SUM(ret_1) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_1,
    ROUND(SUM(ret_2) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_2,
    ROUND(SUM(ret_3) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_3,
    ROUND(SUM(ret_4) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_4,
    ROUND(SUM(ret_5) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_5,
    ROUND(SUM(ret_6) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_6,
    ROUND(SUM(ret_7) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_7,
    ROUND(SUM(ret_14) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_14,
    ROUND(SUM(ret_30) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_30,
    ROUND(SUM(ret_60) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_60,
    ROUND(SUM(ret_90) / CAST(NULLIF(SUM(new_users), 0) AS DOUBLE), 4) AS rr_90,
    ROUND(SUM(rev_1) / NULLIF(SUM(new_users), 0), 2) AS ltv_1,
    ROUND(SUM(rev_2) / NULLIF(SUM(new_users), 0), 2) AS ltv_2,
    ROUND(SUM(rev_3) / NULLIF(SUM(new_users), 0), 2) AS ltv_3,
    ROUND(SUM(rev_4) / NULLIF(SUM(new_users), 0), 2) AS ltv_4,
    ROUND(SUM(rev_5) / NULLIF(SUM(new_users), 0), 2) AS ltv_5,
    ROUND(SUM(rev_6) / NULLIF(SUM(new_users), 0), 2) AS ltv_6,
    ROUND(SUM(rev_7) / NULLIF(SUM(new_users), 0), 2) AS ltv_7,
    ROUND(SUM(rev_14) / NULLIF(SUM(new_users), 0), 2) AS ltv_14,
    ROUND(SUM(rev_30) / NULLIF(SUM(new_users), 0), 2) AS ltv_30,
    ROUND(SUM(rev_60) / NULLIF(SUM(new_users), 0), 2) AS ltv_60,
    ROUND(SUM(rev_90) / NULLIF(SUM(new_users), 0), 2) AS ltv_90
FROM CohortMetricsRaw
GROUP BY os_group

ORDER BY report_type DESC, day_val ASC, os_group ASC;
