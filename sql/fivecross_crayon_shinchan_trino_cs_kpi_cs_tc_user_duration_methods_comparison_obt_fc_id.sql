/*
繁中 App18 OBT｜所选新用户群 D+0～D+7 在线时长：心跳法。
${PartDate:date1} 只筛 new_role 用户群，不是后续在线事件的观察日期过滤。
每个 fc_id 取所选区间内首次 new_role；观察至各自创角日 +7 日（含 D+0，共 8 个自然日）。
不扫描 OBT 全历史注册记录，因此这里是“期间有 new_role 的账号”，
无法仅凭这份 SQL 排除期间在新服/新角色再次创角的历史账号。
观察日志分区限定为队列最早创角日至最晚创角日 +7，再按账号各自日龄 0～7 过滤。
这两个日期来自已筛选的 new_role 队列，不是额外扫描全部日志求参数边界。
心跳法需观察窗口内非 app 业务事件，相邻间隔 0<=gap<120 秒累加，末尾不补偿。
直接使用业务事件自身 fc_id，不建立客户端身份映射。
按账号跨角色合并，黑名单排除 internal_users_new/is_water_new/is_windows_new。
输出四列，保留心跳法原字段名称；日期为观察自然日，天数为相对该批创角日期的日龄。
多天选群时同一观察日期可有不同 D+N；不把不同日龄混在一起。
补齐已到达的 D+0～D+7 无事件日为 0，未来日不输出；当日为部分日数据。
*/
WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new', 'is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
Cohort AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        MIN(CAST(v."$part_date" AS DATE)) AS cohort_date,
        MIN(CAST(v."#event_time" AS TIMESTAMP)) AS create_time
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'new_role'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND v."#event_time" IS NOT NULL
      AND b.fc_id IS NULL
    GROUP BY 1
),
ObservationBounds AS (
    SELECT
        CAST(MIN(cohort_date) AS VARCHAR) AS first_date,
        CAST(DATE_ADD('day', 7, MAX(cohort_date)) AS VARCHAR) AS last_date
    FROM Cohort
),
CohortEvents AS (
    SELECT
        c.fc_id,
        c.cohort_date,
        CAST(v."$part_date" AS DATE) AS dt,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time
    FROM ta.v_event_18 v
    CROSS JOIN ObservationBounds r
    JOIN Cohort c
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = c.fc_id
     AND v."$part_date" BETWEEN CAST(c.cohort_date AS VARCHAR)
                            AND CAST(DATE_ADD('day', 7, c.cohort_date) AS VARCHAR)
     AND CAST(v."#event_time" AS TIMESTAMP) >= c.create_time
    WHERE v."$part_date" BETWEEN r.first_date AND r.last_date
      AND v."#event_name" NOT LIKE '%app%'
),
EventGaps AS (
    SELECT e.*,
        TO_UNIXTIME(
            LEAD(event_time) OVER (
                PARTITION BY fc_id, dt ORDER BY event_time
            )
        ) - TO_UNIXTIME(event_time) AS heartbeat_gap
    FROM CohortEvents e
),
AccountDaily AS (
    SELECT
        dt, cohort_date, fc_id,
        SUM(CASE WHEN heartbeat_gap >= 0 AND heartbeat_gap < 120
                 THEN heartbeat_gap ELSE 0 END) AS heartbeat_seconds
    FROM EventGaps
    GROUP BY 1, 2, 3
),
DailyStats AS (
    SELECT
        dt, cohort_date,
        COUNT(*) AS heartbeat_dau,
        SUM(heartbeat_seconds) / NULLIF(COUNT(*), 0) / 60.0 AS heartbeat_avg
    FROM AccountDaily
    GROUP BY 1, 2
),
CohortDates AS (
    SELECT DISTINCT cohort_date FROM Cohort
),
ObservationDays AS (
    SELECT c.cohort_date, u.day_offset,
        DATE_ADD('day', u.day_offset, c.cohort_date) AS dt
    FROM CohortDates c
    CROSS JOIN UNNEST(SEQUENCE(0, 7)) AS u(day_offset)
    WHERE DATE_ADD('day', u.day_offset, c.cohort_date) <= CURRENT_DATE
)
SELECT
    CAST(d.dt AS VARCHAR) AS "日期",
    CONCAT('D+', CAST(d.day_offset AS VARCHAR)) AS "天数",
    COALESCE(s.heartbeat_dau, 0) AS "活跃人数(心跳法)",
    ROUND(COALESCE(s.heartbeat_avg, 0), 2) AS "日均在线_分钟(心跳法)"
FROM ObservationDays d
LEFT JOIN DailyStats s ON d.cohort_date = s.cohort_date AND d.dt = s.dt
ORDER BY d.cohort_date, d.day_offset;
