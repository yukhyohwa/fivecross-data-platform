/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计 7月1日 - 7月21日 韩国大区 新用户 与 60天回流用户 中 流失用户 (7天未登录) 
           流失前倒数第 3 步、倒数第 2 步、最后 1 步的事件 (主动行为 event_name，连续去重) 路径分布及占比
           (新用户为 7.1-7.21 期间首次活跃/注册的 1022 名真实新用户)
运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
时间宏   : ${PartDate:date1} (默认/建议时间范围: 2026-07-01 至 2026-07-21)

核心逻辑:
  1. 人群定义:
     - 新用户 (New Users)           : 选定期间 (7.1-7.21) 内首次活跃/触发 NUU 的新用户 (基数: 1022)
     - 回流用户(60天) (Return Users) : 距上一次活跃日期 (prev_log_date) >= 60 天的用户
  2. 流失判定 (7天未登录):
     - 在观察期截止至当前日，超过 7 天未登录活跃的用户
  3. 主动行为提取与过滤:
     - 排除服务器被动事件 (snapshot, user_snapshot, email, system_mail, push 等)
     - 关键修复: 通过 UserRoleMap 双重匹配 (直接 lcm_id + role_id 转换)
       确保非登录事件 (#account_id = role_id) 也能正确关联到流失用户的 lcm_id
  4. 路径序列与去重:
     - 去除连续重复相同事件，倒序提取流失前倒数第3步、倒数第2步、最后1步事件组合

输出字段 :
  用户类别, 倒数第三步事件, 倒数第二步事件, 最后1步事件, 流失人数, 占比(%)
================================================================================
*/

WITH ScanConfig AS (
    -- 1. [性能优化] 自动计算选定时间范围边界 (默认: 2026-07-01 至 2026-07-21)
    --    同时定义 7天未登录的流失截止时间点
    SELECT
        DATE '2026-07-01' AS target_start_date,
        DATE '2026-07-21' AS target_end_date,
        DATE '2026-07-28' AS observation_end_date,
        DATE '2026-07-21' AS churn_cutoff_date
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
      AND v."$part_date" <= CAST(sc.observation_end_date AS VARCHAR)
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

LoginSuccesses AS (
    -- 流失判定只使用明确的登录成功事件；NUU 和其他事件均不视为登录活跃。
    SELECT DISTINCT
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        CAST(v."$part_date" AS DATE) AS log_date
    FROM ta.v_event_22 v
    CROSS JOIN ScanConfig sc
    WHERE v."$part_event" = 'LOGIN_SUCCESS'
      AND v."#account_id" IS NOT NULL
      AND v."#account_id" <> ''
      AND v."$part_date" <= CAST(sc.observation_end_date AS VARCHAR)
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
                  OR u.prev_log_date IS NULL
              )
          )
      )
    GROUP BY u.account_id,
        CASE
            WHEN u.reg_date BETWEEN sc.target_start_date AND sc.target_end_date THEN '1.新用户'
            ELSE '2.回流用户(60天)'
        END
),

UserLastLogin AS (
    -- 6. 确定每个目标用户的全周期最后登录活跃日期
    SELECT
        u.account_id,
        u.user_type,
        MAX(d.log_date) AS final_login_date
    FROM TargetUsers u
    LEFT JOIN LoginSuccesses d ON u.account_id = d.account_id
    GROUP BY u.account_id, u.user_type
),

ChurnedUsers AS (
    -- 7. 判定流失用户 (最后登录日距离今天 >= 7天)
    SELECT
        u.account_id,
        u.user_type,
        u.final_login_date
    FROM UserLastLogin u
    CROSS JOIN ScanConfig sc
    WHERE u.final_login_date IS NULL
       OR u.final_login_date <= sc.churn_cutoff_date
),

CohortChurnTotals AS (
    -- 8. 统计各人群总流失人数基数
    SELECT
        user_type,
        COUNT(DISTINCT account_id) AS total_churned_users
    FROM ChurnedUsers
    GROUP BY user_type
),

UserRoleMap AS (
    -- 9. 构建 lcm_id (account_id) → role_id 映射表
    --    [关键] 非登录事件的 #account_id 是 role_id，需要此表做转换
    SELECT
        CAST("#account_id" AS VARCHAR) AS account_id,
        COALESCE(
            CAST("user_id" AS VARCHAR),
            JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
        ) AS role_id
    FROM ta.v_event_22
    CROSS JOIN ScanConfig sc
    WHERE "$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND "$part_date" <= CAST(sc.observation_end_date AS VARCHAR)
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND COALESCE(
          CAST("user_id" AS VARCHAR),
          JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
      ) IS NOT NULL
      AND COALESCE(
          CAST("user_id" AS VARCHAR),
          JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
      ) <> ''
    GROUP BY 1, 2
),

UserRawEvents AS (
    -- 10. 提取流失用户的主动行为事件日志
    --     [关键修复] 通过双重匹配:
    --       a. 登录类事件: e."#account_id" (lcm_id) = c.account_id
    --       b. 非登录事件: e."#account_id" (role_id) → UserRoleMap → c.account_id
    SELECT DISTINCT
        c.account_id,
        c.user_type,
        e."$part_event" AS event_name,
        CAST(e."$part_date" AS DATE) AS part_date,
        e."#event_time" AS event_time
    FROM ta.v_event_22 e
    CROSS JOIN ScanConfig sc
    -- 通过 role_id → lcm_id 映射做转换 (LEFT JOIN, 用于非登录事件)
    LEFT JOIN UserRoleMap rm ON CAST(e."#account_id" AS VARCHAR) = rm.role_id
    -- 双重匹配: 直接 lcm_id 命中 OR 经 role_id 转换后命中
    INNER JOIN ChurnedUsers c ON (
        CAST(e."#account_id" AS VARCHAR) = c.account_id
        OR rm.account_id = c.account_id
    )
    WHERE e."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND e."$part_date" <= CAST(sc.observation_end_date AS VARCHAR)
      -- 仅保留玩家主动参与行为，排除服务器被动定时事件
      AND e."$part_event" NOT LIKE '%snapshot%'
      AND e."$part_event" NOT IN (
          'user_snapshot', 'NUU', 'email', 'system_mail', 'mail',
          'push_notification', 'server_push'
      )
),

UserOrderedEvents AS (
    -- 11. 标注前序事件名称，准备进行连续相同事件压缩
    SELECT
        account_id,
        user_type,
        event_name,
        part_date,
        event_time,
        LAG(event_name, 1) OVER (
            PARTITION BY account_id 
            ORDER BY part_date ASC, event_time ASC
        ) AS prev_event_name
    FROM UserRawEvents
),

UserDedupEvents AS (
    -- 12. 去重连续重复的相同事件 (连续重复事件压缩)，并逆序编号
    SELECT
        account_id,
        user_type,
        event_name,
        part_date,
        event_time,
        ROW_NUMBER() OVER (
            PARTITION BY account_id 
            ORDER BY part_date DESC, event_time DESC
        ) AS reverse_step_rn
    FROM UserOrderedEvents
    WHERE prev_event_name IS NULL OR event_name <> prev_event_name
),

UserLast3Steps AS (
    -- 13. 行列转换提取每个流失用户的倒数第3步、倒数第2步、最后1步事件
    SELECT
        account_id,
        user_type,
        MAX(CASE WHEN reverse_step_rn = 1 THEN event_name END) AS last_1st_event,
        MAX(CASE WHEN reverse_step_rn = 2 THEN event_name END) AS last_2nd_event,
        MAX(CASE WHEN reverse_step_rn = 3 THEN event_name END) AS last_3rd_event
    FROM UserDedupEvents
    WHERE reverse_step_rn <= 3
    GROUP BY account_id, user_type
)

-- 14. 汇总输出两类人群流失前 3 步事件组合分布及占比
SELECT
    u.user_type AS "用户类别",
    COALESCE(s.last_3rd_event, '无(不足3步)') AS "倒数第三步事件",
    COALESCE(s.last_2nd_event, '无(不足2步)') AS "倒数第二步事件",
    COALESCE(s.last_1st_event, '无(不足1步)') AS "最后1步事件",
    COUNT(DISTINCT u.account_id) AS "流失人数",
    ROUND(
        COUNT(DISTINCT u.account_id) * 100.0 / NULLIF(c.total_churned_users, 0),
        2
    ) AS "占比(%)"
FROM ChurnedUsers u
LEFT JOIN UserLast3Steps s
    ON u.account_id = s.account_id AND u.user_type = s.user_type
JOIN CohortChurnTotals c ON u.user_type = c.user_type
GROUP BY u.user_type, s.last_3rd_event, s.last_2nd_event, s.last_1st_event, c.total_churned_users
ORDER BY u.user_type, "流失人数" DESC
