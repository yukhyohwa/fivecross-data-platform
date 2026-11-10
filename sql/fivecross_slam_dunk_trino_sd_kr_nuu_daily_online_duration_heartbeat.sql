/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计 7月1日 - 7月26日 韩国大区 每日新增用户(NUU) 的在线时长 (心跳法)
计算方法 : 修正心跳法 — 提取主动交互事件，按用户与日期升序，相邻事件间隔 < 120 秒部分累加为在线时长。
用户标识 : 结合 #account_id, lcm_id, mabg_uid, #user_id 进行 COALESCE 级联处理，确保账号不遗漏。
事件过滤 : 严格排除被动/后台系统事件 (如 user_snapshot, snapshot, email, receive_mail, push 等)。
时间范围 : 2026-07-01 至 2026-07-26 (支持数数后台时间宏 ${PartDate:date1})
================================================================================
*/

WITH ScanConfig AS (
    -- 1. [动态时间窗口配置] 自动解析数数后台传入的时间筛选宏 ${PartDate:date1}（如选择 7月1日 至 7月26日）
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_22
    WHERE ${PartDate:date1}
),

-- 2. 提取 7.1 ~ 7.26 每日新增用户 (NUU) 队列
NewUserCohort AS (
    SELECT
        COALESCE(
            NULLIF(CAST(v."#account_id" AS VARCHAR), ''),
            NULLIF(CAST(v.mbga_uid AS VARCHAR), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.mbga_uid'), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.lcm_id'), ''),
            NULLIF(CAST(v."#user_id" AS VARCHAR), '')
        ) AS user_id,
        MIN(CAST(v."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'NUU'
      AND v."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND COALESCE(
            NULLIF(CAST(v."#account_id" AS VARCHAR), ''),
            NULLIF(CAST(v.mbga_uid AS VARCHAR), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.mbga_uid'), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.lcm_id'), ''),
            NULLIF(CAST(v."#user_id" AS VARCHAR), '')
          ) IS NOT NULL
    GROUP BY 1
),

-- 3. 提取新用户在注册首日 (D0) 的有效主动行为事件，计算心跳间隔 (gap_sec)
--    过滤规则：排除被动事件 snapshot, email, push 等，排除 app_start/app_exit 原生非交互事件
ActiveEventGaps AS (
    SELECT
        c.user_id,
        c.reg_date,
        v."#event_time",
        to_unixtime(CAST(v."#event_time" AS TIMESTAMP)) AS event_ts,
        LEAD(to_unixtime(CAST(v."#event_time" AS TIMESTAMP))) OVER (
            PARTITION BY c.user_id, c.reg_date
            ORDER BY v."#event_time" ASC
        ) - to_unixtime(CAST(v."#event_time" AS TIMESTAMP)) AS gap_sec
    FROM ta.v_event_22 v
    INNER JOIN NewUserCohort c 
        ON COALESCE(
            NULLIF(CAST(v."#account_id" AS VARCHAR), ''),
            NULLIF(CAST(v.mbga_uid AS VARCHAR), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.mbga_uid'), ''),
            NULLIF(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.lcm_id'), ''),
            NULLIF(CAST(v."#user_id" AS VARCHAR), '')
        ) = c.user_id
       AND CAST(v."$part_date" AS DATE) = c.reg_date  -- 仅统计注册首日 (D0) 在线时长
    WHERE ${PartDate:date1}
      -- 排除被动与系统后台事件
      AND v."$part_event" NOT IN ('user_snapshot', 'snapshot', 'email', 'receive_mail', 'push', 'system_push')
      AND LOWER(v."$part_event") NOT LIKE '%snapshot%'
      AND LOWER(v."$part_event") NOT LIKE '%email%'
      AND LOWER(v."$part_event") NOT LIKE '%push%'
      AND LOWER(v."$part_event") NOT LIKE '%ta_app%'
),

-- 4. 汇总每个新用户在首日 (D0) 的修正心跳时长 (分钟)
UserD0Duration AS (
    SELECT
        user_id,
        reg_date,
        SUM(CASE WHEN gap_sec IS NOT NULL AND gap_sec > 0 AND gap_sec < 120 THEN gap_sec ELSE 0 END) / 60.0 AS duration_min
    FROM ActiveEventGaps
    GROUP BY 1, 2
),

-- 5. 按注册日期 (7.1 ~ 7.26) 进行每日大盘汇总
DailyAgg AS (
    SELECT
        c.reg_date,
        COUNT(DISTINCT c.user_id) AS nuu_count,
        COUNT(DISTINCT d.user_id) AS active_nuu_count,
        SUM(COALESCE(d.duration_min, 0.0)) AS total_duration_min
    FROM NewUserCohort c
    LEFT JOIN UserD0Duration d 
        ON c.user_id = d.user_id 
       AND c.reg_date = d.reg_date
    GROUP BY 1
)

-- 6. 最终报表输出
SELECT
    CAST(reg_date AS VARCHAR)                                                     AS "注册日期",
    nuu_count                                                                     AS "新增用户数(NUU)",
    active_nuu_count                                                              AS "首日有行为用户数",
    ROUND(total_duration_min, 2)                                                  AS "首日总在线时长(分钟)",
    ROUND(total_duration_min / NULLIF(nuu_count, 0), 2)                          AS "新增人均在线时长(分钟)",
    ROUND((total_duration_min / NULLIF(nuu_count, 0)) / 60.0, 2)                 AS "新增人均在线时长(小时)"
FROM DailyAgg
ORDER BY reg_date ASC;
