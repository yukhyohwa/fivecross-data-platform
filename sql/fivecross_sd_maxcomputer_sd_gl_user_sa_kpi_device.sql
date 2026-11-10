-- ================================================================================
-- 游戏: 灌篮高手 (Slam Dunk)
-- 区域: 南美大区 (South America, Zone 开头为 3)
-- 描述: 核心 KPI 概览 (新增设备、活跃设备、收入、留存、LTV)
-- 引擎: MaxCompute (ODPS)
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

WITH SA_Filter AS (
    -- 1. 识别南美大区的角色及其账号 (通过 snapshot 确定区域)
    SELECT DISTINCT mbga_uid AS lcm_id
    FROM g63002013.daily_user_snapshot
    WHERE SUBSTR(zone, 1, 1) = '3'
      AND day >= 20200101

),

Device_Base AS (
    -- 2. 获取设备的首次出现日期（设备注册日）
    -- 仅包含在南美大区有过登录行为的设备
    SELECT 
        raw.device_id,
        MIN(raw.day) AS device_reg_day
    FROM dm_platform.daily_lcx_user_info raw
    INNER JOIN SA_Filter sa ON raw.lcm_id = sa.lcm_id
    WHERE raw.app_id = 63002013
    AND raw.day >= '20200101' -- 从游戏上线周期开始
    GROUP BY raw.device_id
),

Daily_Raw_Data AS (
    -- 3. 提取以设备为基础的活跃与营收数据
    SELECT 
        raw.day,
        db.device_reg_day,
        raw.device_id,
        raw.purchase AS daily_revenue
    FROM dm_platform.daily_lcx_user_info raw
    INNER JOIN Device_Base db ON raw.device_id = db.device_id
    WHERE raw.app_id = 63002013
      AND raw.day >= '20200101'
),

Daily_KPI AS (
    -- 4. 计算每日设备 DAU, NUU, Revenue
    SELECT 
        day,
        COUNT(DISTINCT device_id) AS dau,
        COUNT(DISTINCT CASE WHEN day = device_reg_day THEN device_id END) AS nuu,
        SUM(daily_revenue) AS revenue
    FROM Daily_Raw_Data
    GROUP BY day
),

Retention_LTV_Base AS (
    -- 5. 计算设备留存与 LTV
    SELECT 
        device_reg_day AS reg_day,
        COUNT(DISTINCT device_id) AS reg_count,
        -- 留存设备数
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 1  THEN device_id END) AS ret_1,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 2  THEN device_id END) AS ret_2,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 3  THEN device_id END) AS ret_3,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 4  THEN device_id END) AS ret_4,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 5  THEN device_id END) AS ret_5,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 6  THEN device_id END) AS ret_6,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 7  THEN device_id END) AS ret_7,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 8  THEN device_id END) AS ret_8,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 9  THEN device_id END) AS ret_9,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 10  THEN device_id END) AS ret_10,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 11  THEN device_id END) AS ret_11,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 12  THEN device_id END) AS ret_12,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 13  THEN device_id END) AS ret_13,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 14  THEN device_id END) AS ret_14,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 15  THEN device_id END) AS ret_15,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 16  THEN device_id END) AS ret_16,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 17  THEN device_id END) AS ret_17,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 18  THEN device_id END) AS ret_18,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 19  THEN device_id END) AS ret_19,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 20  THEN device_id END) AS ret_20,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 21  THEN device_id END) AS ret_21,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 22  THEN device_id END) AS ret_22,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 23  THEN device_id END) AS ret_23,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 24  THEN device_id END) AS ret_24,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 25  THEN device_id END) AS ret_25,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 26  THEN device_id END) AS ret_26,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 27  THEN device_id END) AS ret_27,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 28  THEN device_id END) AS ret_28,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 29  THEN device_id END) AS ret_29,
        COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) = 30  THEN device_id END) AS ret_30,
        -- 累积收入 (用于 LTV)
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 1  THEN daily_revenue ELSE 0 END) AS rev_1,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 2  THEN daily_revenue ELSE 0 END) AS rev_2,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 3  THEN daily_revenue ELSE 0 END) AS rev_3,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 4  THEN daily_revenue ELSE 0 END) AS rev_4,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 5  THEN daily_revenue ELSE 0 END) AS rev_5,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 6  THEN daily_revenue ELSE 0 END) AS rev_6,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 7  THEN daily_revenue ELSE 0 END) AS rev_7,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 8  THEN daily_revenue ELSE 0 END) AS rev_8,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 9  THEN daily_revenue ELSE 0 END) AS rev_9,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 10  THEN daily_revenue ELSE 0 END) AS rev_10,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 11  THEN daily_revenue ELSE 0 END) AS rev_11,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 12  THEN daily_revenue ELSE 0 END) AS rev_12,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 13  THEN daily_revenue ELSE 0 END) AS rev_13,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 14  THEN daily_revenue ELSE 0 END) AS rev_14,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 15  THEN daily_revenue ELSE 0 END) AS rev_15,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 16  THEN daily_revenue ELSE 0 END) AS rev_16,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 17  THEN daily_revenue ELSE 0 END) AS rev_17,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 18  THEN daily_revenue ELSE 0 END) AS rev_18,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 19  THEN daily_revenue ELSE 0 END) AS rev_19,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 20  THEN daily_revenue ELSE 0 END) AS rev_20,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 21  THEN daily_revenue ELSE 0 END) AS rev_21,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 22  THEN daily_revenue ELSE 0 END) AS rev_22,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 23  THEN daily_revenue ELSE 0 END) AS rev_23,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 24  THEN daily_revenue ELSE 0 END) AS rev_24,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 25  THEN daily_revenue ELSE 0 END) AS rev_25,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 26  THEN daily_revenue ELSE 0 END) AS rev_26,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 27  THEN daily_revenue ELSE 0 END) AS rev_27,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 28  THEN daily_revenue ELSE 0 END) AS rev_28,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 29  THEN daily_revenue ELSE 0 END) AS rev_29,
        SUM(CASE WHEN DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(device_reg_day, 'yyyyMMdd')) < 30  THEN daily_revenue ELSE 0 END) AS rev_30
    FROM Daily_Raw_Data
    GROUP BY device_reg_day
)

-- 6. 最终汇总报表
SELECT 
    kpi.day,
    -- 累计设备数
    SUM(kpi.nuu) OVER (ORDER BY kpi.day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_devices,
    kpi.nuu,
    kpi.dau,
    kpi.revenue,
    ROUND(kpi.revenue / NULLIF(kpi.dau, 0), 2) AS arpu,
    -- 设备留存率
    ROUND(COALESCE(rl.ret_1, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_1,
    ROUND(COALESCE(rl.ret_2, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_2,
    ROUND(COALESCE(rl.ret_3, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_3,
    ROUND(COALESCE(rl.ret_4, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_4,
    ROUND(COALESCE(rl.ret_5, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_5,
    ROUND(COALESCE(rl.ret_6, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_6,
    ROUND(COALESCE(rl.ret_7, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_7,
    ROUND(COALESCE(rl.ret_8, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_8,
    ROUND(COALESCE(rl.ret_9, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_9,
    ROUND(COALESCE(rl.ret_10, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_10,
    ROUND(COALESCE(rl.ret_11, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_11,
    ROUND(COALESCE(rl.ret_12, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_12,
    ROUND(COALESCE(rl.ret_13, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_13,
    ROUND(COALESCE(rl.ret_14, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_14,
    ROUND(COALESCE(rl.ret_15, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_15,
    ROUND(COALESCE(rl.ret_16, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_16,
    ROUND(COALESCE(rl.ret_17, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_17,
    ROUND(COALESCE(rl.ret_18, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_18,
    ROUND(COALESCE(rl.ret_19, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_19,
    ROUND(COALESCE(rl.ret_20, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_20,
    ROUND(COALESCE(rl.ret_21, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_21,
    ROUND(COALESCE(rl.ret_22, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_22,
    ROUND(COALESCE(rl.ret_23, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_23,
    ROUND(COALESCE(rl.ret_24, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_24,
    ROUND(COALESCE(rl.ret_25, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_25,
    ROUND(COALESCE(rl.ret_26, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_26,
    ROUND(COALESCE(rl.ret_27, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_27,
    ROUND(COALESCE(rl.ret_28, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_28,
    ROUND(COALESCE(rl.ret_29, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_29,
    ROUND(COALESCE(rl.ret_30, 0)  / NULLIF(rl.reg_count, 0), 4) AS rr_30,
    -- 设备 LTV
    ROUND(COALESCE(rl.rev_1, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_1,
    ROUND(COALESCE(rl.rev_2, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_2,
    ROUND(COALESCE(rl.rev_3, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_3,
    ROUND(COALESCE(rl.rev_4, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_4,
    ROUND(COALESCE(rl.rev_5, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_5,
    ROUND(COALESCE(rl.rev_6, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_6,
    ROUND(COALESCE(rl.rev_7, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_7,
    ROUND(COALESCE(rl.rev_8, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_8,
    ROUND(COALESCE(rl.rev_9, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_9,
    ROUND(COALESCE(rl.rev_10, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_10,
    ROUND(COALESCE(rl.rev_11, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_11,
    ROUND(COALESCE(rl.rev_12, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_12,
    ROUND(COALESCE(rl.rev_13, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_13,
    ROUND(COALESCE(rl.rev_14, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_14,
    ROUND(COALESCE(rl.rev_15, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_15,
    ROUND(COALESCE(rl.rev_16, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_16,
    ROUND(COALESCE(rl.rev_17, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_17,
    ROUND(COALESCE(rl.rev_18, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_18,
    ROUND(COALESCE(rl.rev_19, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_19,
    ROUND(COALESCE(rl.rev_20, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_20,
    ROUND(COALESCE(rl.rev_21, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_21,
    ROUND(COALESCE(rl.rev_22, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_22,
    ROUND(COALESCE(rl.rev_23, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_23,
    ROUND(COALESCE(rl.rev_24, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_24,
    ROUND(COALESCE(rl.rev_25, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_25,
    ROUND(COALESCE(rl.rev_26, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_26,
    ROUND(COALESCE(rl.rev_27, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_27,
    ROUND(COALESCE(rl.rev_28, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_28,
    ROUND(COALESCE(rl.rev_29, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_29,
    ROUND(COALESCE(rl.rev_30, 0)  / NULLIF(rl.reg_count, 0), 2) AS ltv_30
FROM Daily_KPI kpi
LEFT JOIN Retention_LTV_Base rl ON kpi.day = rl.reg_day
ORDER BY kpi.day DESC;
