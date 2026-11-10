/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 用户首充前最后的主线副本统计
描述：统计账号在历史首次有效充值前，最后一次攻打的主线副本关卡分布。
输出：关卡名称和人数两列，字段名称及顺序保持原 SQL 不变。

口径：
1. OBT 从 2026-10-14 开始；使用 fc_id，同账号多角色合并。
2. 先确定首次 OBT 创角，再寻找创角后的第一笔有效 charge。
3. 有效充值排除 sandbox、is_freebuy。
4. 充值黑名单为 is_water_new、is_windows_new，使用 #varchar_id 关联 fc_id。
5. 主线战斗必须发生在首次 OBT 创角之后、历史首充之前。
6. ${PartDate:date1} 筛选的是首充发生日期。
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
-- 完整 OBT 历史中确定每个 fc_id 的首次创角
--------------------------------------------------------------------------------
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
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
    SELECT r.fc_id, r.reg_date, r.reg_event_time
    FROM AccountRegistrationRanked r
    LEFT JOIN UserBlacklist b ON r.fc_id = b.fc_id
    WHERE r.rn = 1
      AND b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- 扫描开服至报表结束日的充值，确定账号历史首笔有效订单
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

--------------------------------------------------------------------------------
-- 目标账号首次创角后、首充前的主线副本战斗
--------------------------------------------------------------------------------
MainStageFights AS (
    SELECT
        fc.fc_id,
        CAST(v.stage_id AS INTEGER) AS stage_id,
        ds."stage_id@stage_name_real",
        CAST(v."#event_time" AS TIMESTAMP) AS fight_time
    FROM ta.v_event_18 v
    INNER JOIN TargetFirstCharge fc
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = fc.fc_id
    LEFT JOIN ta_dim.dim_13_0_18203 ds
        ON CAST(v.stage_id AS VARCHAR) = CAST(ds."stage_id@stage_id" AS VARCHAR)
    WHERE SPLIT(ds."stage_id@stage_name_real", '-')[3] = '5'
      AND v."#event_name" = 'stage_fight'
      AND v.a_rst[1].key = '1001'
      AND CAST(v."#event_time" AS TIMESTAMP) >= fc.reg_event_time
      AND CAST(v."#event_time" AS TIMESTAMP) < fc.first_charge_time
),

LastFightBeforeCharge AS (
    SELECT fc_id, stage_id, "stage_id@stage_name_real"
    FROM (
        SELECT
            fc_id,
            stage_id,
            "stage_id@stage_name_real",
            ROW_NUMBER() OVER (
                PARTITION BY fc_id
                ORDER BY fight_time DESC,
                         stage_id DESC NULLS LAST
            ) AS fight_rank
        FROM MainStageFights
    ) t
    WHERE fight_rank = 1
),

StageStats AS (
    SELECT
        stage_id,
        "stage_id@stage_name_real",
        COUNT(DISTINCT fc_id) AS num
    FROM LastFightBeforeCharge
    GROUP BY 1, 2
)

SELECT
    "stage_id@stage_name_real",
    num
FROM StageStats
ORDER BY 1 ASC;
