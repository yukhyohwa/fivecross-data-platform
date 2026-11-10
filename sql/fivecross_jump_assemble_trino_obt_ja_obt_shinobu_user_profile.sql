/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : 蝴蝶忍持有用户画像 + 养成信息
Description:
    查询指定日期范围内持有蝴蝶忍 card_id = 132 的用户信息。
    包含：
      - 用户ID、角色名、角色ID、区服
      - 注册时间、最后登录、国家、系统、渠道
      - 累计充值金额 USD、最新段位
      - 是否内部用户、是否水军用户、用户标记
      - 蝴蝶忍养成：等级、觉醒数、天赋数
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    -- 用户标记：内部用户 / 水军用户
    SELECT 
        "#varchar_id" AS lcx_id,
        MAX(CASE WHEN cluster_name = 'internal_users' THEN 1 ELSE 0 END) AS is_internal_user,
        MAX(CASE WHEN cluster_name = 'is_water' THEN 1 ELSE 0 END) AS is_water_user
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
    GROUP BY 1
),

-------------------------------------------------------
-- 1. 蝴蝶忍最新快照：取每个用户最新一条 card_id = 132 的养成状态
-------------------------------------------------------
ButterflyLatestSnapshot AS (
    SELECT
        lcx_id,
        role_id,
        card_id,
        card_name,
        card_level,
        awaken_count,
        talent_count,
        snap_date,
        latest_card_snapshot_time
    FROM (
        SELECT
            COALESCE(e.fc_sdk_common.lcx_id, e.sdkcommon.lcx_id, e."#account_id") AS lcx_id,
            e.rolecommon.role_id AS role_id,

            e.card_id,
            e.card_name,

            COALESCE(e.card_level, 0) AS card_level,

            COALESCE(
                cardinality(e.card_awake),
                0
            ) AS awaken_count,

            COALESCE(
                cardinality(
                    filter(
                        e.card_talent_slot,
                        x -> x <> '0' AND x <> ''
                    )
                ),
                0
            ) AS talent_count,

            e."$part_date" AS snap_date,
            e."#event_time" AS latest_card_snapshot_time,

            ROW_NUMBER() OVER (
                PARTITION BY 
                    COALESCE(e.fc_sdk_common.lcx_id, e.sdkcommon.lcx_id, e."#account_id"),
                    e.card_id
                ORDER BY e."#event_time" DESC
            ) AS rn

        FROM ta.v_event_23 e
        WHERE e."$part_event" = 'daily_role_card_snapshot'
          AND e."$part_date" BETWEEN '2026-07-01' AND '2026-07-08'
          AND e.card_id = 132
    )
    WHERE rn = 1
),

-------------------------------------------------------
-- 2. 获取用户最新角色信息
-------------------------------------------------------
LatestRole AS (
    SELECT
        lcx_id,
        role_id,
        role_name,
        zone_id
    FROM (
        SELECT
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") AS lcx_id,
            e.rolecommon.role_id AS role_id,
            e.rolecommon.role_name AS role_name,
            e.rolecommon.zone_id AS zone_id,

            ROW_NUMBER() OVER (
                PARTITION BY COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id")
                ORDER BY e."#event_time" DESC
            ) AS rn

        FROM ta.v_event_23 e
        INNER JOIN ButterflyLatestSnapshot bo
            ON COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") = bo.lcx_id
        WHERE e."$part_date" >= '2026-06-24'
          AND e.rolecommon.role_name IS NOT NULL
    )
    WHERE rn = 1
),

-------------------------------------------------------
-- 3. 玩家固化标签：注册时间、系统、渠道、国家
-------------------------------------------------------
UserProfile AS (
    SELECT
        "#varchar_id" AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country
    FROM user_result_cluster_23
    WHERE cluster_name IN (
        'fixed_regdate',
        'fixed_os',
        'fixed_affcode',
        'fixed_country'
    )
    GROUP BY 1
),

-------------------------------------------------------
-- 4. 累计充值金额 USD
-------------------------------------------------------
ChargeSum AS (
    SELECT
        COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") AS lcx_id,

        ROUND(
            SUM(
                CAST(e.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0)
            ),
            2
        ) AS revenue_usd

    FROM ta.v_event_23 e
    INNER JOIN ButterflyLatestSnapshot bo
        ON COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") = bo.lcx_id
    LEFT JOIN ta_dim.ta_exchange s5 
        ON e."$part_date" = s5.ex_date 
       AND e.payload.cur = s5.currency
    WHERE e."$part_event" = 'PURCHASE'
      AND e."$part_date" >= '2024-03-27'
      AND (
          e.payload.validationtype IS NULL 
          OR e.payload.validationtype <> 'SANDBOX_RECEIPT'
      )
    GROUP BY 1
),

-------------------------------------------------------
-- 5. 最后登录日期
-------------------------------------------------------
LastLogin AS (
    SELECT
        COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") AS lcx_id,
        MAX(e."$part_date") AS last_login_date
    FROM ta.v_event_23 e
    INNER JOIN ButterflyLatestSnapshot bo
        ON COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") = bo.lcx_id
    WHERE e."$part_event" = 'LOGIN_SUCCESS'
      AND e."$part_date" >= '2026-06-24'
    GROUP BY 1
),

-------------------------------------------------------
-- 6. 最新段位
-------------------------------------------------------
UserLadder AS (
    SELECT 
        lcx_id,
        player_ladder_level
    FROM (
        SELECT 
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") AS lcx_id,
            CAST(e.player_ladder_level AS INTEGER) AS player_ladder_level,

            ROW_NUMBER() OVER (
                PARTITION BY COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id")
                ORDER BY e."#event_time" DESC
            ) AS rn

        FROM ta.v_event_23 e
        INNER JOIN ButterflyLatestSnapshot bo
            ON COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") = bo.lcx_id
        WHERE e."$part_date" >= '2026-06-24'
          AND e.player_ladder_level IS NOT NULL
    )
    WHERE rn = 1
)

-------------------------------------------------------
-- 7. 最终输出
-------------------------------------------------------
SELECT
    bo.lcx_id                                      AS "用户ID_lcx_id",

    COALESCE(lr.role_name, '未知')                  AS "角色名",
    COALESCE(lr.role_id, bo.role_id)                AS "角色ID",
    lr.zone_id                                     AS "区服ID",

    up.fixed_regdate                               AS "注册时间",
    COALESCE(ll.last_login_date, '未知')            AS "最后登陆日期",
    COALESCE(up.fixed_country, '未知')              AS "国家",
    COALESCE(up.fixed_os, '未知')                   AS "系统",
    COALESCE(up.fixed_affcode, '未知')              AS "渠道",

    COALESCE(cs.revenue_usd, 0.0)                  AS "充值金额_USD",
    COALESCE(ul.player_ladder_level, 0)            AS "最新段位",

    CASE 
        WHEN COALESCE(ub.is_internal_user, 0) = 1 THEN '是'
        ELSE '否'
    END                                            AS "是否内部用户",

    CASE 
        WHEN COALESCE(ub.is_water_user, 0) = 1 THEN '是'
        ELSE '否'
    END                                            AS "是否水军用户",

    CASE
        WHEN COALESCE(ub.is_internal_user, 0) = 1 
         AND COALESCE(ub.is_water_user, 0) = 1 THEN '内部用户+水军用户'
        WHEN COALESCE(ub.is_internal_user, 0) = 1 THEN '内部用户'
        WHEN COALESCE(ub.is_water_user, 0) = 1 THEN '水军用户'
        ELSE '正常用户'
    END                                            AS "用户标记",

    bo.card_id                                     AS "卡牌ID",
    bo.card_name                                   AS "卡牌名",

    bo.card_level                                  AS "蝴蝶忍等级",
    bo.awaken_count                                AS "蝴蝶忍觉醒数",
    bo.talent_count                                AS "蝴蝶忍天赋数",

    bo.snap_date                                   AS "卡牌快照日期",
    bo.latest_card_snapshot_time                   AS "最后卡牌快照时间"

FROM ButterflyLatestSnapshot bo
LEFT JOIN LatestRole    lr ON bo.lcx_id = lr.lcx_id
LEFT JOIN UserProfile   up ON bo.lcx_id = up.lcx_id
LEFT JOIN ChargeSum     cs ON bo.lcx_id = cs.lcx_id
LEFT JOIN LastLogin     ll ON bo.lcx_id = ll.lcx_id
LEFT JOIN UserLadder    ul ON bo.lcx_id = ul.lcx_id
LEFT JOIN UserBlacklist ub ON bo.lcx_id = ub.lcx_id

ORDER BY 
    COALESCE(cs.revenue_usd, 0.0) DESC,
    bo.card_level DESC,
    bo.awaken_count DESC,
    bo.talent_count DESC,
    bo.latest_card_snapshot_time DESC;
