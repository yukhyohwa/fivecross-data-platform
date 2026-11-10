/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese)
Description: 回流用户 (RUU) 核心 KPI 报表 (回流留存, 回流 LTV, 转化)
             1. 定义回流：由于离线 30 天以上重新登录的用户。
             2. 统计回流后的留存 (次留-30留) 与 LTV (1-30)。
             3. 使用【用户标签】加速方案确定维度与注册背景。
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. [性能优化] 自动计算扫描边界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date,
        -- 往前追溯 60 天作为扫描起点，确保能判定 30 天的回流间隙
        DATE_ADD('day', -60, MIN(CAST("$part_date" AS DATE))) AS scan_start_date,
        MAX(CAST("$part_date" AS DATE)) AS scan_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1} AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 内部用户名单 (黑名单)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users')
),

-- 3. 用户标签与基础信息
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_16 
    WHERE cluster_name IN ('fixed_country', 'fixed_os', 'fixed_store', 'fixed_affcode', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 4. 基础登录去重
UserDailyLogin AS (
    SELECT 
        v."#account_id", 
        v."$part_date"
    FROM ta.v_event_16 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND CAST(v."$part_date" AS DATE) BETWEEN sc.scan_start_date AND sc.scan_end_date
      AND ub."#account_id" IS NULL -- 排除内部号
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
        s.login_date > CAST(up.fixed_regdate AS DATE) -- 必须是注册日期之后发生的登录
        AND (
            (
                s.prev_login_date IS NOT NULL 
                AND DATE_DIFF('day', s.prev_login_date, s.login_date) >= 30 -- 离线 30 天回流
            )
            OR 
            (
                s.prev_login_date IS NULL 
                AND CAST(up.fixed_regdate AS DATE) <= DATE_ADD('day', -30, s.login_date) -- 注册后 30 天才首次回来
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
    WHERE ${PartDate:date1} 
),

-- 7. 回流后留存
ReturneeRetention AS (
    SELECT 
        tru."#account_id",
        tru.return_date,
        ARRAY_AGG(DISTINCT DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE))) AS retention_days_array
    FROM TargetReturnUsers tru
    JOIN ta.v_event_16 v ON tru."#account_id" = v."#account_id"
    WHERE v."$part_date" >= CAST(tru.return_date AS VARCHAR)
      AND v."$part_event" IN ('LOGIN_SUCCESS')
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
            ) THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1)
            ELSE 0 END) AS rev_period,

        -- [固定天数] LTV 序列
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 1 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) ELSE 0 END) AS rev_1,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 2 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) ELSE 0 END) AS rev_2,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 3 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) ELSE 0 END) AS rev_3,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 7 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) ELSE 0 END) AS rev_7,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 14 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) ELSE 0 END) AS rev_14,
        SUM(CASE WHEN DATE_DIFF('day', tru.return_date, CAST(v."$part_date" AS DATE)) < 30 THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) ELSE 0 END) AS rev_30
    FROM TargetReturnUsers tru
    JOIN ta.v_event_16 v ON tru."#account_id" = v."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    WHERE v."$part_date" >= CAST(tru.return_date AS VARCHAR)
      AND v."$part_event" = 'PURCHASE'
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
    END AS "时间维度",
    CASE WHEN ${Selector:ostype} THEN p1.fixed_os ELSE '已合并' END AS "OS",
    CASE WHEN ${Selector:country} THEN p1.fixed_country ELSE '已合并' END AS "地区", 
    CASE WHEN ${Selector:affcode} THEN p1.fixed_affcode ELSE '已合并' END AS "渠道",
    CASE WHEN ${Selector:store} THEN p1.fixed_store ELSE '已合并' END AS "商店",  
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

    COUNT(DISTINCT p1."#account_id") AS "回流人数(RUU)",
    
    -- 回流用户核心转化指标
    COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#account_id" END) AS "回流付费人数",
    CAST(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#account_id" END) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流付费率",
    ROUND(SUM(r_ltv.rev_period), 2) AS "回流流水(USD)",
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流ARPU",
    SUM(r_ltv.rev_period) / NULLIF(COUNT(DISTINCT CASE WHEN r_ltv.rev_period > 0 THEN p1."#account_id" END), 0) AS "回流ARPPU",

    -- 留存指标
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 1)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流次留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 2)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流D2留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 3)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流D3留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 6)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流D7留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 13)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流D14留",
    CAST(COUNT_IF(CONTAINS(r_ret.retention_days_array, 29)) AS DOUBLE) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0) AS "回流D30留",

    -- LTV 指标
    COALESCE(SUM(r_ltv.rev_1) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS "回流LTV_1",
    COALESCE(SUM(r_ltv.rev_2) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS "回流LTV_2",
    COALESCE(SUM(r_ltv.rev_3) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS "回流LTV_3",
    COALESCE(SUM(r_ltv.rev_7) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS "回流LTV_7",
    COALESCE(SUM(r_ltv.rev_14) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS "回流LTV_14",
    COALESCE(SUM(r_ltv.rev_30) / NULLIF(COUNT(DISTINCT p1."#account_id"), 0), 0) AS "回流LTV_30"

FROM TargetReturnUsers p1
CROSS JOIN ScanConfig sc
LEFT JOIN ReturneeRetention r_ret ON p1."#account_id" = r_ret."#account_id" AND p1.return_date = r_ret.return_date
LEFT JOIN ReturneeLtvStats r_ltv ON p1."#account_id" = r_ltv."#account_id" AND p1.return_date = r_ltv.return_date
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC;
