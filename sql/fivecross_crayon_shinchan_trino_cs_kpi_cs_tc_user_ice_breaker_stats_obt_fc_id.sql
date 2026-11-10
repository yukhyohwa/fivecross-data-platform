/*
================================================================================
Game       : Crayon Shin-chan (蜡笔小新) - TC OBT
Description: 首充破冰金额档位及 D1/D3/D7 活跃留存分布，账号口径使用 fc_id。
Environment: Trino
Tables     : ta.v_event_18 / user_result_cluster_18 / ta_dim.ta_exchange

口径：
1. OBT 从 2026-10-14 开始；先确定每个 fc_id 的首次 OBT new_role。
2. 首充为账号创角后的第一笔有效 charge；排除 sandbox、is_freebuy。
3. 首充日收入为该账号首充自然日内全部有效充值的 USD 总额。
4. 充值黑名单为 is_water_new、is_windows_new；使用 #varchar_id 关联 fc_id。
5. OS 和地区取首次 OBT 创角记录；地区统一为“港澳台”和“其他”。
6. 留存仅使用 new_role/login；D1/D3/D7 未成熟时不进入对应分母。
7. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/

WITH
Config AS (
    SELECT
        DATE '2026-10-14' AS obt_start_date,
        DATE_ADD('day', -1, CURRENT_DATE) AS mature_end_date
),

ScanConfig AS (
    SELECT
        MIN(CAST(v."$part_date" AS DATE)) AS target_start_date,
        MAX(CAST(v."$part_date" AS DATE)) AS target_end_date,
        MAX(c.obt_start_date) AS obt_start_date,
        MAX(c.mature_end_date) AS mature_end_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('new_role', 'login')
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

--------------------------------------------------------------------------------
-- 完整 OBT 历史中取每个账号第一次 new_role，避免同账号多角色重复
--------------------------------------------------------------------------------
AccountRegistrationRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."$part_date" AS DATE) AS reg_date,
        CAST(v."#event_time" AS TIMESTAMP) AS reg_event_time,
        COALESCE(NULLIF(TRIM(CAST(v.os AS VARCHAR)), ''), '未知') AS os_type,
        CASE
            WHEN UPPER(TRIM(CAST(v.country AS VARCHAR))) IN (
                'TW', 'TWN', 'HK', 'HKG', 'MO', 'MAC',
                '台湾', '台灣', '臺灣', '中国台湾', '中國台灣', '中國臺灣',
                '香港', '中国香港', '中國香港',
                '澳门', '澳門', '中国澳门', '中國澳門',
                '港澳台', '台港澳', 'TAIWAN', 'HONG KONG', 'MACAU', 'MACAO'
            ) THEN '港澳台'
            ELSE '其他'
        END AS country_name,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST,
                     CAST(v.os AS VARCHAR) ASC NULLS LAST,
                     CAST(v.country AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),

AccountProfile AS (
    SELECT fc_id, reg_date, reg_event_time, os_type, country_name
    FROM AccountRegistrationRanked
    WHERE rn = 1
),

EligibleAccounts AS (
    SELECT p.*
    FROM AccountProfile p
    LEFT JOIN UserBlacklist b ON p.fc_id = b.fc_id
    WHERE b.fc_id IS NULL
),

--------------------------------------------------------------------------------
-- 首充候选：扫描 OBT 开服至报表结束日，确保找到真正的历史首充
--------------------------------------------------------------------------------
ValidChargeHistory AS (
    SELECT
        p.fc_id,
        p.os_type,
        p.country_name,
        CAST(v."$part_date" AS DATE) AS pay_date,
        v."$part_date",
        v.pay_currency,
        TRY_CAST(v.pay_amount AS DOUBLE) AS pay_amount
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

FirstPurchaseEver AS (
    SELECT fc_id, MIN(pay_date) AS first_pay_date
    FROM ValidChargeHistory
    GROUP BY 1
),

IceBreakerDetail AS (
    SELECT
        c.fc_id,
        c.os_type,
        c.country_name,
        fp.first_pay_date,
        SUM(c.pay_amount / COALESCE(TRY_CAST(s5.exchange AS DOUBLE), 1.0)) AS first_day_revenue_usd
    FROM ValidChargeHistory c
    INNER JOIN FirstPurchaseEver fp
        ON c.fc_id = fp.fc_id
       AND c.pay_date = fp.first_pay_date
    CROSS JOIN ScanConfig sc
    LEFT JOIN ta_dim.ta_exchange s5
        ON c."$part_date" = s5.ex_date
       AND c.pay_currency = s5.currency
    WHERE fp.first_pay_date BETWEEN sc.target_start_date AND sc.target_end_date
    GROUP BY 1, 2, 3, 4
),

--------------------------------------------------------------------------------
-- 扫描目标首充日之后最多 7 天的账号活跃
--------------------------------------------------------------------------------
UserActivity AS (
    SELECT
        p.fc_id,
        CAST(v."$part_date" AS DATE) AS activity_date
    FROM ta.v_event_18 v
    INNER JOIN EligibleAccounts p
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = p.fc_id
       AND CAST(v."#event_time" AS TIMESTAMP) >= p.reg_event_time
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" IN ('new_role', 'login')
      AND v."$part_date" >= CAST(sc.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(
          LEAST(DATE_ADD('day', 7, sc.target_end_date), CURRENT_DATE)
          AS VARCHAR
      )
    GROUP BY 1, 2
),

IceBreakerRetention AS (
    SELECT
        ib.fc_id,
        ib.first_pay_date,
        MAX(CASE WHEN ua.activity_date = DATE_ADD('day', 1, ib.first_pay_date) THEN 1 ELSE 0 END) AS is_ret_1,
        MAX(CASE WHEN ua.activity_date = DATE_ADD('day', 3, ib.first_pay_date) THEN 1 ELSE 0 END) AS is_ret_3,
        MAX(CASE WHEN ua.activity_date = DATE_ADD('day', 7, ib.first_pay_date) THEN 1 ELSE 0 END) AS is_ret_7
    FROM IceBreakerDetail ib
    LEFT JOIN UserActivity ua ON ib.fc_id = ua.fc_id
    GROUP BY 1, 2
),

IceBreakerTier AS (
    SELECT
        ib.*,
        CASE
            WHEN ib.first_day_revenue_usd <= 0.99 THEN 'a.(0, 0.99]'
            WHEN ib.first_day_revenue_usd <= 4.99 THEN 'b.(0.99, 4.99]'
            WHEN ib.first_day_revenue_usd <= 9.99 THEN 'c.(4.99, 9.99]'
            WHEN ib.first_day_revenue_usd <= 19.99 THEN 'd.(9.99, 19.99]'
            WHEN ib.first_day_revenue_usd <= 49.99 THEN 'e.(19.99, 49.99]'
            WHEN ib.first_day_revenue_usd <= 99.99 THEN 'f.(49.99, 99.99]'
            ELSE 'g.(99.99, ∞]'
        END AS recharge_tier
    FROM IceBreakerDetail ib
),

FinalAggregation AS (
    SELECT
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', ib.first_pay_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', ib.first_pay_date) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', ib.first_pay_date) AS VARCHAR)
            ELSE '已合并'
        END AS "时间维度",
        CASE WHEN ${Selector:ostype} THEN ib.os_type ELSE '已合并' END AS "系统类型",
        CASE WHEN ${Selector:country} THEN ib.country_name ELSE '已合并' END AS "国家",

        COUNT(DISTINCT ib.fc_id) AS "破冰人数",
        SUM(ib.first_day_revenue_usd) AS "破冰总金额_USD",
        SUM(ib.first_day_revenue_usd) / NULLIF(COUNT(DISTINCT ib.fc_id), 0) AS "破冰ARPU",

        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'a.(0, 0.99]' THEN ib.fc_id END) AS "0.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'b.(0.99, 4.99]' THEN ib.fc_id END) AS "4.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'c.(4.99, 9.99]' THEN ib.fc_id END) AS "9.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'd.(9.99, 19.99]' THEN ib.fc_id END) AS "19.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'e.(19.99, 49.99]' THEN ib.fc_id END) AS "49.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'f.(49.99, 99.99]' THEN ib.fc_id END) AS "99.99档人数",
        COUNT(DISTINCT CASE WHEN ib.recharge_tier = 'g.(99.99, ∞]' THEN ib.fc_id END) AS "100+档人数",

        CAST(COUNT_IF(
            DATE_ADD('day', 1, ib.first_pay_date) <= sc.mature_end_date
            AND ret.is_ret_1 = 1
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 1, ib.first_pay_date) <= sc.mature_end_date), 0) AS "破冰次留",

        CAST(COUNT_IF(
            DATE_ADD('day', 3, ib.first_pay_date) <= sc.mature_end_date
            AND ret.is_ret_3 = 1
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 3, ib.first_pay_date) <= sc.mature_end_date), 0) AS "破冰3留",

        CAST(COUNT_IF(
            DATE_ADD('day', 7, ib.first_pay_date) <= sc.mature_end_date
            AND ret.is_ret_7 = 1
        ) AS DOUBLE)
        / NULLIF(COUNT_IF(DATE_ADD('day', 7, ib.first_pay_date) <= sc.mature_end_date), 0) AS "破冰7留",

        1 - (
            CAST(COUNT_IF(
                DATE_ADD('day', 7, ib.first_pay_date) <= sc.mature_end_date
                AND ret.is_ret_7 = 1
            ) AS DOUBLE)
            / NULLIF(COUNT_IF(DATE_ADD('day', 7, ib.first_pay_date) <= sc.mature_end_date), 0)
        ) AS "破冰7日流失率"
    FROM IceBreakerTier ib
    LEFT JOIN IceBreakerRetention ret
        ON ib.fc_id = ret.fc_id
       AND ib.first_pay_date = ret.first_pay_date
    CROSS JOIN ScanConfig sc
    GROUP BY 1, 2, 3
)

SELECT *
FROM FinalAggregation
ORDER BY 1 DESC;
