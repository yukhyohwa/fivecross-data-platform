/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 异常设备或 IP 关联的未付费账号 (lcx_id) 筛选
Description: 使用 UNION 合并并去重以下两批异常账号：
             - 条件 1：单一设备 ID 关联 10 个以上账号，且该设备下未付费的账号。
             - 条件 2：单一 IP 关联 100 个以上设备，这些设备关联的未付费账号。
Environment: Trino (TA)
================================================================================
*/

WITH UserProfiles AS (
    -- 1. 从标签表整理每个账号的固化 IP 与 固化设备 ID
    SELECT 
        "#varchar_id" AS lcx_id,
        COALESCE(NULLIF(MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END), ''), 'unknown') AS fixed_deviceid,
        COALESCE(NULLIF(MAX(CASE WHEN cluster_name = 'fixed_ip'       THEN tag_value END), ''), 'unknown') AS fixed_ip
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_deviceid', 'fixed_ip')
    GROUP BY 1
),

PaidUsers AS (
    -- 2. 提取 OBT 期间 (6.23起) 有真实充值记录的账号列表 (排除沙盒)
    SELECT DISTINCT 
        v."#account_id" AS lcx_id
    FROM ta.v_event_23 v
    WHERE v."$part_event" = 'PURCHASE'
      AND (v.payload.validationtype IS NULL OR v.payload.validationtype <> 'SANDBOX_RECEIPT')
      AND v."$part_date" >= '2026-06-23'
),

-- 3. 条件 1：单一设备 ID 关联超过 10 个账号的设备，及其关联的未付费账号
Condition1Devices AS (
    SELECT fixed_deviceid
    FROM UserProfiles
    WHERE fixed_deviceid IS NOT NULL 
      AND fixed_deviceid <> 'unknown' 
      AND fixed_deviceid <> ''
    GROUP BY 1
    HAVING COUNT(DISTINCT lcx_id) > 10
),

Condition1Users AS (
    SELECT DISTINCT 
        up.lcx_id
    FROM UserProfiles up
    INNER JOIN Condition1Devices cd ON up.fixed_deviceid = cd.fixed_deviceid
    LEFT JOIN PaidUsers pu ON up.lcx_id = pu.lcx_id
    WHERE pu.lcx_id IS NULL
),

-- 4. 条件 2：单一 IP 关联 100 个以上设备的 IP 下关联的所有设备，及其关联的未付费账号
Condition2IPs AS (
    SELECT fixed_ip
    FROM UserProfiles
    WHERE fixed_ip IS NOT NULL 
      AND fixed_ip <> 'unknown' 
      AND fixed_ip <> ''
      AND fixed_deviceid IS NOT NULL 
      AND fixed_deviceid <> 'unknown' 
      AND fixed_deviceid <> ''
    GROUP BY 1
    HAVING COUNT(DISTINCT fixed_deviceid) > 100
),

Condition2Devices AS (
    SELECT DISTINCT fixed_deviceid
    FROM UserProfiles
    WHERE fixed_ip IN (SELECT fixed_ip FROM Condition2IPs)
      AND fixed_deviceid IS NOT NULL 
      AND fixed_deviceid <> 'unknown' 
      AND fixed_deviceid <> ''
),

Condition2Users AS (
    SELECT DISTINCT 
        up.lcx_id
    FROM UserProfiles up
    INNER JOIN Condition2Devices cd ON up.fixed_deviceid = cd.fixed_deviceid
    LEFT JOIN PaidUsers pu ON up.lcx_id = pu.lcx_id
    WHERE pu.lcx_id IS NULL
)

-- 5. 合并去重输出最终的 lcx_id
SELECT lcx_id FROM Condition1Users
UNION
SELECT lcx_id FROM Condition2Users;
