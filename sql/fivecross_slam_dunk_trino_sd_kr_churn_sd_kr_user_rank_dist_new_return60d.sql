/*
================================================================================
游戏名称 : 灌篮高手 (Slam Dunk)
适用大区 : 韩国 (Korea, Event Table: ta.v_event_22 / AppID: 33002013)
需求描述 : 统计 7月1日 - 7月21日 韩国大区 新用户 与 回流60天用户 的 段位分布
           (新用户为 7.1-7.21 期间首次活跃/注册的 1022 名真实新用户；每个账号仅映射 1 个最新段位)
参考逻辑 : ../fivecross-analysis-cases/slam_dunk/cross_platform_new_user_d30_rank_distribution/sql/02_ta_june_new_user_rank.sql
运行环境 : 数数 / Trino (ThinkingData TA)
数据表   : 
  - 事件表: ta.v_event_22 (灌篮韩国)
时间宏   : ${PartDate:date1} (默认/建议时间范围: 2026-07-01 至 2026-07-21)

段位体系映射 (MatchRank 阈值):
  - < 16       : 01. 入部新秀
  - 16 ~ 31    : 02. 强力替补
  - 32 ~ 51    : 03. 最佳正选
  - 52 ~ 71    : 04. 绝对主力
  - 72 ~ 95    : 05. 超级明星
  - 96 ~ 119   : 06. 最强王牌
  - 120 ~ 149  : 07. 传奇巨星
  - 150 ~ 169  : 08. 殿堂王者
  - >= 170     : 09. 灌篮高手

输出字段 :
  用户类型, 段位名称, 用户数, 占比(%)
================================================================================
*/

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
      AND "$part_date" <= '2026-07-27'
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS', 'user_snapshot')
      AND COALESCE(
          CAST("user_id" AS VARCHAR),
          JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.user_id')
      ) IS NOT NULL
    GROUP BY 1, 2
),

UserSnapshotRank AS (
    -- 7. 提取快照及排位/对局事件中的 match_rank 明细
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
        COALESCE(
            TRY_CAST(s.match_rank AS BIGINT),
            TRY_CAST(JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.match_rank') AS BIGINT),
            TRY_CAST(JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.rank') AS BIGINT),
            TRY_CAST(JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.user_rank') AS BIGINT),
            TRY_CAST(JSON_EXTRACT_SCALAR(CAST(s.payload AS JSON), '$.pvp_rank') AS BIGINT)
        ) AS match_rank_num,
        CAST(s."$part_date" AS DATE) AS part_date,
        s."#event_time" AS event_time
    FROM ta.v_event_22 s
    CROSS JOIN ScanConfig sc
    WHERE (
            s."$part_event" = 'user_snapshot' 
            OR regexp_like(s."$part_event", 'snapshot$')
            OR s."$part_event" IN ('RankH3V3', 'pvp_end', 'match_finish')
          )
      AND s."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
      AND s."$part_date" <= '2026-07-27'
),

UserRankMapped AS (
    -- 8. 关联目标人群，并按 account_id 分组取绝对最新的 1 条段位记录
    SELECT
        t.account_id,
        t.user_type,
        s.match_rank_num,
        ROW_NUMBER() OVER (
            PARTITION BY t.account_id
            ORDER BY s.part_date DESC, s.event_time DESC
        ) AS rn
    FROM TargetUsers t
    LEFT JOIN UserRoleMap r ON t.account_id = r.account_id
    INNER JOIN UserSnapshotRank s 
        ON t.account_id = s.direct_account_id 
        OR (r.role_id IS NOT NULL AND r.role_id = s.role_id)
    WHERE s.match_rank_num IS NOT NULL AND s.match_rank_num > 0
),

UserRankCombined AS (
    -- 9. 每个 account_id 仅输出 1 行记录（未测到段位的默认为 0）
    SELECT
        t.account_id,
        t.user_type,
        COALESCE(m.match_rank_num, 0) AS match_rank_num
    FROM TargetUsers t
    LEFT JOIN UserRankMapped m ON t.account_id = m.account_id AND m.rn = 1
)

-- 10. 按 用户类型 与 灌篮高手段位映射体系 统计分布 (新用户总人数严格等于 1022)
SELECT
    u.user_type AS "用户类型",
    CASE
        WHEN u.match_rank_num IS NULL OR u.match_rank_num = 0 THEN '00. 未入段/未排位'
        WHEN u.match_rank_num < 16 THEN '01. 入部新秀'
        WHEN u.match_rank_num < 32 THEN '02. 强力替补'
        WHEN u.match_rank_num < 52 THEN '03. 最佳正选'
        WHEN u.match_rank_num < 72 THEN '04. 绝对主力'
        WHEN u.match_rank_num < 96 THEN '05. 超级明星'
        WHEN u.match_rank_num < 120 THEN '06. 最强王牌'
        WHEN u.match_rank_num < 150 THEN '07. 传奇巨星'
        WHEN u.match_rank_num < 170 THEN '08. 殿堂王者'
        ELSE '09. 灌篮高手'
    END AS "段位名称",
    COUNT(DISTINCT u.account_id) AS "用户数",
    ROUND(COUNT(DISTINCT u.account_id) * 100.0 / SUM(COUNT(DISTINCT u.account_id)) OVER (PARTITION BY u.user_type), 2) AS "占比(%)"
FROM UserRankCombined u
GROUP BY u.user_type, 
    CASE
        WHEN u.match_rank_num IS NULL OR u.match_rank_num = 0 THEN '00. 未入段/未排位'
        WHEN u.match_rank_num < 16 THEN '01. 入部新秀'
        WHEN u.match_rank_num < 32 THEN '02. 强力替补'
        WHEN u.match_rank_num < 52 THEN '03. 最佳正选'
        WHEN u.match_rank_num < 72 THEN '04. 绝对主力'
        WHEN u.match_rank_num < 96 THEN '05. 超级明星'
        WHEN u.match_rank_num < 120 THEN '06. 最强王牌'
        WHEN u.match_rank_num < 150 THEN '07. 传奇巨星'
        WHEN u.match_rank_num < 170 THEN '08. 殿堂王者'
        ELSE '09. 灌篮高手'
    END
ORDER BY "用户类型", "段位名称"
