/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计 7月1日 - 7月21日 韩国大区 新用户 与 回流60天用户 的 精确等级分布
           人群识别窗口: 7.1-7.21；等级取截至 2026-07-27 的最新快照
           (不活跃用户的最后快照可能早于 7.21，因此快照扫描延伸至 7.27)
运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
  - 快照事件: user_snapshot
时间宏   : ${PartDate:date1} (默认/建议时间范围: 2026-07-01 至 2026-07-21)

人群定义 (互斥):
  1. 新用户 (New Users)           : 选定期间 (7.1-7.21) 内首次活跃/触发 NUU 的新用户 (基数: 1022)
  2. 回流用户(60天) (Return Users) : 距上一次活跃日期 (prev_log_date) >= 60 天的用户

输出字段 :
  用户类型, 等级, 用户数, 占比(%)
================================================================================
*/

WITH ScanConfig AS (
    -- 1. [性能优化] 自动计算选定时间范围边界 (默认: 2026-07-01 至 2026-07-21)
    --    snapshot_end_date: 快照/等级扫描截止日，取至 7月27日（覆盖流失不活跃用户的最后快照）
    SELECT
        DATE '2026-07-23' AS target_start_date,
        DATE '2026-07-26' AS target_end_date,
        DATE '2026-07-27' AS snapshot_end_date
),

UserRegDate AS (
    -- 2. 提取用户的 NUU 事件首发时间 (NUU 事件中的 #account_id 即为 lcm_id)
    SELECT
        CAST("#account_id" AS VARCHAR) AS account_id,
        MIN(CAST("$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_22
    WHERE "$part_event" = 'NUU'
      AND "#account_id" IS NOT NULL
      AND "#account_id" <> ''
    GROUP BY 1
),

DailyLogins AS (
    -- 3. 提取每日活跃日志 (LOGIN_SUCCESS / NUU 中的 #account_id 即为 lcm_id)
    SELECT DISTINCT
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."$part_date" AS DATE) AS log_date
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE v."#account_id" IS NOT NULL 
      AND v."#account_id" <> ''
      AND v."$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND v."$part_date" >= CAST(DATE_ADD('day', -65, sc.target_start_date) AS VARCHAR)
      AND v."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
),

UserStatus AS (
    -- 4. 关联 NUU 注册日期，并计算上一次活跃日期 (prev_log_date)
    SELECT
        d.account_id,
        d.log_date,
        r.reg_date,                                                                             -- NUU创角日期 (迁移前老用户为 NULL)
        COALESCE(r.reg_date, MIN(d.log_date) OVER (PARTITION BY d.account_id)) AS first_log_date,
        LAG(d.log_date, 1) OVER (PARTITION BY d.account_id ORDER BY d.log_date) AS prev_log_date
    FROM DailyLogins d
    LEFT JOIN UserRegDate r ON d.account_id = r.account_id
),

TargetUsers AS (
    -- 5. 划分目标人群:
    --    新用户  : NUU 创角时间在选定窗口内 (直接用 reg_date，避免迁移老用户被误判为新用户)
    --    回流用户 : 明确的老用户 (reg_date 为 NULL 或在窗口前) + 上次登录间隔 >= 60 天
    SELECT
        u.account_id,
        CASE
            WHEN u.reg_date BETWEEN sc.target_start_date AND sc.target_end_date THEN '1.新用户'
            ELSE '2.回流用户(60天)'
        END AS user_type
    FROM UserStatus u
    CROSS JOIN ScanConfig sc
    WHERE u.log_date BETWEEN sc.target_start_date AND sc.target_end_date
      AND (
          -- 新用户: NUU 创角在窗口内
          (u.reg_date BETWEEN sc.target_start_date AND sc.target_end_date)
          -- 回流用户: 非新用户 + 距上次登录 >= 60 天
          OR (
              u.reg_date IS NULL
              AND (
                  (u.prev_log_date IS NOT NULL AND DATE_DIFF('day', u.prev_log_date, u.log_date) >= 60)
                  OR (u.prev_log_date IS NULL)  -- DailyLogins 窗口内无先前登录 = 至少65天未登录 = 必是回流
              )
          )
      )
    GROUP BY u.account_id,
        CASE
            WHEN u.reg_date BETWEEN sc.target_start_date AND sc.target_end_date THEN '1.新用户'
            ELSE '2.回流用户(60天)'
        END
),

UserRoleMap AS (
    -- 6. 构建平台账号 account_id (lcm_id) 与 其它非登录事件中的 role_id (#account_id / user_id) 映射
    SELECT
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(
            CAST("user_id" AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
        ) AS role_id
    FROM ta.v_event_22
    CROSS JOIN ScanConfig sc
    WHERE "$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND "$part_date" <= CAST(sc.snapshot_end_date AS VARCHAR)
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'user_snapshot')
      AND COALESCE(
          CAST("user_id" AS VARCHAR),
          JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
      ) IS NOT NULL
    GROUP BY 1, 2
),

UserSnapshotLevel AS (
    -- 7. 从 user_snapshot / snapshot 事件中提取 level 明细
    SELECT
        COALESCE(
            CAST(s.mbga_uid AS VARCHAR),
            CAST(s."#account_id" AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.mbga_uid'),
            JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.lcm_id')
        ) AS direct_account_id,
        COALESCE(
            CAST(s."user_id" AS VARCHAR),
            CAST(s."#account_id" AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.user_id')
        ) AS role_id,
        TRY_CAST(s.level AS BIGINT) AS snap_level,
        CAST(s."$part_date" AS DATE) AS part_date,
        s."#event_time" AS event_time
    FROM ta.v_event_22 s
    CROSS JOIN ScanConfig sc
    WHERE (s."$part_event" = 'user_snapshot' OR regexp_like(s."$part_event", 'snapshot$'))
      AND s."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND s."$part_date" <= CAST(sc.snapshot_end_date AS VARCHAR)  -- 扫描至 7.27，覆盖不活跃用户的历史快照
      AND TRY_CAST(s.level AS BIGINT) > 0
),

UserLevelMapped AS (
    -- 8. 关联目标人群，并按 account_id 分组取绝对最新的 1 条等级
    SELECT
        t.account_id,
        t.user_type,
        s.snap_level,
        ROW_NUMBER() OVER (
            PARTITION BY t.account_id
            ORDER BY s.part_date DESC, s.event_time DESC
        ) AS rn
    FROM TargetUsers t
    LEFT JOIN UserRoleMap r ON t.account_id = r.account_id
    INNER JOIN UserSnapshotLevel s 
        ON t.account_id = s.direct_account_id 
        OR (r.role_id IS NOT NULL AND r.role_id = s.role_id)
),

UserLevelCombined AS (
    -- 9. 每个 account_id 仅输出 1 行记录
    SELECT
        t.account_id,
        t.user_type,
        COALESCE(m.snap_level, 1) AS user_level
    FROM TargetUsers t
    LEFT JOIN UserLevelMapped m ON t.account_id = m.account_id AND m.rn = 1
)

-- 10. 按 用户类型 与 精确等级 统计分布 (总人数 1:1 匹配 NUU 新用户总数 1022)
SELECT
    u.user_type AS "用户类型",
    u.user_level AS "等级",
    COUNT(DISTINCT u.account_id) AS "用户数",
    ROUND(COUNT(DISTINCT u.account_id) * 100.0 / SUM(COUNT(DISTINCT u.account_id)) OVER (PARTITION BY u.user_type), 2) AS "占比(%)"
FROM UserLevelCombined u
GROUP BY u.user_type, u.user_level
ORDER BY "用户类型", "等级"
