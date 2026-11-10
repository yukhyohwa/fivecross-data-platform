/*
================================================================================
蜡笔小新 - 5月8日后注册用户全量画像
字段：user_id / account_id / 角色名 / server / 注册时间 / 国家 / 系统
      充值金额(USD) / 主线最远关卡 ID & 名称
================================================================================
*/

WITH

-- 黑名单
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 5月8日后注册的全量用户（new_role 取首次）
NewUsers AS (
    SELECT
        "#user_id",
        "#account_id",
        MIN("$part_date")  AS reg_date,
        MAX(server_id)     AS server_id
    FROM ta.v_event_13
    WHERE "$part_event" = 'new_role'
      AND "$part_date" >= '2026-05-08'
    GROUP BY 1, 2
),

-- 用户标签：国家 / 系统
UserProfile AS (
    SELECT
        "#user_id",
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS country,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS os_type
    FROM user_result_cluster_13
    WHERE cluster_name IN ('fixed_country', 'fixed_os')
    GROUP BY 1
),

-- 角色名（取最新一条）
UsersInfo AS (
    SELECT account_id, role_name
    FROM (
        SELECT
            "#account_id" AS account_id,
            role_name,
            ROW_NUMBER() OVER (PARTITION BY "#account_id" ORDER BY "#event_time" DESC) AS rn
        FROM ta.v_event_13
        WHERE "$part_date" >= '2026-05-08'
          AND role_name IS NOT NULL
    )
    WHERE rn = 1
),

-- 充值汇总（5/8后，剔除 sandbox / freebuy）
ChargeSum AS (
    SELECT
        "#user_id",
        ROUND(SUM(pay_amount_usd), 2) AS revenue_usd
    FROM ta.v_event_13
    WHERE "$part_event" = 'charge'
      AND "$part_date" >= '2026-05-08'
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    GROUP BY 1
),

-- 主线关卡（stage_type=1001）最远进度：取 MAX(stage_id) per account
StageFurthest AS (
    SELECT
        "#account_id",
        MAX(CAST(stage_id AS INTEGER)) AS max_stage_id
    FROM ta.v_event_13
    WHERE "$part_date" >= '2026-05-08'
      AND "#event_name" = 'stage_fight'
      AND a_rst[1].key = '1001'   -- 主线副本
    GROUP BY 1
)

SELECT
    nu."#user_id"                                AS user_id,
    nu."#account_id"                             AS account_id,
    ui.role_name                                 AS 角色名,
    nu.server_id                                 AS server_id,
    nu.reg_date                                  AS 注册时间,
    COALESCE(up.country, '未知')                 AS 国家,
    COALESCE(up.os_type, '未知')                AS 系统,
    COALESCE(cs.revenue_usd, 0)                 AS 充值金额_USD,
    sf.max_stage_id                              AS 主线最远关卡ID,
    SPLIT(ds."stage_id@stage_name_real", ':')[1] AS 关卡大章,
    ds."stage_id@stage_name_real"               AS 关卡全名

FROM NewUsers nu
LEFT JOIN UserBlacklist  ub ON nu."#user_id"    = ub."#user_id"
LEFT JOIN UserProfile    up ON nu."#user_id"    = up."#user_id"
LEFT JOIN UsersInfo      ui ON nu."#account_id" = ui.account_id
LEFT JOIN ChargeSum      cs ON nu."#user_id"    = cs."#user_id"
LEFT JOIN StageFurthest  sf ON nu."#account_id" = sf."#account_id"
LEFT JOIN ta_dim.dim_13_0_18203 ds ON sf.max_stage_id = ds."stage_id@stage_id"

WHERE ub."#user_id" IS NULL          -- 排除黑名单

ORDER BY 充值金额_USD DESC;
