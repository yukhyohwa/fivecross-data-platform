/*
================================================================================
Game       : Slam Dunk KR
Environment: ThinkingData / Trino
Table      : ta.v_event_22

Description
  Count characters whose current ranked tier is Hall of Fame or above, segmented
  by 7-day, 30-day, and 90-day game-behavior activity.

Definition
  - Character grain: account_id + zone_id + role_id.
  - The reporting date is the latest date selected by ${PartDate:date1}.
  - One latest user_snapshot is retained for every character on that date.
  - Hall of Fame or above: match_rank >= 150.
  - Activity windows include the reporting date: last 7 / 30 / 90 calendar days.
  - Snapshots and platform-only events (NUU, PURCHASE, LOGIN_SUCCESS, and wallet
    transactions) do not qualify as game-behavior activity.

MaxCompute to Trino mapping
  - g33002013.daily_user_snapshot / dm_server_user_info_odps
    -> ta.v_event_22 user_snapshot.
  - Old rank_name / dim_rank mapping -> user_snapshot.match_rank threshold.
================================================================================
*/

WITH ScanConfig AS (
    SELECT
        MAX(CAST("$part_date" AS DATE)) AS report_date
    FROM ta.v_event_22
    WHERE ${PartDate:date1}
),

LatestUserSnapshot AS (
    SELECT
        sc.report_date,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v.zone AS VARCHAR) AS zone_id,
        CAST(v."user_id" AS VARCHAR) AS role_id,
        TRY_CAST(v.match_rank AS BIGINT) AS match_rank,
        ROW_NUMBER() OVER (
            PARTITION BY v."$part_date", v."#account_id", v.zone, v."user_id"
            ORDER BY v."#event_time" DESC
        ) AS rn
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE CAST(v."$part_date" AS DATE) = sc.report_date
      AND v."$part_event" = 'user_snapshot'
),

ActiveRoleLastDate AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(SPLIT(SPLIT(v.a_usr, '@')[1], '_')[3] AS VARCHAR) AS zone_id,
        CAST(SPLIT(v.a_usr, '@')[2] AS VARCHAR) AS role_id,
        MAX(CAST(v."$part_date" AS DATE)) AS last_active_date
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE CAST(v."$part_date" AS DATE)
              BETWEEN DATE_ADD('day', -89, sc.report_date) AND sc.report_date
      AND v."$part_event" IN ('Dmp101002')
      AND SPLIT(v.a_usr, '@')[2] IS NOT NULL
    GROUP BY 1, 2, 3
)

SELECT
    s.report_date AS "统计日期",
    COUNT_IF(a.last_active_date >= DATE_ADD('day', -6, s.report_date))
        AS "近7日活跃殿堂及以上角色数",
    COUNT_IF(a.last_active_date >= DATE_ADD('day', -29, s.report_date))
        AS "近30日活跃殿堂及以上角色数",
    COUNT_IF(a.last_active_date >= DATE_ADD('day', -89, s.report_date))
        AS "近90日活跃殿堂及以上角色数"
FROM LatestUserSnapshot s
LEFT JOIN ActiveRoleLastDate a
  ON s.account_id = a.account_id
 AND s.zone_id = a.zone_id
 AND s.role_id = a.role_id
WHERE s.rn = 1
  AND s.match_rank >= 150
GROUP BY s.report_date
ORDER BY s.report_date DESC;
