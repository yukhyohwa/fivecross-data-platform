/*
================================================================================
蜡笔小新繁体 OBT - 限时伙伴/限时坐骑核心道具获得次数分布（fc_id 账号口径）

输出：每个活动一行，前列为活动信息，后列为：
- 获得1次人数
- 获得2次人数
- 获得3次人数
- 获得4次人数
- 获得5次及以上人数

数数日期参数：v.${PartDate:date1}
活动类型：1117=限时伙伴，1116=限时坐骑。
核心道具名称：活动 name 按“-”拆分后的第二段。
获得次数：汇总 active_reward.a_rst 中同名核心道具的实际增加数量；数量不可解析
或不为正时，该条核心道具奖励按1次计算。同一 fc_id 多角色合并。
过滤：OBT 自 2026-10-14 起，仅统计首次 OBT 创角后的事件；排除
internal_users_new、is_windows_new、is_water_new、活动ID=0及空 fc_id。
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
      AND v."$part_event" = 'active_reward'
),

UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_windows_new', 'is_water_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

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

/* 所选日期范围内全部有效限时伙伴、限时坐骑活动。 */
ActivityDim AS (
    SELECT
        TRY_CAST(v.type AS BIGINT) AS activity_type,
        CAST(TRY_CAST(v.id AS DECIMAL(38, 0)) AS VARCHAR) AS activity_id,
        MAX_BY(CAST(v.name AS VARCHAR), CAST(v."#event_time" AS TIMESTAMP)) AS activity_full_name,
        TRY(SPLIT(
            MAX_BY(CAST(v.name AS VARCHAR), CAST(v."#event_time" AS TIMESTAMP)),
            '-'
        )[2]) AS core_item_name,
        MIN(CAST(v."$part_date" AS DATE)) AS observed_start_date,
        MAX(CAST(v."$part_date" AS DATE)) AS observed_end_date
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'active_reward'
      AND TRY_CAST(v.type AS BIGINT) IN (1117, 1116)
      AND CAST(TRY_CAST(v.id AS DECIMAL(38, 0)) AS VARCHAR) <> '0'
    GROUP BY 1, 2
),

/* 每条核心道具奖励记录的获得数量。 */
CoreRewardRows AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        a.activity_type,
        a.activity_id,
        CASE
            WHEN COALESCE(
                TRY_CAST(u.item_after AS BIGINT) - TRY_CAST(u.item_before AS BIGINT),
                TRY_CAST(u.item_diff AS BIGINT)
            ) > 0
            THEN COALESCE(
                TRY_CAST(u.item_after AS BIGINT) - TRY_CAST(u.item_before AS BIGINT),
                TRY_CAST(u.item_diff AS BIGINT)
            )
            ELSE 1
        END AS obtained_count
    FROM ta.v_event_18 v
    INNER JOIN ActivityDim a
      ON TRY_CAST(v.type AS BIGINT) = a.activity_type
     AND CAST(TRY_CAST(v.id AS DECIMAL(38, 0)) AS VARCHAR) = a.activity_id
    INNER JOIN EligibleAccounts e
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = e.fc_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= e.reg_event_time
    CROSS JOIN UNNEST(v.a_rst) AS u(
        item_after, item_before, item_diff, item_id, item_key, item_name
    )
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'active_reward'
      AND TRIM(CAST(u.item_name AS VARCHAR)) = TRIM(a.core_item_name)
),

/* 每个活动、每个 fc_id 的核心道具累计获得次数。 */
UserCoreCount AS (
    SELECT
        activity_type,
        activity_id,
        fc_id,
        SUM(obtained_count) AS total_obtained_count
    FROM CoreRewardRows
    GROUP BY 1, 2, 3
),

ActivityStats AS (
    SELECT
        activity_type,
        activity_id,
        COUNT(DISTINCT fc_id) AS core_item_users,
        COUNT(DISTINCT CASE WHEN total_obtained_count = 1 THEN fc_id END) AS obtained_1_users,
        COUNT(DISTINCT CASE WHEN total_obtained_count = 2 THEN fc_id END) AS obtained_2_users,
        COUNT(DISTINCT CASE WHEN total_obtained_count = 3 THEN fc_id END) AS obtained_3_users,
        COUNT(DISTINCT CASE WHEN total_obtained_count = 4 THEN fc_id END) AS obtained_4_users,
        COUNT(DISTINCT CASE WHEN total_obtained_count >= 5 THEN fc_id END) AS obtained_5_plus_users
    FROM UserCoreCount
    GROUP BY 1, 2
)

SELECT
    CASE a.activity_type
        WHEN 1117 THEN '限时伙伴'
        WHEN 1116 THEN '限时坐骑'
    END AS "活动类型",
    a.activity_id AS "活动ID",
    a.activity_full_name AS "活动完整名称",
    a.core_item_name AS "核心道具名称",
    a.observed_start_date AS "活动观测开始日期",
    a.observed_end_date AS "活动观测结束日期",
    COALESCE(s.core_item_users, 0) AS "获得核心道具总人数",
    COALESCE(s.obtained_1_users, 0) AS "获得1次人数",
    COALESCE(s.obtained_2_users, 0) AS "获得2次人数",
    COALESCE(s.obtained_3_users, 0) AS "获得3次人数",
    COALESCE(s.obtained_4_users, 0) AS "获得4次人数",
    COALESCE(s.obtained_5_plus_users, 0) AS "获得5次及以上人数"
FROM ActivityDim a
LEFT JOIN ActivityStats s
  ON a.activity_type = s.activity_type
 AND a.activity_id = s.activity_id
ORDER BY
    a.observed_start_date DESC,
    a.activity_type DESC,
    a.activity_id;
