/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 通过玩家昵称或 ID 模糊搜索用户画像
Description: 输入玩家昵称关键字或平台 ID，查询其基本画像信息。
             包含：注册时间、最后登陆时间、国家、系统、区服、累计充值金额 (USD)、段位等信息。
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    -- 排除测试与水军黑名单
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- 1. 昵称或 ID 模糊搜索：匹配角色名或 lcx_id，获取该账号最新的一条事件记录
RoleSearch AS (
    SELECT
        COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) AS lcx_id,
        e.rolecommon.role_id AS role_id,
        e.rolecommon.role_name AS role_name,
        e.rolecommon.zone_id AS zone_id,
        ROW_NUMBER() OVER (PARTITION BY COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) ORDER BY e."#event_time" DESC) AS rn
    FROM ta.v_event_23 e
    WHERE e."$part_date" >= '2026-06-24'
      AND e."$part_event" IN ('resource_change')
      AND e.rolecommon.role_name IS NOT NULL
      AND (
          e.rolecommon.role_name LIKE '%${roleinfo}%' 
          OR COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) LIKE '%${roleinfo}%'
      )
),

-- 保留最新的角色映射关系
MatchedAccounts AS (
    SELECT lcx_id, role_id, role_name, zone_id
    FROM RoleSearch
    WHERE rn = 1
),

-- 2. 玩家固化标签：国家、系统、渠道及注册日期 (源自 user_result_cluster_23)
UserProfile AS (
    SELECT
        "#varchar_id" AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_regdate', 'fixed_os', 'fixed_affcode', 'fixed_country')
    GROUP BY 1
),

-- 3. 累计充值汇总 (排除 Sandbox 充值)
ChargeSum AS (
    SELECT
        "#account_id" AS lcx_id,
        ROUND(SUM(CAST(e.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0)), 2) AS revenue_usd
    FROM ta.v_event_23 e
    LEFT JOIN ta_dim.ta_exchange s5 
        ON e."$part_date" = s5.ex_date 
        AND e.payload.cur = s5.currency
    WHERE e."$part_event" = 'PURCHASE'
      AND (e.payload.validationtype IS NULL OR e.payload.validationtype <> 'SANDBOX_RECEIPT')
      AND e."$part_date" >= '2024-03-27'
    GROUP BY 1
),

-- 4. 最后登录活跃日期
LastLogin AS (
    SELECT
        "#account_id" AS lcx_id,
        MAX(e."$part_date") AS last_login_date
    FROM ta.v_event_23 e
    WHERE e."$part_event" = 'LOGIN_SUCCESS'
      AND e."$part_date" >= '2026-06-24'
    GROUP BY 1
),

-- 5. 获取最新段位级别 (player_ladder_level)
UserLadder AS (
    SELECT 
        lcx_id,
        player_ladder_level
    FROM (
        SELECT 
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) AS lcx_id,
            CAST(e.player_ladder_level AS INTEGER) AS player_ladder_level,
            ROW_NUMBER() OVER(PARTITION BY COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) ORDER BY e."#event_time" DESC) AS rn
        FROM ta.v_event_23 e
        WHERE e."$part_date" >= '2024-03-27'
          AND e.player_ladder_level IS NOT NULL
    )
    WHERE rn = 1
)

-- 6. 关联整合并输出结果
SELECT
    ma.lcx_id                                    AS "用户ID (lcx_id)",
    ma.role_name                                 AS "角色名",
    ma.role_id                                   AS "角色ID",
    ma.zone_id                                   AS "区服ID",
    up.fixed_regdate                             AS "注册时间",
    COALESCE(ll.last_login_date, '未知')          AS "最后登陆日期",
    COALESCE(up.fixed_country, '未知')           AS "国家",
    COALESCE(up.fixed_os, '未知')                AS "系统",
    COALESCE(up.fixed_affcode, '未知')           AS "渠道",
    COALESCE(cs.revenue_usd, 0.0)                AS "充值金额_USD",
    COALESCE(ul.player_ladder_level, 0)          AS "最新段位"
FROM MatchedAccounts ma
LEFT JOIN UserBlacklist  ub ON ma.lcx_id = ub.lcx_id
LEFT JOIN UserProfile    up ON ma.lcx_id = up.lcx_id
LEFT JOIN ChargeSum      cs ON ma.lcx_id = cs.lcx_id
LEFT JOIN LastLogin      ll ON ma.lcx_id = ll.lcx_id
LEFT JOIN UserLadder     ul ON ma.lcx_id = ul.lcx_id
WHERE ub.lcx_id IS NULL -- 排除黑名单
ORDER BY "充值金额_USD" DESC;
