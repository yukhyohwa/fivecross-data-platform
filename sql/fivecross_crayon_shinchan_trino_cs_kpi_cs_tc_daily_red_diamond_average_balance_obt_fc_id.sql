/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 红钻（10009）每日平均持仓统计
时间：自适应 ${PartDate:date1}
逻辑：取每日每个 fc_id 最后一次红钻变动后的余额（after），计算全服平均值。

口径：
1. OBT 从 2026-10-14 开始；使用 fc_id，同账号多角色合并。
2. 仅统计账号首次 OBT 创角后的红钻记录。
3. 黑名单使用 #varchar_id，排除 is_water_new、is_windows_new、internal_users_new。
4. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/

WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),

ReportRange AS (
    SELECT MAX(CAST(v."$part_date" AS DATE)) AS report_end_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'item_change'
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new', 'internal_users_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中确定每个 fc_id 的首次创角
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
    CROSS JOIN Config c
    CROSS JOIN ReportRange r
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.report_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

EligibleAccounts AS (
    SELECT r.fc_id, r.reg_event_time
    FROM AccountRegistrationRanked r
    LEFT JOIN UserBlacklist b ON r.fc_id = b.fc_id
    WHERE r.rn = 1
      AND b.fc_id IS NULL
),

FlattenedData AS (
    SELECT
        v."$part_date" AS part_date,
        p.fc_id AS user_id,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        CAST(t.after AS BIGINT) AS balance
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN UNNEST(v.a_rst) AS t
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'item_change'
      AND CAST(t.id AS BIGINT) = 10009
),

LatestState AS (
    SELECT
        part_date,
        user_id,
        balance,
        ROW_NUMBER() OVER (
            PARTITION BY part_date, user_id
            ORDER BY event_time DESC NULLS LAST
        ) AS rn
    FROM FlattenedData
)

SELECT
    part_date AS "日期",
    AVG(balance) AS "平均红钻持仓"
FROM LatestState
WHERE rn = 1
GROUP BY 1
ORDER BY 1 DESC;
