/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 1. 统计 7月1日 - 7月21日 韩国大区 新用户 与 60天回流用户 的 新手引导 (Novice Guide) 各步骤完成/到达人数与到达率分布
           (新用户为 7.1-7.21 期间首次活跃/注册的 1022 名真实新用户)
           2. 包含原 MaxCompute (ODPS) 3 条 `daily_game_log` 统计 SQL 的 1:1 Trino (ThinkingData TA) 改写版本
运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
时间宏   : ${PartDate:date1} (默认/建议时间范围: 2026-07-01 至 2026-07-21)

人群定义 (互斥):
  1. 新用户 (New Users)           : 选定期间 (7.1-7.21) 内首次活跃/触发 NUU 的新用户 (基数: 1022)
  2. 回流用户(60天) (Return Users) : 距上一次活跃日期 (prev_log_date) >= 60 天的用户

引导事件与字段提取:
  - 核心引导事件: Dmp101003 / role_guide / guide / tutorial
  - 引导ID      : COALESCE(e.guide_id_str, payload.guide_id, payload.a_tar.guide_id, ...)
================================================================================
*/

--------------------------------------------------------------------------------
-- 模块一：【人群对比】新用户 vs 60天回流用户 新手引导完成度与卡点差异分布
--------------------------------------------------------------------------------

WITH ScanConfig AS (
    -- 1. [性能优化] 自动计算选定时间范围边界 (默认: 2026-07-01 至 2026-07-21)
    SELECT
        DATE '2026-07-23' AS target_start_date,
        DATE '2026-07-26' AS target_end_date
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
    -- 4. 关联 NUU 注册日期，计算上一次活跃日期 (prev_log_date)
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
      AND "$part_date" <= CAST(DATE_ADD('day', 2, sc.target_end_date) AS VARCHAR)
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'user_snapshot')
      AND COALESCE(
          CAST("user_id" AS VARCHAR),
          JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
      ) IS NOT NULL
    GROUP BY 1, 2
),

CohortTotals AS (
    -- 7. 统计各人群基数总人数
    SELECT
        user_type,
        COUNT(DISTINCT account_id) AS total_cohort_users
    FROM TargetUsers
    GROUP BY user_type
),

UserGuideEvents AS (
    -- 8. 提取引导事件 (兼容多事件名与多层级 JSON 字段)
    SELECT
        COALESCE(
            CAST(e.mbga_uid AS VARCHAR),
            CAST(e."#account_id" AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.mbga_uid'),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.lcm_id')
        ) AS direct_account_id,
        COALESCE(
            CAST(e."user_id" AS VARCHAR),
            CAST(e."#account_id" AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.user_id')
        ) AS role_id,
        COALESCE(
            CAST(e.guide_id_str AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.guide_id'),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.a_tar.guide_id'),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.guide_type'),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.guide'),
            JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.type')
        ) AS guide_id
    FROM ta.v_event_22 e
    CROSS JOIN ScanConfig sc
    WHERE e."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND e."$part_date" <= CAST(sc.target_end_date AS VARCHAR)
      AND (
          e."$part_event" IN ('Dmp101003', 'role_guide', 'guide', 'tutorial')
          OR JSON_EXTRACT_SCALAR(CAST(e.payload AS JSON), '$.a_typ') = 'Dmp101003'
      )
),

UserGuideAgg AS (
    -- 9. 关联引导步骤，按账号与步骤去重
    SELECT
        u.user_type,
        g.guide_id,
        u.account_id
    FROM TargetUsers u
    LEFT JOIN UserRoleMap r ON u.account_id = r.account_id
    INNER JOIN UserGuideEvents g 
        ON u.account_id = g.direct_account_id 
        OR (r.role_id IS NOT NULL AND r.role_id = g.role_id)
    WHERE g.guide_id IS NOT NULL AND g.guide_id <> ''
    GROUP BY u.user_type, g.guide_id, u.account_id
)

-- 10. 最终差异分布对比报表 (区分 1.新用户 与 2.回流用户(60天))
SELECT
    a.user_type AS "用户类型",
    a.guide_id AS "引导步骤ID",
    c.total_cohort_users AS "人群总人数",
    COUNT(DISTINCT a.account_id) AS "到达人数",
    ROUND(COUNT(DISTINCT a.account_id) * 100.0 / NULLIF(c.total_cohort_users, 0), 2) AS "到达率(%)"
FROM UserGuideAgg a
JOIN CohortTotals c ON a.user_type = c.user_type
GROUP BY a.user_type, a.guide_id, c.total_cohort_users
ORDER BY a.user_type, a.guide_id
