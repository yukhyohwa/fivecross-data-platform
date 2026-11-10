/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: TC (Traditional Chinese)
Description: 2nd Anniversary Focus Analysis - Device Lifecycle (New vs. Returning)
Target Period: 2026-01-22 10:00 ~ 2026-01-25 23:59
Author: Antigravity
Logic: Unified with kb_tc_comprehensive_kpi_report.sql (Device Min Login Pattern)
Definition:
  - New Device: Historically FIRST login after 2026-01-22 10:00.
  - Returning Device: Last login before 2026-01-22 was more than 7 days ago.
================================================================================
*/

WITH 
-------------------------------------------------------
-- 1. 黑名单逻辑 (Blacklist)
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 设备基础表 (寻找每个设备的“历史首登时间”)
-------------------------------------------------------
DeviceHistoryBase AS (
    SELECT 
        s1."#device_id", 
        MIN(s1."#event_time") AS first_login_time
    FROM ta.v_event_10 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND b."#user_id" IS NULL
      AND s1."#device_id" IS NOT NULL AND s1."#device_id" <> ''
      AND "$part_date" > '2020-01-22'
    GROUP BY 1
),

-------------------------------------------------------
-- 3. 分类标识：新设备 (New Devices)
-------------------------------------------------------
NewDevices AS (
    SELECT "#device_id"
    FROM DeviceHistoryBase
    WHERE first_login_time >= TIMESTAMP '2026-01-22 10:00:00'
),

-------------------------------------------------------
-- 4. 分类标识：回流设备 (Returning Devices) 
-------------------------------------------------------
-- 4.1 01/22 10:00 之前最后一次登入日期
DevicePreActivity AS (
    SELECT 
        s1."#device_id",
        MAX(s1."$part_date") as last_active_date_pre
    FROM ta.v_event_10 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND s1."#event_time" < TIMESTAMP '2026-01-22 10:00:00'
      AND b."#user_id" IS NULL
    GROUP BY 1
),

-- 4.2 定义回流：必须是老设备（首登在前）且一週以上未登入
ReturningDevices AS (
    SELECT dpa."#device_id"
    FROM DevicePreActivity dpa
    INNER JOIN DeviceHistoryBase dhb ON dpa."#device_id" = dhb."#device_id"
    WHERE dpa.last_active_date_pre < '2026-01-15'
      AND dhb.first_login_time < TIMESTAMP '2026-01-22 10:00:00'
),

-------------------------------------------------------
-- 5. 聚合 DAU (基于二週年期间)
-------------------------------------------------------
CategorizedDAU AS (
    SELECT 
        s1."$part_date" as dt,
        s1."#device_id",
        CASE WHEN nd."#device_id" IS NOT NULL THEN 1 ELSE 0 END as is_new,
        CASE WHEN rd."#device_id" IS NOT NULL THEN 1 ELSE 0 END as is_returning
    FROM ta.v_event_10 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    LEFT JOIN NewDevices nd ON s1."#device_id" = nd."#device_id"
    LEFT JOIN ReturningDevices rd ON s1."#device_id" = rd."#device_id"
    WHERE s1."$part_event" = 'login'
      AND s1."$part_date" BETWEEN '2026-01-22' AND '2026-01-25'
      AND b."#user_id" IS NULL
)

-------------------------------------------------------
-- 6. 最终输出聚合
-------------------------------------------------------
SELECT 
    dt AS "日期",
    COUNT(DISTINCT "#device_id") AS "DAU (活跃设备)",
    
    -- 新设备活跃数
    SUM(is_new) AS "新增设备数",
    CAST(ROUND(CAST(SUM(is_new) AS DOUBLE) / COUNT(DISTINCT "#device_id") * 100, 2) AS VARCHAR) || '%' AS "新增占比",
    
    -- 回流设备活跃数
    SUM(is_returning) AS "回流设备数",
    CAST(ROUND(CAST(SUM(is_returning) AS DOUBLE) / COUNT(DISTINCT "#device_id") * 100, 2) AS VARCHAR) || '%' AS "回流占比"

FROM CategorizedDAU
GROUP BY 1
ORDER BY 1;
