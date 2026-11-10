/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 充值用户明细
描述：按 5X 账号、角色、服务器汇总所选周期的有效充值金额。

口径：
1. OBT 从 2026-10-14 开始；账号使用 fc_id，同账号多角色共享首次注册日期。
2. 注册时间取 fc_id 在完整 OBT 历史中的首次 new_role 日期。
3. 角色名按 #account_id 取截至报表结束日的最新非空记录。
4. 有效充值排除 sandbox、is_freebuy。
5. 充值黑名单为 is_water_new、is_windows_new，使用 #varchar_id 关联 fc_id。
6. 第一列沿用原字段名 #user_id，但字段值为 fc_id；其余输出字段名称及顺序不变。
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
    WHERE v.${PartDate:date}
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
    CROSS JOIN Config c
    CROSS JOIN ReportRange r
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.report_end_date AS VARCHAR)
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
-- 每个角色取 OBT 期间截至报表结束日的最新角色名
--------------------------------------------------------------------------------
UsersInfoRanked AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        v.role_name,
        ROW_NUMBER() OVER (
            PARTITION BY CAST(v."#account_id" AS VARCHAR)
            ORDER BY v."#event_time" DESC NULLS LAST,
                     CAST(v.role_name AS VARCHAR) DESC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    CROSS JOIN ReportRange r
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(r.report_end_date AS VARCHAR)
      AND v.role_name IS NOT NULL
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
),

UsersInfo AS (
    SELECT account_id, role_name
    FROM UsersInfoRanked
    WHERE rn = 1
),

ChargeData AS (
    SELECT
        p.fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        v.server_id,
        p.reg_date,
        v."$part_date",
        v.pay_currency,
        TRY_CAST(v.pay_amount AS DOUBLE) AS pay_amount
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN Config c
    WHERE v.${PartDate:date}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
)

SELECT
    s1.fc_id AS "#user_id",
    s1.account_id AS "#account_id",
    s3.role_name,
    s1.server_id,
    CAST(s1.reg_date AS VARCHAR) AS "注册时间",
    ROUND(
        SUM(s1.pay_amount / COALESCE(TRY_CAST(s5.exchange AS DOUBLE), 1.0)),
        2
    ) AS "充值金额"
FROM ChargeData s1
LEFT JOIN UsersInfo s3 ON s1.account_id = s3.account_id
LEFT JOIN ta_dim.ta_exchange s5
    ON s1."$part_date" = s5.ex_date
   AND s1.pay_currency = s5.currency
GROUP BY 1, 2, 3, 4, 5
ORDER BY 6 DESC;
