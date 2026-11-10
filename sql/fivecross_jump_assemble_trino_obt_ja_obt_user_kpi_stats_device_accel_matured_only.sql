/*
================================================================================
Game    : Jump Assemble
Region  : TC (Traditional Chinese - TW/HK/MO)
Description: 核心 KPI 报表 (LTV, 留存, 收入) - 使用【设备 ID】加速且仅统计生命周期达标（Matured）设备方案
             1. 使用 UserProfileDetail (来自 user_result_cluster_23) 确定注册日期、设备ID和维度的系统/地区/渠道属性。
             2. 以 fixed_deviceid 作为统计 NUU 和 AU 的去重标准（空设备 ID 映射为 CONCAT('unknown_', "#account_id") 虚拟唯一化）。
             3. 包含 LTV (1-360) 和 留存 (次留-360留) 以及 一阶/二阶登录比率。
             4. 周期自适应：支持日、周、月、季度、合并全部维度聚合。支持系统、国家地区、渠道的自定义拆分选择。
             5. 仅统计对应天数生命周期已达标（Matured）的设备分母，消除近期注册设备对长期指标的拉低与稀释。
             6. 修正：留存 / LTV 的观察截止日使用 current_date - 1，不再使用筛选结束日。
             7. 新增：D8留存 / LTV_8，作为验证字段。
================================================================================
*/

WITH
-- 1. [性能优化] 自动计算扫描边界
-- target_start_date / target_end_date：报表筛选窗口，例如 2026-06-24 ~ 2026-06-28
-- mature_end_date：留存 / LTV 的真实观察截止日，例如 current_date - 1
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date,
        DATE_ADD('day', -1, CURRENT_DATE) AS mature_end_date
    FROM ta.v_event_23
    WHERE ${PartDate:date1} 
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 黑名单用户
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS "#account_id"
    FROM user_result_cluster_23
    WHERE cluster_name IN ( ${Selector:selector2} ) --'internal_users',
),

-- 3. 用户标签数据表
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE 
            WHEN cluster_name = 'fixed_country' THEN 
                CASE 
                    WHEN tag_value IN ('中国', '中国大陆', 'CN') THEN '中国大陆'
                    WHEN tag_value IN ('台湾', '香港', '澳门', '中国台湾', '中国香港', '中国澳门', 'TW', 'HK', 'MO', '台港澳') THEN '台港澳'
                    ELSE '其他国家'
                END
        END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode'  THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'       THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid 
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_regdate', 'fixed_deviceid')
    GROUP BY "#varchar_id"
),

-- 3b. 映射设备基本属性
DeviceProfile AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), CONCAT('unknown_', "#account_id")) AS device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type,
        MAX(fixed_country) AS country,
        MAX(fixed_affcode) AS affcode
    FROM UserProfileDetail
    GROUP BY 1
),

-- 3c. 黑名单设备
DeviceBlacklist AS (
    SELECT DISTINCT 
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) AS device_id
    FROM UserBlacklist ub
    INNER JOIN UserProfileDetail s4 
        ON ub."#account_id" = s4."#account_id"
),

-- 4. 设备活跃序列
DeviceRetentionArrays AS (
    SELECT 
        s1.device_id, 
        s2.reg_date,  
        TRANSFORM(
            ARRAY_SORT(s1.return_date_array), 
            d -> DATE_DIFF('day', CAST(s2.reg_date AS DATE), d)
        ) AS return_days_array
    FROM (
        SELECT 
            COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#account_id")) AS device_id, 
            ARRAY_AGG(DISTINCT CAST(v."$part_date" AS DATE)) AS return_date_array
        FROM ta.v_event_23 v
        CROSS JOIN ScanConfig sc
        LEFT JOIN UserProfileDetail s4 
            ON v."#account_id" = s4."#account_id"
        WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
          AND v."$part_date" <= CAST(sc.mature_end_date AS VARCHAR)
          AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
        GROUP BY 1
    ) s1
    INNER JOIN DeviceProfile s2 
        ON s1.device_id = s2.device_id
),

-- 5. 每日设备净收入明细
DailyDeviceRevenue AS (
    SELECT
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#account_id")) AS device_id,
        v."$part_date",
        SUM(
            CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) 
            / COALESCE(s5.exchange, 1)
        ) AS revenue_usd
    FROM ta.v_event_23 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserProfileDetail s4 
        ON v."#account_id" = s4."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    WHERE v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.mature_end_date AS VARCHAR)
      AND v."$part_event" IN ('PURCHASE')
      AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
    GROUP BY 1, 2
),

-- 6. 设备 LTV 映射表
DeviceLtvMap AS (
    SELECT
        s2.device_id,
        MAP_AGG(
            DATE_DIFF('day', CAST(s2.reg_date AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_usd                                                               
        ) AS revenue_map
    FROM DailyDeviceRevenue s1
    INNER JOIN DeviceProfile s2 
        ON s1.device_id = s2.device_id
    GROUP BY 1
),

-- 7. 留存率计算指标
NewAccountRR AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,

        CASE WHEN ${Selector:ostype} THEN s1.os_type ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN COALESCE(s1.country, '其他国家') ELSE '已合并' END AS country, 
        CASE WHEN ${Selector:affcode} THEN s1.affcode ELSE '已合并' END AS affcode,

        COUNT(DISTINCT s1.device_id) AS new_account,

        CAST(COUNT_IF(CONTAINS(return_days_array, 0) AND DATE_ADD('day', 0, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 0, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_1,

        CAST(COUNT_IF(CONTAINS(return_days_array, 1) AND DATE_ADD('day', 1, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 1, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_2,

        CAST(COUNT_IF(CONTAINS(return_days_array, 2) AND DATE_ADD('day', 2, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 2, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_3,

        CAST(COUNT_IF(CONTAINS(return_days_array, 3) AND DATE_ADD('day', 3, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 3, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_4,

        CAST(COUNT_IF(CONTAINS(return_days_array, 4) AND DATE_ADD('day', 4, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 4, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_5,

        CAST(COUNT_IF(CONTAINS(return_days_array, 5) AND DATE_ADD('day', 5, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 5, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_6,

        CAST(COUNT_IF(CONTAINS(return_days_array, 6) AND DATE_ADD('day', 6, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 6, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_7,

        -- 新增：D8留存 / 8留
        -- 注册日为 day 0，所以 D8 对应 return_days_array 包含 7
        CAST(COUNT_IF(CONTAINS(return_days_array, 7) AND DATE_ADD('day', 7, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 7, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_8,

        CAST(COUNT_IF(CONTAINS(return_days_array, 13) AND DATE_ADD('day', 13, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 13, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_14,

        CAST(COUNT_IF(CONTAINS(return_days_array, 20) AND DATE_ADD('day', 20, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 20, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_21,
            
        CAST(COUNT_IF(CONTAINS(return_days_array, 29) AND DATE_ADD('day', 29, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 29, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_30,

        CAST(COUNT_IF(CONTAINS(return_days_array, 59) AND DATE_ADD('day', 59, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 59, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_60,

        CAST(COUNT_IF(CONTAINS(return_days_array, 89) AND DATE_ADD('day', 89, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 89, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_90,

        CAST(COUNT_IF(CONTAINS(return_days_array, 179) AND DATE_ADD('day', 179, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 179, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_180,

        CAST(COUNT_IF(CONTAINS(return_days_array, 359) AND DATE_ADD('day', 359, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 359, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS rr_360,

        CAST(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 
                AND DATE_ADD('day', 6, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date
            ) AS DOUBLE
        )
        / NULLIF(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2 
                AND DATE_ADD('day', 6, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date
            ), 
            0
        ) AS week1_retention_rate,

        CAST(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 
                AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1 
                AND DATE_ADD('day', 13, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date
            ) AS DOUBLE
        )
        / NULLIF(
            COUNT_IF(
                CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 
                AND DATE_ADD('day', 13, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date
            ), 
            0
        ) AS week2_return_rate

    FROM DeviceProfile s1
    LEFT JOIN DeviceRetentionArrays s2 
        ON s1.device_id = s2.device_id
    LEFT JOIN DeviceBlacklist s4 
        ON s1.device_id = s4.device_id
    CROSS JOIN ScanConfig sc
    WHERE s4.device_id IS NULL
      AND CAST(s1.reg_date AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
    GROUP BY 1, 2, 3, 4
),

-- 8. 新用户 LTV 计算
NewAccountLTV AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,

        CASE WHEN ${Selector:ostype} THEN s1.os_type ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN COALESCE(s1.country, '其他国家') ELSE '已合并' END AS country, 
        CASE WHEN ${Selector:affcode} THEN s1.affcode ELSE '已合并' END AS affcode,

        COUNT(DISTINCT s1.device_id) AS new_account,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 0, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 1)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 0, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_1,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 1, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 2)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 1, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_2,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 2, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 3)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 2, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_3,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 3, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 4)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 3, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_4,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 4, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 5)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 4, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_5,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 5, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 6)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 5, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_6,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 6, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 7)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 6, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_7,

        -- 新增：LTV_8
        -- 注册日为 day 0，所以 LTV_8 为 k < 8 的累计收入
        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 7, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 8)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 7, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_8,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 13, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 14)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 13, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_14,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 20, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 21)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 20, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_21,
       
        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 29, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 30)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 29, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_30,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 59, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 60)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 59, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_60,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 89, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 90)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 89, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_90,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 179, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 180)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 179, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_180,

        CAST(SUM(
            CASE 
                WHEN DATE_ADD('day', 359, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date 
                THEN COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s2.revenue_map, (k, v) -> k < 360)), 0.0, (acc, v) -> acc + v, acc -> acc), 0.0) 
            END
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 359, CAST(s1.reg_date AS DATE)) <= sc.mature_end_date), 0) AS ltv_360

    FROM DeviceProfile s1
    LEFT JOIN DeviceLtvMap s2 
        ON s1.device_id = s2.device_id
    LEFT JOIN DeviceBlacklist s4 
        ON s1.device_id = s4.device_id
    CROSS JOIN ScanConfig sc
    WHERE s4.device_id IS NULL
      AND CAST(s1.reg_date AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
    GROUP BY 1, 2, 3, 4
),

-- 9. 全局 KPI
DeviceKPI AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,

        CASE WHEN ${Selector:ostype} THEN s4.fixed_os ELSE '已合并' END AS os_type,

        CASE WHEN ${Selector:country} THEN COALESCE(
            CASE 
                WHEN s4.fixed_country IN ('中国', '中国大陆', 'CN') THEN '中国大陆'
                WHEN s4.fixed_country IN ('台湾', '香港', '澳门', '中国台湾', '中国香港', '中国澳门', 'TW', 'HK', 'MO', '台港澳') THEN '台港澳'
                ELSE '其他国家'
            END, 
            '其他国家'
        ) ELSE '已合并' END AS country, 

        CASE WHEN ${Selector:affcode} THEN s4.fixed_affcode ELSE '已合并' END AS affcode,

        MAX(CONCAT(
            CAST(GREATEST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'W' THEN DATE_TRUNC('week', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_TRUNC('month', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_start_date
                    ELSE CAST(v."$part_date" AS DATE)
                END, 
                sc.target_start_date
            ) AS VARCHAR),
            ' ~ ',
            CAST(LEAST(
                CASE 
                    WHEN ${Selector:timetype} = 'D' THEN DATE_TRUNC('day', CAST(v."$part_date" AS DATE))
                    WHEN ${Selector:timetype} = 'W' THEN DATE_ADD('day', 6, DATE_TRUNC('week', CAST(v."$part_date" AS DATE)))
                    WHEN ${Selector:timetype} = 'M' THEN DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', CAST(v."$part_date" AS DATE))))
                    WHEN ${Selector:timetype} = 'S' THEN DATE_ADD('day', -1, DATE_ADD('quarter', 1, DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE))))
                    WHEN ${Selector:timetype} = 'A' THEN sc.target_end_date
                    ELSE CAST(v."$part_date" AS DATE)
                END,
                sc.target_end_date
            ) AS VARCHAR)
        )) AS date_range,
        
        MIN(DATE_DIFF('day', CAST(v."$part_date" AS DATE), CURRENT_DATE)) AS date_gap,

        COUNT(DISTINCT COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#account_id"))) AS active_account,

        COUNT(DISTINCT CASE 
            WHEN v."$part_event" = 'PURCHASE' 
             AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT' 
            THEN COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#account_id")) 
        END) AS paying_account,

        SUM(CASE 
            WHEN v."$part_event" = 'PURCHASE' 
             AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT' 
            THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) 
        END) AS total_revenue_usd

    FROM ta.v_event_23 v
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserProfileDetail s4 
        ON v."#account_id" = s4."#account_id"
    LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    LEFT JOIN UserBlacklist s6 
        ON v."#account_id" = s6."#account_id"
    WHERE s6."#account_id" IS NULL
      AND v.${PartDate:date1} 
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'PURCHASE')
      AND (v."$part_event" <> 'PURCHASE' OR COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT')
    GROUP BY 1, 2, 3, 4
),

-- 10. 新用户首期转化 KPI
NewDeviceKPI AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s2.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s2.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s2.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s2.reg_date AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'A' THEN '1970-01-01'
        END AS time_dimension,

        CASE WHEN ${Selector:ostype} THEN s2.os_type ELSE '已合并' END AS os_type,
        CASE WHEN ${Selector:country} THEN COALESCE(s2.country, '其他国家') ELSE '已合并' END AS country, 
        CASE WHEN ${Selector:affcode} THEN s2.affcode ELSE '已合并' END AS affcode,

        COUNT(DISTINCT CASE 
            WHEN v."$part_event" = 'PURCHASE' 
             AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
             AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'A')
             )
            THEN COALESCE(NULLIF(s3.fixed_deviceid, ''), CONCAT('unknown_', v."#account_id")) 
        END) AS new_paying_account,

        SUM(CASE 
            WHEN v."$part_event" = 'PURCHASE' 
             AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
             AND (
                (${Selector:timetype} = 'D' AND DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'W' AND DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'M' AND DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'S' AND DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2.reg_date AS DATE))) OR
                (${Selector:timetype} = 'A')
             )
            THEN CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1) 
        END) AS new_account_revenue_usd

    FROM ta.v_event_23 v
    INNER JOIN UserProfileDetail s3 
        ON v."#account_id" = s3."#account_id"
    INNER JOIN DeviceProfile s2 
        ON COALESCE(NULLIF(s3.fixed_deviceid, ''), CONCAT('unknown_', s3."#account_id")) = s2.device_id
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    WHERE v.${PartDate:date1}
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'PURCHASE')
      AND (v."$part_event" <> 'PURCHASE' OR COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT')
      AND CAST(s2.reg_date AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
    GROUP BY 1, 2, 3, 4
)

-- 11. 最终报表汇总
SELECT
    k.time_dimension AS "时间维度", 
    k.os_type AS "OS", 
    k.country AS "地区", 
    k.affcode AS "渠道", 
    k.date_range AS "日期范围",

    k.active_account AS "活跃设备", 
    k.paying_account AS "付费设备", 
    ROUND(k.total_revenue_usd, 2) AS "总流水(USD)",

    CAST(k.paying_account AS DOUBLE) / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "付费率",
    k.total_revenue_usd / NULLIF(CAST(k.active_account AS DOUBLE), 0.0) AS "ARPU",
    k.total_revenue_usd / NULLIF(CAST(k.paying_account AS DOUBLE), 0.0) AS "ARPPU",
    
    ltv.new_account AS "新增设备", 
    p5.new_paying_account AS "新增付费设备", 
    ROUND(p5.new_account_revenue_usd, 2) AS "新增当日流水(USD)",

    p5.new_account_revenue_usd / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增ARPU",
    p5.new_account_revenue_usd / NULLIF(CAST(p5.new_paying_account AS DOUBLE), 0.0) AS "新增ARPPU",
    CAST(p5.new_paying_account AS DOUBLE) / NULLIF(CAST(ltv.new_account AS DOUBLE), 0.0) AS "新增付费率",

    k.date_gap AS "完整生命周期到第几天", 
    rr.rr_2 AS "次留", 
    rr.rr_3 AS "D3留存", 
    rr.rr_4 AS "D4留存", 
    rr.rr_5 AS "D5留存", 
    rr.rr_6 AS "D6留存", 
    rr.rr_7 AS "D7留存", 
    rr.rr_8 AS "D8留存", 
    rr.rr_14 AS "D14留存", 
    rr.rr_21 AS "D21留存",
    rr.rr_30 AS "D30留存", 
    rr.rr_60 AS "D60留存", 
    rr.rr_90 AS "D90留存", 
    rr.rr_180 AS "D180留存", 
    rr.rr_360 AS "D360留存",

    rr.week1_retention_rate AS "一阶登陆比率", 
    rr.week2_return_rate AS "二阶登陆比率",

    ltv.ltv_1 AS "LTV_1", 
    ltv.ltv_2 AS "LTV_2", 
    ltv.ltv_3 AS "LTV_3", 
    ltv.ltv_4 AS "LTV_4", 
    ltv.ltv_5 AS "LTV_5", 
    ltv.ltv_6 AS "LTV_6", 
    ltv.ltv_7 AS "LTV_7", 
    ltv.ltv_8 AS "LTV_8", 
    ltv.ltv_14 AS "LTV_14", 
    ltv.ltv_21 AS "LTV_21", 
    ltv.ltv_30 AS "LTV_30", 
    ltv.ltv_60 AS "LTV_60", 
    ltv.ltv_90 AS "LTV_90", 
    ltv.ltv_180 AS "LTV_180", 
    ltv.ltv_360 AS "LTV_360"

FROM DeviceKPI k
LEFT JOIN NewAccountLTV ltv 
    ON k.time_dimension = ltv.time_dimension 
   AND k.os_type = ltv.os_type 
   AND k.country = ltv.country 
   AND k.affcode = ltv.affcode
LEFT JOIN NewAccountRR rr 
    ON k.time_dimension = rr.time_dimension 
   AND k.os_type = rr.os_type 
   AND k.country = rr.country 
   AND k.affcode = rr.affcode
LEFT JOIN NewDeviceKPI p5 
    ON k.time_dimension = p5.time_dimension 
   AND k.os_type = p5.os_type 
   AND k.country = p5.country 
   AND k.affcode = p5.affcode
ORDER BY 1 DESC;