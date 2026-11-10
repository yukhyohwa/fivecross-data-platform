/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 用户首充距离创角时间分布
描述：统计目标周期内完成历史首次有效充值的账号，其首充距离首次 OBT 创角的时间分布。
区间：0-10min、10-30min、30-60min、60-120min、120-180min、180-240min、240min以上。

口径：
1. OBT 从 2026-10-14 开始；使用 fc_id，同账号多角色合并。
2. 创角时间取账号在完整 OBT 历史中的第一次 new_role。
3. 首充时间取首次创角后的第一笔有效 charge；排除 sandbox、is_freebuy。
4. 充值黑名单为 is_water_new、is_windows_new，使用 #varchar_id 关联 fc_id。
5. ${PartDate:date1} 筛选的是首充发生日期。
6. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

ScanConfig AS (
    SELECT
        MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
        MAX(CAST(v."$part_date" AS DATE)) AS target_end_date,
        MAX(c.obt_start_date) AS obt_start_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'charge'
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定每个 fc_id 的首次创角时间
--------------------------------------------------------------------------------
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

EligibleAccounts AS (
    SELECT r.fc_id, r.reg_event_time
    FROM AccountRegistrationRanked r
    LEFT JOIN UserBlacklist b ON r.fc_id = b.fc_id
    WHERE r.rn = 1
      AND b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- 从 OBT 开服扫描到报表结束日，确定创角后的历史首笔有效充值
--------------------------------------------------------------------------------
AllUserFirstChargeRanked AS (
    SELECT
        p.fc_id,
        p.reg_event_time,
        CAST(v."#event_time" AS TIMESTAMP) AS first_charge_time,
        CAST(v."$part_date" AS DATE) AS first_charge_date,
        ROW_NUMBER() OVER (
            PARTITION BY p.fc_id
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v.product_id AS VARCHAR) ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST
        ) AS charge_rank
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'charge'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
),

TargetFirstCharge AS (
    SELECT
        fc.fc_id,
        fc.reg_event_time,
        fc.first_charge_time
    FROM AllUserFirstChargeRanked fc
    CROSS JOIN ScanConfig sc
    WHERE fc.charge_rank = 1
      AND fc.first_charge_date BETWEEN sc.target_start_date AND sc.target_end_date
),

TimeDiffStats AS (
    SELECT
        fc.fc_id,
        DATE_DIFF('minute', fc.reg_event_time, fc.first_charge_time) AS diff_minutes
    FROM TargetFirstCharge fc
)

SELECT
    CASE
        WHEN diff_minutes >= 0 AND diff_minutes <= 10 THEN '01_0-10min'
        WHEN diff_minutes > 10 AND diff_minutes <= 30 THEN '02_10-30min'
        WHEN diff_minutes > 30 AND diff_minutes <= 60 THEN '03_30-60min'
        WHEN diff_minutes > 60 AND diff_minutes <= 120 THEN '04_60-120min'
        WHEN diff_minutes > 120 AND diff_minutes <= 180 THEN '05_120-180min'
        WHEN diff_minutes > 180 AND diff_minutes <= 240 THEN '06_180-240min'
        WHEN diff_minutes > 240 THEN '07_240min以上'
        ELSE '08_异常数据(如时间错乱)'
    END AS "时间区间",
    COUNT(DISTINCT fc_id) AS "人数"
FROM TimeDiffStats
GROUP BY 1
ORDER BY 1 ASC;
