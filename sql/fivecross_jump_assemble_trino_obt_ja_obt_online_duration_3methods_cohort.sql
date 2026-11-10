/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : 修正心跳法 在线时长 — 选定日期范围 新增设备大群聚合版
Cohort  : 由参数 ${PartDate:date1} 指定日期范围内的 新增(注册)设备。
          (将每个设备在该范围内的【首次注册日】作为其个人的 D+0，然后进行全局大盘聚合)
Window  : D+0 ~ D+7
Method  : 修正心跳法 — 相邻事件间隔 < 120s 累加，末尾事件不补偿 (fixed_deviceid)
Output  : D+0 ~ D+7 (8行)，展示全局融合后的留存与日均时长
黑名单规则: 排除内部测试号(internal_users)与水设备账号(is_water)
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 0. 获取全局最大/最小日期
--------------------------------------------------------------------------------
EventDates AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS start_date,
        MAX(CAST("$part_date" AS DATE)) AS end_date
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
),

--------------------------------------------------------------------------------
-- 0b. 黑名单定义 (包含测试号与水设备号)
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 0c. 用户与设备映射定义 (UserProfileDetail_23)
--------------------------------------------------------------------------------
UserProfileDetail_23 AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid
    FROM user_result_cluster_23 
    WHERE cluster_name IN ('fixed_deviceid')
    GROUP BY "#varchar_id"
),

--------------------------------------------------------------------------------
-- 1. 目标设备队列：获取每个设备在选取范围内的【首次注册日期】作为其专属 cohort_date
--------------------------------------------------------------------------------
Cohort_M2 AS (
    SELECT 
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#distinct_id")) AS device_id,
        MIN(CAST(v."$part_date" AS DATE)) AS cohort_date
    FROM ta.v_event_23 v
    LEFT JOIN UserProfileDetail_23 s4 
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) = s4."#account_id"
    LEFT JOIN UserBlacklist ub 
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) = ub.lcx_id
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'NUU'
      AND ub.lcx_id IS NULL
    GROUP BY 1
),

--------------------------------------------------------------------------------
-- 2. 获取设备在相应日期范围内的所有单日统计时长 (修正心跳法)
--------------------------------------------------------------------------------
M2_Gaps AS (
    SELECT
        COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#distinct_id")) AS device_id,
        CAST(v."$part_date" AS DATE) AS report_date,
        LEAD(to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))) OVER (
            PARTITION BY COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#distinct_id")), v."$part_date"
            ORDER BY v."#event_time"
        ) - to_unixtime(parse_datetime(CAST(v."#event_time" AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) AS gap
    FROM ta.v_event_23 v
    LEFT JOIN UserProfileDetail_23 s4 
        ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id    AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id    AS VARCHAR) END,
            CASE WHEN LENGTH(CAST(v."#account_id"       AS VARCHAR)) = 36 THEN CAST(v."#account_id"       AS VARCHAR) END
        ) = s4."#account_id"
    INNER JOIN Cohort_M2 c2 
        ON COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', v."#distinct_id")) = c2.device_id
    WHERE v."$part_date" >= CAST((SELECT start_date FROM EventDates) AS VARCHAR)
      AND v."$part_date" <= CAST(DATE_ADD('day', 7, (SELECT end_date FROM EventDates)) AS VARCHAR)
      AND v."#event_name" NOT LIKE '%app%'
),

M2_DeviceDaily AS (
    SELECT
        device_id,
        report_date,
        SUM(CASE WHEN gap IS NOT NULL AND gap < 120 THEN gap ELSE 0 END) / 60.0 AS duration_min
    FROM M2_Gaps
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 3. 进行 全局同期群 X 目标日(D+n) 的大聚合
--------------------------------------------------------------------------------
-- 先用一个 CTE 生成 0-7，确保最终一定输出 8 行
DayOffsets AS (
    SELECT n AS day_offset FROM UNNEST(SEQUENCE(0, 7)) AS t(n)
),

M2_Agg AS (
    SELECT 
        DATE_DIFF('day', c.cohort_date, d.report_date) AS day_offset,
        COUNT(DISTINCT c.device_id) AS cohort_dau,
        SUM(d.duration_min) AS total_duration_min
    FROM Cohort_M2 c
    JOIN M2_DeviceDaily d 
        ON c.device_id = d.device_id 
       AND d.report_date >= c.cohort_date
       AND d.report_date <= DATE_ADD('day', 7, c.cohort_date)
    GROUP BY 1
),
M2_CohortSize AS (
    SELECT COUNT(DISTINCT device_id) AS total_cohort_dau FROM Cohort_M2
)

--------------------------------------------------------------------------------
-- 4. 最终输出：全局聚合的 D+0 ~ D+7
--------------------------------------------------------------------------------
SELECT
    CONCAT('D+', CAST(o.day_offset AS VARCHAR))                                 AS "天数",
    COALESCE((SELECT total_cohort_dau FROM M2_CohortSize), 0)                   AS "新增设备数",
    COALESCE(m2.cohort_dau, 0)                                                  AS "D+n活跃设备数",
    ROUND(COALESCE(m2.total_duration_min, 0) / NULLIF(m2.cohort_dau, 0), 2)     AS "日均在线时长(分钟)"

FROM DayOffsets o
LEFT JOIN M2_Agg m2 ON o.day_offset = m2.day_offset
ORDER BY o.day_offset ASC;
