/*
================================================================================
蜡笔小新 - 所有充值用户画像
字段：user_id / account_id / 角色名 / 角色等级 / server / 注册时间 / 最后登陆日期 / 国家 / 系统
      充值金额(USD) / 最后付费商品 / 成功看广告次数 / 广告收入(USD) / 主线最远关卡 ID & 名称
说明：充值用户口径排除 sandbox / freebuy
================================================================================
*/

WITH

-- 黑名单
UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 有效充值明细（全量）
ValidCharges AS (
    SELECT
        "$part_date",
        "#event_time",
        "#user_id",
        "#account_id" AS account_id,
        product_id,
        pay_amount_usd
    FROM ta.v_event_13
    WHERE "$part_event" = 'charge'
      AND "#user_id" IS NOT NULL
      AND "#account_id" IS NOT NULL
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
      AND COALESCE(pay_amount_usd, 0) > 0
),

-- 所有有效充值账号及充值金额（全量）
ChargeSum AS (
    SELECT
        "#user_id",
        account_id,
        ROUND(SUM(pay_amount_usd), 2) AS revenue_usd
    FROM ValidCharges
    GROUP BY 1, 2
),

-- 每个充值账号最后一笔付费
LatestCharge AS (
    SELECT
        "#user_id",
        account_id,
        "$part_date" AS last_pay_date,
        product_id AS last_pay_product_id,
        pay_amount_usd AS last_pay_amount_usd
    FROM (
        SELECT
            vc.*,
            ROW_NUMBER() OVER (
                PARTITION BY "#user_id", account_id
                ORDER BY "#event_time" DESC, "$part_date" DESC
            ) AS rn
        FROM ValidCharges vc
    ) c
    WHERE rn = 1
),

-- 取每个充值账号最新一条角色名
LatestRole AS (
    SELECT
        "#user_id",
        account_id,
        role_name
    FROM (
        SELECT
            v."#user_id",
            v."#account_id" AS account_id,
            v.role_name,
            ROW_NUMBER() OVER (
                PARTITION BY v."#user_id", v."#account_id"
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_13 v
        JOIN ChargeSum cs
          ON v."#user_id" = cs."#user_id"
         AND v."#account_id" = cs.account_id
        WHERE v.role_name IS NOT NULL
    ) r
    WHERE rn = 1
),

-- 主表：所有充值账号
MatchedAccounts AS (
    SELECT
        cs."#user_id",
        cs.account_id,
        lr.role_name
    FROM ChargeSum cs
    LEFT JOIN LatestRole lr
      ON cs."#user_id" = lr."#user_id"
     AND cs.account_id = lr.account_id
),

-- 注册信息（new_role 首次）
NewUsers AS (
    SELECT
        "#user_id",
        "#account_id" AS account_id,
        MIN("$part_date") AS reg_date,
        MAX(server_id)    AS server_id
    FROM ta.v_event_13
    WHERE "$part_event" = 'new_role'
      AND "#account_id" IS NOT NULL
    GROUP BY 1, 2
),

-- 用户标签：国家 / 系统
UserProfile AS (
    SELECT
        "#user_id",
        MAX(CASE WHEN cluster_name = 'fixed_countrycode' THEN tag_value END) AS country,
        MAX(CASE WHEN cluster_name = 'fixed_os'          THEN tag_value END) AS os_type
    FROM user_result_cluster_13
    WHERE cluster_name IN ('fixed_countrycode', 'fixed_os')
    GROUP BY 1
),

-- 主线关卡（stage_type=1001）最远进度
StageFurthest AS (
    SELECT
        "#account_id" AS account_id,
        MAX(CAST(stage_id AS INTEGER)) AS max_stage_id
    FROM ta.v_event_13
    WHERE "#event_name" = 'stage_fight'
      AND a_rst[1].key = '1001'
      AND "#account_id" IS NOT NULL
    GROUP BY 1
),

-- 最后登录活跃日期
LastLogin AS (
    SELECT
        "#user_id",
        "#account_id" AS account_id,
        MAX("$part_date") AS last_login_date
    FROM ta.v_event_13
    WHERE "$part_event" = 'login'
      AND "#account_id" IS NOT NULL
    GROUP BY 1, 2
),

-- 角色等级（取最大等级值）
UserLevel AS (
    SELECT
        "#user_id",
        "#account_id" AS account_id,
        MAX(CAST(role_lev AS INTEGER)) AS role_level
    FROM ta.v_event_13
    WHERE role_lev IS NOT NULL
      AND "#account_id" IS NOT NULL
    GROUP BY 1, 2
),

-- 找到 account_id 与 #distinct_id 的关联映射（可能一对多）
AccountDistinctMapping AS (
    SELECT DISTINCT
        "#user_id",
        "#account_id" AS account_id,
        "#distinct_id" AS distinct_id
    FROM ta.v_event_13
    WHERE "#account_id" IS NOT NULL
      AND "#distinct_id" IS NOT NULL
),

-- 基于 #distinct_id 统计成功看广告次数与广告收益
AdSummaryByDistinct AS (
    SELECT
        v."#distinct_id" AS distinct_id,
        COUNT(
            CASE
                WHEN v."$part_event" = 'game_ad_impression'
                 AND CAST(v.status AS INTEGER) = 1
                THEN 1
            END
        ) AS ad_watch_count,
        SUM(
            CASE
                WHEN v."$part_event" = 'game_ad_impression'
                 AND CAST(v.status AS INTEGER) = 1
                THEN CASE
                    WHEN v."#os" = 'Android' THEN CAST(v.value AS DOUBLE) / 1000.0
                    ELSE CAST(v.value AS DOUBLE)
                END
                ELSE 0.0
            END
        ) AS ad_revenue_usd
    FROM ta.v_event_13 v
    WHERE v."$part_event" = 'game_ad_impression'
    GROUP BY 1
),

-- 将广告数据聚合回 account_id
AccountAdSummary AS (
    SELECT
        m."#user_id",
        m.account_id,
        SUM(a.ad_watch_count) AS ad_watch_count,
        ROUND(SUM(a.ad_revenue_usd), 4) AS ad_revenue_usd
    FROM AccountDistinctMapping m
    JOIN AdSummaryByDistinct a
      ON m.distinct_id = a.distinct_id
    GROUP BY 1, 2
)

SELECT
    ma."#user_id"                                AS user_id,
    ma.account_id                                AS account_id,
    COALESCE(ma.role_name, '未知')               AS "角色名",
    COALESCE(ul.role_level, 1)                   AS "角色等级",
    nu.server_id                                 AS server_id,
    nu.reg_date                                  AS "注册时间",
    COALESCE(ll.last_login_date, '未知')         AS "最后登陆日期",
    COALESCE(up.country, '未知')                 AS "国家",
    COALESCE(up.os_type, '未知')                 AS "系统",
    COALESCE(cs.revenue_usd, 0)                  AS "充值金额_USD",
    lc.last_pay_date                             AS "最后付费日期",
    lc.last_pay_product_id                       AS "最后付费商品ID",
    ldp."product_id@product_name_tc"             AS "最后付费商品名称",
    ldp."product_id@product_type"                AS "最后付费商品种类",
    COALESCE(lc.last_pay_amount_usd, 0)          AS "最后付费金额_USD",
    COALESCE(ad.ad_watch_count, 0)               AS "成功看广告次数",
    COALESCE(ad.ad_revenue_usd, 0.0)             AS "广告收入_USD",
    sf.max_stage_id                              AS "主线最远关卡ID",
    SPLIT(ds."stage_id@stage_name_real", ':')[1] AS "关卡大章",
    ds."stage_id@stage_name_real"               AS "关卡全名"

FROM MatchedAccounts ma
JOIN ChargeSum cs
  ON ma."#user_id" = cs."#user_id"
 AND ma.account_id = cs.account_id
LEFT JOIN UserBlacklist ub
  ON ma."#user_id" = ub."#user_id"
LEFT JOIN LatestCharge lc
  ON ma."#user_id" = lc."#user_id"
 AND ma.account_id = lc.account_id
LEFT JOIN ta_dim.dim_13_0_20639 ldp
  ON TRY_CAST(lc.last_pay_product_id AS INTEGER) = TRY_CAST(ldp."product_id@product_id" AS INTEGER)
LEFT JOIN NewUsers nu
  ON ma."#user_id" = nu."#user_id"
 AND ma.account_id = nu.account_id
LEFT JOIN UserProfile up
  ON ma."#user_id" = up."#user_id"
LEFT JOIN StageFurthest sf
  ON ma.account_id = sf.account_id
LEFT JOIN LastLogin ll
  ON ma."#user_id" = ll."#user_id"
 AND ma.account_id = ll.account_id
LEFT JOIN UserLevel ul
  ON ma."#user_id" = ul."#user_id"
 AND ma.account_id = ul.account_id
LEFT JOIN AccountAdSummary ad
  ON ma."#user_id" = ad."#user_id"
 AND ma.account_id = ad.account_id
LEFT JOIN ta_dim.dim_13_0_18203 ds
  ON sf.max_stage_id = ds."stage_id@stage_id"

WHERE ub."#user_id" IS NULL

ORDER BY "充值金额_USD" DESC;
