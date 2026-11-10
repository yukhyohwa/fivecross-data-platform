/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 跃之星或免费跃之星为负数的用户异常名单与画像分析
Description : 
    查询近期在角色快照或资源日志中，出现【跃之星(付费) < 0】或【免费跃之星 < 0】
    的异常玩家名单（例如受到 GM 扣减、退款扣款或漏洞引发的负债账单），
    并同步整合输出其完整用户画像信息：
    包含：当前负数存款额度、注册时间、最后登陆时间、国家、系统、区服、累计充值金额 (USD)、段位等。
Environment : Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    -- 排除或标记测试与水军黑名单
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

-- 1. 扫描获取所有角色的最新存量状态（从每日快照与资源变动中定位跃之星余额）
LatestStarBalance AS (
    SELECT
        role_id,
        lcx_id,
        role_name,
        zone_id,
        stat_date,
        total_amount,
        total_free_amount
    FROM (
        SELECT
            -- 【防科学计数法处理】DOUBLE/FLOAT类型的数字转换为 BIGINT 整数后再转 VARCHAR
            COALESCE(CAST(TRY_CAST(TRY_CAST(e.rolecommon.role_id AS DOUBLE) AS BIGINT) AS VARCHAR), CAST(TRY_CAST(TRY_CAST(e."#account_id" AS DOUBLE) AS BIGINT) AS VARCHAR), CAST(e.rolecommon.role_id AS VARCHAR), CAST(e."#account_id" AS VARCHAR)) AS role_id,
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) AS lcx_id,
            e.rolecommon.role_name AS role_name,
            e.rolecommon.zone_id AS zone_id,
            e."$part_date" AS stat_date,
            COALESCE(e.total_amount, 0) AS total_amount,           -- 跃之星(免费/付费 埋点定义)
            COALESCE(e.total_free_amount, 0) AS total_free_amount, -- 跃之星(付费/免费 埋点定义)
            ROW_NUMBER() OVER (
                PARTITION BY COALESCE(CAST(TRY_CAST(TRY_CAST(e.rolecommon.role_id AS DOUBLE) AS BIGINT) AS VARCHAR), CAST(TRY_CAST(TRY_CAST(e."#account_id" AS DOUBLE) AS BIGINT) AS VARCHAR), CAST(e.rolecommon.role_id AS VARCHAR), CAST(e."#account_id" AS VARCHAR)) 
                ORDER BY e."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 e
        WHERE e."$part_date" >= '2026-06-24'
          AND e."$part_event" IN ('daily_role_snapshot', 'resource_change')
          AND (e.total_amount IS NOT NULL OR e.total_free_amount IS NOT NULL)
    )
    WHERE rn = 1
      -- 核心判定条件：跃之星或免费跃之星任一为负数 (< 0)
      AND (total_amount < 0 OR total_free_amount < 0)
),

-- 2. 针对负数异常玩家，关联最新的完备基础身份（防止后台被动快照日志中角色昵称或UUID缺失）
MatchedAccounts AS (
    SELECT 
        b.role_id,
        COALESCE(b.lcx_id, i.lcx_id) AS lcx_id,
        COALESCE(b.role_name, i.role_name, '未知') AS role_name,
        COALESCE(b.zone_id, i.zone_id, '未知') AS zone_id,
        b.stat_date,
        b.total_amount,
        b.total_free_amount
    FROM LatestStarBalance b
    LEFT JOIN (
        SELECT role_id, lcx_id, role_name, zone_id
        FROM (
            SELECT 
                COALESCE(CAST(TRY_CAST(TRY_CAST(e.rolecommon.role_id AS DOUBLE) AS BIGINT) AS VARCHAR), CAST(e.rolecommon.role_id AS VARCHAR)) AS role_id,
                COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) AS lcx_id,
                e.rolecommon.role_name AS role_name,
                e.rolecommon.zone_id AS zone_id,
                ROW_NUMBER() OVER (
                    PARTITION BY COALESCE(CAST(TRY_CAST(TRY_CAST(e.rolecommon.role_id AS DOUBLE) AS BIGINT) AS VARCHAR), CAST(e.rolecommon.role_id AS VARCHAR)) 
                    ORDER BY e."#event_time" DESC
                ) AS rn
            FROM ta.v_event_23 e
            WHERE e."$part_date" >= '2026-06-24'
              AND e."$part_event" IN ('resource_change', 'hero_choose', 'LOGIN_SUCCESS', 'active_shop', 'item_exchange')
              AND e.rolecommon.role_name IS NOT NULL AND e.rolecommon.role_name <> ''
        )
        WHERE rn = 1
    ) i ON b.role_id = i.role_id
),

-- 3. 玩家固化标签：国家、系统、渠道及注册日期 (源自 user_result_cluster_23)
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

-- 4. 累计充值汇总 (排除 Sandbox 充值)
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

-- 5. 最后登录活跃日期
LastLogin AS (
    SELECT
        "#account_id" AS lcx_id,
        MAX(e."$part_date") AS last_login_date
    FROM ta.v_event_23 e
    WHERE e."$part_event" = 'LOGIN_SUCCESS'
      AND e."$part_date" >= '2026-06-24'
    GROUP BY 1
),

-- 6. 获取最新段位级别 (player_ladder_level)
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
        WHERE e."$part_date" >= '2026-06-24'
          AND e.player_ladder_level IS NOT NULL
    )
    WHERE rn = 1
)

-- 7. 关联整合并输出负数名单与其完备画像
SELECT
    ma.lcx_id                                    AS "用户ID (lcx_id)",
    ma.role_name                                 AS "角色名",
    COALESCE(CAST(TRY_CAST(TRY_CAST(ma.role_id AS DOUBLE) AS BIGINT) AS VARCHAR), ma.role_id, '未知') AS "角色ID",
    ma.zone_id                                   AS "区服ID",
    ma.stat_date                                 AS "数据状态日期",
    ma.total_amount                              AS "跃之星(免费)存量", -- 注：保留原始字段定义（与充值互换）
    ma.total_free_amount                         AS "跃之星(付费)存量", -- 注：保留原始字段定义（与充值互换）
    up.fixed_regdate                             AS "注册时间",
    COALESCE(ll.last_login_date, '未知')          AS "最后登陆日期",
    COALESCE(up.fixed_country, '未知')           AS "国家",
    COALESCE(up.fixed_os, '未知')                AS "系统",
    COALESCE(up.fixed_affcode, '未知')           AS "渠道",
    COALESCE(cs.revenue_usd, 0.0)                AS "充值金额_USD",
    COALESCE(ul.player_ladder_level, 0)          AS "最新段位",
    CASE WHEN ub.lcx_id IS NOT NULL THEN '内部或水军号' ELSE '普通玩家' END AS "备注"
FROM MatchedAccounts ma
LEFT JOIN UserBlacklist  ub ON ma.lcx_id = ub.lcx_id
LEFT JOIN UserProfile    up ON ma.lcx_id = up.lcx_id
LEFT JOIN ChargeSum      cs ON ma.lcx_id = cs.lcx_id
LEFT JOIN LastLogin      ll ON ma.lcx_id = ll.lcx_id
LEFT JOIN UserLadder     ul ON ma.lcx_id = ul.lcx_id
-- WHERE ub.lcx_id IS NULL -- 若希望在报表中排除测试及水军黑名单，可取消此处注释
-- 排序说明：按负数负款严重程度升序(最惨烈的负债放最顶上)，其次按充值总额从高到低排序
ORDER BY LEAST(ma.total_amount, ma.total_free_amount) ASC, "充值金额_USD" DESC;
