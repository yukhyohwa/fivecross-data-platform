/*
================================================================================
Game: New Three Kingdoms (NTK) - GL
Description: Return User (RUU) KPI & LTV analysis script for New Three Kingdoms.
             Detects users returning after 30+ days of inactivity.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH
-- 1. 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date,
        -- 往前追溯 60 天作为扫描起点
        DATE_ADD('day', -60, MIN(CAST("$part_date" AS DATE))) AS scan_start_date,
        MAX(CAST("$part_date" AS DATE)) AS scan_end_date
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
),

-- 2. 用户标签与基础信息 (切换至 19)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('fixed_country', 'fixed_os', 'fixed_store', 'fixed_affcode', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 2.5 黑名单用户 (切换至 19)
UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),

-- 4. 基础登录去重
UserDailyLogin AS (
    SELECT 
        v."#account_id", 
        v."$part_date"
    FROM ta.v_event_19 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(v."$part_date" AS DATE) BETWEEN sc.scan_start_date AND sc.scan_end_date
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2
),

UserLoginSequence AS (
    SELECT 
        "#account_id",
        "$part_date", 
        CAST("$part_date" AS DATE) AS login_date,
        LAG(CAST("$part_date" AS DATE)) OVER (PARTITION BY "#account_id" ORDER BY "$part_date" ASC) AS prev_login_date
    FROM UserDailyLogin
),

-- 5. 判定回流行为 (RUU)
ReturnEvents AS (
    SELECT 
        s."#account_id",
        s."$part_date", 
        s.login_date AS return_date,
        s.prev_login_date,
        up.fixed_regdate
    FROM UserLoginSequence s
    INNER JOIN UserProfileDetail up ON s."#account_id" = up."#account_id"
    WHERE 
        s.login_date > CAST(up.fixed_regdate AS DATE)
        AND (
            (
                s.prev_login_date IS NOT NULL 
                AND DATE_DIFF('day', s.prev_login_date, s.login_date) >= 30
            )
            OR 
            (
                s.prev_login_date IS NULL 
                AND CAST(up.fixed_regdate AS DATE) <= DATE_ADD('day', -30, s.login_date)
            )
        )
),

-- 6. 锁定目标日期窗口内的回流动作
TargetReturnUsers AS (
    SELECT 
        re."#account_id",
        re.return_date,
        up.fixed_os,
        up.fixed_country,
        up.fixed_store,
        up.fixed_affcode
    FROM ReturnEvents re
    LEFT JOIN UserProfileDetail up ON re."#account_id" = up."#account_id"
    LEFT JOIN UserBlacklist ub ON re."#account_id" = ub."#account_id"
    WHERE ${PartDate:date1} 
      AND ub."#account_id" IS NULL
),

-- 7. 回流后留存
ReturneeRetention AS (
    SELECT 
        tru."#account_id",
        tru.return_date,
        ARRAY_AGG(DISTINCT DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE))) AS retention_days_array
    FROM TargetReturnUsers tru
    JOIN ta.v_event_19 v ON tru."#account_id" = v."#account_id"
    WHERE v."$part_date" >= CAST(tru.return_date AS VARCHAR)
      AND v."$part_event" IN ('LOGIN_SUCCESS')
      -- [项目识别]
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2
),

-- 8. 回流用户 LTV 及 周期转化计算
ReturneeLtvStats AS (
    SELECT 
        tru."#account_id",
        tru.return_date,
        
        -- [周期自适应] 不同维度下的累计付费人数与金额
        SUM(CASE 
            WHEN (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', tru.return_date) = DATE_TRUNC('day', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', tru.return_date) = DATE_TRUNC('week', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', tru.return_date) = DATE_TRUNC('month', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', tru.return_date) = DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE))) OR
                (${Selector:timetype} = 'A') 
            ) THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange 
            ELSE 0 END) AS rev_period,

        -- [固定天数] LTV 序列
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 1 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_1,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 2 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_2,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 3 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_3,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 4 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_4,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 5 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_5,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 6 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_6,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 7 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_7,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 14 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_14,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 30 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / s5.exchange * s_cny.exchange ELSE 0 END) AS rev_30
    FROM TargetReturnUsers tru
    JOIN ta.v_event_19 v ON tru."#account_id" = v."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN ta_dim.ta_exchange s_cny ON v."$part_date" = s_cny.ex_date AND s_cny.currency = 'CNY'
    WHERE v."$part_date" >= CAST(tru.return_date AS VARCHAR)
      AND v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      -- [项目识别]
      AND (
           v.applicationid IN ('65002004') 
        OR v.productid IN ('65002004') 
        OR regexp_extract(v.lcxproductid, 'g(\d+)', 1) IN ('65002004')
        OR substring(v.affcode, -8) IN ('65002004') 
        OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('65002004')
      )
    GROUP BY 1, 2
)

-- 9. 最终汇总报表
SELECT
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', p1.return_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '已合并'
    END AS time_dimension,
    CASE WHEN ${Selector:ostype} THEN p1.fixed_os ELSE '已合并' END os_type,
    CASE WHEN ${Selector:country} THEN p1.fixed_country ELSE '已合并' END country, 
    CASE WHEN ${Selector:affcode} THEN p1.fixed_affcode ELSE '已合并' END affcode,
    CASE WHEN ${Selector:store} THEN p1.fixed_store ELSE '已合并' END store,  
    MAX(CONCAT(
        CAST(GREATEST(
            CASE 
                WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', p1.return_date)
                WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', p1.return_date)
                WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', p1.return_date)
                WHEN ${Selector:timetype} = 'S' THEN DATE_TRUNC('quarter', p1.return_date)
                WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                ELSE p1.return_date
            END, 
            sc.target_start_date
        ) AS VARCHAR),
        ' ~ ',
        CAST(LEAST(
            CASE 
                WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', p1.return_date)
                WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', p1.return_date))
                WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', p1.return_date)))
                WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, DATE_TRUNC('quarter', p1.return_date)))
                WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                ELSE p1.return_date
            END,
            sc.target_end_date
        ) AS VARCHAR)
    )) AS "日期范围",

    COUNT(DISTINCT p1."#account_id") AS ruu,
    
    -- 回流用户核心转化指标 (自适应统计周期)
    COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#account_id" END) AS ruu_paying_users,
    CAST(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#account_id" END) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS ruu_pay_rate,
    SUM(r_ltv.rev_period) ruu_revenue,
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS ruu_arpu,
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#account_id" END), 0) AS ruu_arppu,

    -- 留存指标
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 0)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_1,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_2,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_3,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_4,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 4)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_5,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 5)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_6,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_7,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_14,
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS rr_30,

    -- LTV 指标
    COALESCE(SUM(r_ltv.rev_1) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_1,
    COALESCE(SUM(r_ltv.rev_2) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_2,
    COALESCE(SUM(r_ltv.rev_3) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_3,
    COALESCE(SUM(r_ltv.rev_4) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_4,
    COALESCE(SUM(r_ltv.rev_5) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_5,
    COALESCE(SUM(r_ltv.rev_6) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_6,
    COALESCE(SUM(r_ltv.rev_7) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_7,
    COALESCE(SUM(r_ltv.rev_14) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_14,
    COALESCE(SUM(r_ltv.rev_30) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS ltv_30

FROM TargetReturnUsers p1
CROSS JOIN ScanConfig sc
LEFT JOIN ReturneeRetention r_ret ON p1."#account_id" = r_ret."#account_id" AND p1.return_date = r_ret.return_date
LEFT JOIN ReturneeLtvStats r_ltv ON p1."#account_id" = r_ltv."#account_id" AND p1.return_date = r_ltv.return_date
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC;
