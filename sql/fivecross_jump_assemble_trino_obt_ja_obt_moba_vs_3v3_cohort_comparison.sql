/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : MOBA 5v5 历史老用户 vs 3v3 新用户 留存与 LTV 表现对比
          fixed_regdate 新增批次 + event16/event23 NUU 分类 + 设备口径
          仅限 iOS

Description:
             1. 新增批次判定：
                使用 user_result_cluster_23 的 fixed_regdate 标签。
                fixed_regdate 在统计日期范围内，即进入该批新增分母。

             2. 3v3 新用户：
                账号在 ta.v_event_16 或 ta.v_event_23 有 NUU 事件。

             3. MOBA 老用户：
                账号在 ta.v_event_16 和 ta.v_event_23 都没有 NUU 事件。
                说明账号由 MOBA 5v5 历史版本继承 / 导入。

             4. 统计口径：
                为了对齐 KPI SQL 的新增设备，使用 fixed_deviceid 设备口径。
                空 fixed_deviceid 使用 CONCAT('unknown_', account_id) 虚拟设备。

Metrics : 次留、3留、7留、14留、LTV1、LTV3、LTV7、LTV14
Environment: Trino (TA)
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 0. 参数配置
--------------------------------------------------------------------------------
Config AS (
    SELECT
        DATE '2026-06-24' AS cohort_start_date,
        DATE '2026-07-07' AS cohort_end_date,
        DATE_ADD('day', -1, CURRENT_DATE) AS mature_end_date
),

--------------------------------------------------------------------------------
-- 1. 黑名单用户
--    这里需要和 KPI SQL 的黑名单口径保持一致
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT
        "#varchar_id" AS account_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('is_water')
),

--------------------------------------------------------------------------------
-- 2. 用户标签明细
--    fixed_regdate：新增批次判定
--    fixed_os：iOS 筛选
--    fixed_deviceid：设备口径
--------------------------------------------------------------------------------
UserProfileDetail AS (
    SELECT
        "#varchar_id" AS account_id,

        MAX(
            CASE WHEN cluster_name = 'fixed_regdate'
            THEN tag_value END
        ) AS fixed_regdate,

        MAX(
            CASE WHEN cluster_name = 'fixed_os'
            THEN tag_value END
        ) AS fixed_os,

        MAX(
            CASE WHEN cluster_name = 'fixed_deviceid'
            THEN tag_value END
        ) AS fixed_deviceid

    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_regdate', 'fixed_os', 'fixed_deviceid')
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 3. 账号映射到设备
--    和 KPI SQL 对齐：
--    有 fixed_deviceid 用 fixed_deviceid
--    没有 fixed_deviceid 用 unknown_account_id
--------------------------------------------------------------------------------
AccountDeviceMap AS (
    SELECT
        account_id,

        COALESCE(
            NULLIF(fixed_deviceid, ''),
            CONCAT('unknown_', account_id)
        ) AS device_id,

        fixed_regdate,
        fixed_os,
        fixed_deviceid

    FROM UserProfileDetail
),

--------------------------------------------------------------------------------
-- 4. 设备基础属性
--    新增批次用 fixed_regdate
--    一个设备下多个账号时，取最早 fixed_regdate 作为设备 reg_date
--    这和 KPI SQL 的 DeviceProfile 逻辑一致
--------------------------------------------------------------------------------
DeviceProfile AS (
    SELECT
        device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type
    FROM AccountDeviceMap
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 5. 黑名单设备
--    黑名单账号所在设备整体排除
--------------------------------------------------------------------------------
DeviceBlacklist AS (
    SELECT DISTINCT
        adm.device_id
    FROM UserBlacklist ub
    INNER JOIN AccountDeviceMap adm
        ON ub.account_id = adm.account_id
),

--------------------------------------------------------------------------------
-- 6. Cohort 设备
--    新用户 / 新增设备判定标准：fixed_regdate
--------------------------------------------------------------------------------
CohortDevices AS (
    SELECT
        dp.device_id,
        CAST(dp.reg_date AS DATE) AS cohort_date,
        dp.os_type
    FROM DeviceProfile dp
    CROSS JOIN Config c
    LEFT JOIN DeviceBlacklist db
        ON dp.device_id = db.device_id
    WHERE db.device_id IS NULL
      AND dp.os_type = 'iOS'
      AND dp.reg_date IS NOT NULL
      AND CAST(dp.reg_date AS DATE) BETWEEN c.cohort_start_date AND c.cohort_end_date
),

--------------------------------------------------------------------------------
-- 7. event16 / event23 中出现过 NUU 的账号
--    3v3 判定条件：
--    event16 有 NUU 或 event23 有 NUU
--------------------------------------------------------------------------------
NuuAccounts AS (
    SELECT DISTINCT
        "#account_id" AS account_id
    FROM ta.v_event_16
    WHERE "$part_event" = 'NUU'

    UNION

    SELECT DISTINCT
        "#account_id" AS account_id
    FROM ta.v_event_23
    WHERE "$part_event" = 'NUU'
),

--------------------------------------------------------------------------------
-- 8. NUU 账号映射到设备
--    设备下任意账号有 NUU，则该设备归为 3v3 新用户设备
--------------------------------------------------------------------------------
NuuDevices AS (
    SELECT DISTINCT
        adm.device_id
    FROM NuuAccounts na
    INNER JOIN AccountDeviceMap adm
        ON na.account_id = adm.account_id
),

--------------------------------------------------------------------------------
-- 9. 设备分类
--    event16/event23 有 NUU => 3v3 新用户
--    event16/event23 都没有 NUU => MOBA 老用户
--------------------------------------------------------------------------------
DeviceGroups AS (
    SELECT
        cd.device_id,
        cd.cohort_date,

        CASE
            WHEN nd.device_id IS NOT NULL THEN '3v3_NewUser'
            ELSE 'MOBA_LegacyUser'
        END AS user_group

    FROM CohortDevices cd
    LEFT JOIN NuuDevices nd
        ON cd.device_id = nd.device_id
),

--------------------------------------------------------------------------------
-- 10. 设备活跃日期
--     用于计算留存
--------------------------------------------------------------------------------
DeviceActiveDays AS (
    SELECT DISTINCT
        COALESCE(
            NULLIF(up.fixed_deviceid, ''),
            CONCAT('unknown_', v."#account_id")
        ) AS device_id,

        CAST(v."$part_date" AS DATE) AS active_date

    FROM ta.v_event_23 v
    CROSS JOIN Config c
    LEFT JOIN UserProfileDetail up
        ON v."#account_id" = up.account_id

    WHERE v."$part_event" IN ('LOGIN_SUCCESS', 'NUU')
      AND CAST(v."$part_date" AS DATE) >= c.cohort_start_date
      AND CAST(v."$part_date" AS DATE) <= c.mature_end_date
),

--------------------------------------------------------------------------------
-- 11. 设备充值日期
--     排除沙盒充值，折算 USD
--------------------------------------------------------------------------------
DeviceRecharge AS (
    SELECT
        COALESCE(
            NULLIF(up.fixed_deviceid, ''),
            CONCAT('unknown_', v."#account_id")
        ) AS device_id,

        CAST(v."$part_date" AS DATE) AS pay_date,

        SUM(
            CAST(v.payload.curamt AS DOUBLE)
            / COALESCE(ex.exchange, 1.0)
        ) AS revenue_usd

    FROM ta.v_event_23 v
    CROSS JOIN Config c
    LEFT JOIN UserProfileDetail up
        ON v."#account_id" = up.account_id
    LEFT JOIN ta_dim.ta_exchange ex
        ON v."$part_date" = ex.ex_date
       AND v.payload.cur = ex.currency

    WHERE v."$part_event" = 'PURCHASE'
      AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
      AND CAST(v."$part_date" AS DATE) >= c.cohort_start_date
      AND CAST(v."$part_date" AS DATE) <= c.mature_end_date

    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 12. 设备级留存标记
--     次留 = cohort + 1
--     3留  = cohort + 2
--     7留  = cohort + 6
--     14留 = cohort + 13
--------------------------------------------------------------------------------
DeviceMetricsActive AS (
    SELECT
        dg.device_id,

        MAX(
            CASE
                WHEN da.active_date = DATE_ADD('day', 1, dg.cohort_date)
                THEN 1 ELSE 0
            END
        ) AS active_d1,

        MAX(
            CASE
                WHEN da.active_date = DATE_ADD('day', 2, dg.cohort_date)
                THEN 1 ELSE 0
            END
        ) AS active_d3,

        MAX(
            CASE
                WHEN da.active_date = DATE_ADD('day', 6, dg.cohort_date)
                THEN 1 ELSE 0
            END
        ) AS active_d7,

        MAX(
            CASE
                WHEN da.active_date = DATE_ADD('day', 13, dg.cohort_date)
                THEN 1 ELSE 0
            END
        ) AS active_d14

    FROM DeviceGroups dg
    LEFT JOIN DeviceActiveDays da
        ON dg.device_id = da.device_id
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 13. 设备级 LTV
--     LTV1  = cohort 当日
--     LTV3  = cohort ~ cohort + 2
--     LTV7  = cohort ~ cohort + 6
--     LTV14 = cohort ~ cohort + 13
--------------------------------------------------------------------------------
DeviceMetricsRecharge AS (
    SELECT
        dg.device_id,

        SUM(
            CASE
                WHEN dr.pay_date = dg.cohort_date
                THEN dr.revenue_usd ELSE 0.0
            END
        ) AS revenue_ltv1,

        SUM(
            CASE
                WHEN dr.pay_date BETWEEN dg.cohort_date AND DATE_ADD('day', 2, dg.cohort_date)
                THEN dr.revenue_usd ELSE 0.0
            END
        ) AS revenue_ltv3,

        SUM(
            CASE
                WHEN dr.pay_date BETWEEN dg.cohort_date AND DATE_ADD('day', 6, dg.cohort_date)
                THEN dr.revenue_usd ELSE 0.0
            END
        ) AS revenue_ltv7,

        SUM(
            CASE
                WHEN dr.pay_date BETWEEN dg.cohort_date AND DATE_ADD('day', 13, dg.cohort_date)
                THEN dr.revenue_usd ELSE 0.0
            END
        ) AS revenue_ltv14

    FROM DeviceGroups dg
    LEFT JOIN DeviceRecharge dr
        ON dg.device_id = dr.device_id
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 14. 合并设备级指标
--------------------------------------------------------------------------------
DeviceMetrics AS (
    SELECT
        dg.device_id,
        dg.cohort_date,
        dg.user_group,

        COALESCE(dma.active_d1, 0) AS active_d1,
        COALESCE(dma.active_d3, 0) AS active_d3,
        COALESCE(dma.active_d7, 0) AS active_d7,
        COALESCE(dma.active_d14, 0) AS active_d14,

        COALESCE(dmr.revenue_ltv1, 0.0) AS revenue_ltv1,
        COALESCE(dmr.revenue_ltv3, 0.0) AS revenue_ltv3,
        COALESCE(dmr.revenue_ltv7, 0.0) AS revenue_ltv7,
        COALESCE(dmr.revenue_ltv14, 0.0) AS revenue_ltv14

    FROM DeviceGroups dg
    LEFT JOIN DeviceMetricsActive dma
        ON dg.device_id = dma.device_id
    LEFT JOIN DeviceMetricsRecharge dmr
        ON dg.device_id = dmr.device_id
)

--------------------------------------------------------------------------------
-- 15. 最终汇总输出
--------------------------------------------------------------------------------
SELECT
    CAST(dm.cohort_date AS VARCHAR) AS "批次日期",

    CASE
        WHEN dm.user_group = '3v3_NewUser' THEN '3v3 新用户'
        ELSE 'MOBA 老用户'
    END AS "用户类型",

    COUNT(DISTINCT dm.device_id) AS "进入设备",

    ROUND(
        CAST(SUM(dm.active_d1) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0) * 100,
        2
    ) AS "次留 (%)",

    ROUND(
        CAST(SUM(dm.active_d3) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0) * 100,
        2
    ) AS "3留 (%)",

    ROUND(
        CAST(SUM(dm.active_d7) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0) * 100,
        2
    ) AS "7留 (%)",

    ROUND(
        CAST(SUM(dm.active_d14) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0) * 100,
        2
    ) AS "14留 (%)",

    ROUND(
        SUM(dm.revenue_ltv1)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0),
        4
    ) AS "LTV1 (USD)",

    ROUND(
        SUM(dm.revenue_ltv3)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0),
        4
    ) AS "LTV3 (USD)",

    ROUND(
        SUM(dm.revenue_ltv7)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0),
        4
    ) AS "LTV7 (USD)",

    ROUND(
        SUM(dm.revenue_ltv14)
        / NULLIF(COUNT(DISTINCT dm.device_id), 0),
        4
    ) AS "LTV14 (USD)"

FROM DeviceMetrics dm
GROUP BY
    dm.cohort_date,
    dm.user_group

ORDER BY
    dm.cohort_date ASC,
    "用户类型" DESC;