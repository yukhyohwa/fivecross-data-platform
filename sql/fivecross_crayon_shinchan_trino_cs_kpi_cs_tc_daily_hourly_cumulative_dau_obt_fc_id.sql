/*
App18 TC OBT: hourly cumulative DAU, distinct fc_id across roles.
Date filtering: v.${PartDate:date}, directly on login/new_role partitions.
No date calendar, log-boundary scan, or registration-time gate.
Blacklist: internal_users_new, is_water_new, is_windows_new via #varchar_id.
First aggregate each account/day to its first hour; expand only daily counts to 24 hours.
The seven original output names are preserved.
Period start is the earliest active date returned by the selected event filter;
if the selected first day has no valid events, it is not represented in this start date.
Day N counts calendar days from that first active date.
Hours 0-23 are retained even for the current partial day.
*/
WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
UserFirstHour AS (
    SELECT
        CAST(v."$part_date" AS DATE) AS act_date,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        MIN(HOUR(CAST(v."#event_time" AS TIMESTAMP))) AS first_hour
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" IN ('new_role', 'login')
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND v."#event_time" IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1, 2
),
HourlyNewUsers AS (
    SELECT act_date, first_hour, COUNT(*) AS new_active_users
    FROM UserFirstHour
    GROUP BY 1, 2
),
DailyCounts AS (
    SELECT
        act_date,
        MAP_AGG(first_hour, new_active_users) AS hourly_counts,
        SUM(new_active_users) AS dau
    FROM HourlyNewUsers
    GROUP BY 1
),
HourlyStats AS (
    SELECT
        d.act_date,
        MIN(d.act_date) OVER () AS p_start,
        h.hr,
        d.dau,
        SUM(COALESCE(ELEMENT_AT(d.hourly_counts, h.hr), 0)) OVER (
            PARTITION BY d.act_date ORDER BY h.hr
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_dau
    FROM DailyCounts d
    CROSS JOIN UNNEST(SEQUENCE(0, 23)) AS h(hr)
)
SELECT
    s.p_start AS "时段起始日",
    CAST(s.act_date AS VARCHAR) AS "日期",
    DATE_DIFF('day', s.p_start, s.act_date) + 1 AS "第N天",
    CAST(s.hr AS VARCHAR) AS "小时",
    s.cumulative_dau AS "累计DAU",
    s.dau AS "当日DAU",
    ROUND(CAST(s.cumulative_dau AS DOUBLE) / NULLIF(s.dau, 0), 4) AS "累计占比"
FROM HourlyStats s
ORDER BY s.act_date, s.hr;
