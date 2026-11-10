/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 每日周活跃用户 (WAU) 道具货币人均存量统计
Description : 
    统计公测 OBT 期间，每日对应近一周活跃用户 (WAU，前6天至今有过登录/注册活动) 
    在角色快照中的人均货币与道具存量（已通过 DISTINCT 排除 GM 及黑名单干扰）：
    1. 意志结晶人均量 (total_diamond)
    2. 纪念币人均量 (total_gold)
    3. 跃之星(免费/付费)人均量 (total_amount / total_free_amount，保留埋点定义互换)
    技术细节：1. 负数保底归零：针对被退款或扣罚致负数账单的货币存量统一计为 0，防范其向下拖拉全盘人均线。
             2. 活跃窗口准确筛选：通过中间映射打通角色 ID (role_id) 与平台账号 ID (lcx_id)，
                仅纳入真实周活跃口径的玩家快照进行均值计算，避免历史流失大盘分母拉扯。
Environment : Trino (TA)
================================================================================
*/

WITH 
-- 1. 临时黑名单 (从 v_event_23 过滤 GM 资源调整等干扰账号)
RoleBlacklist AS (
    SELECT DISTINCT "#account_id" AS role_id
    FROM ta.v_event_23
    WHERE "$part_event" = 'resource_change'
      AND "$part_date" >= '2026-06-24' 
      AND gu_type = 1 
      AND id IN (3, 8)
      AND reason = 'GM'
),

-- 2. 获取公测以来的活跃玩家流水 (登录/注册中 #account_id 即为平台 UUID lcx_id)
UserActivity AS (
    SELECT DISTINCT
        "$part_date" AS act_date,
        "#account_id" AS lcx_id
    FROM ta.v_event_23
    WHERE "$part_date" >= '2026-06-24'
      AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
      AND "#account_id" IS NOT NULL
),

-- 3. 建立【角色ID (role_id) <=> 账号ID (lcx_id)】的映射表
-- 在 OBT 环境仅对齐有效的主题字段：sdkcommon 和 fc_sdk_common
RoleLcxMapping AS (
    SELECT role_id, lcx_id
    FROM (
        SELECT 
            CAST(e.rolecommon.role_id AS VARCHAR) AS role_id,
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) AS lcx_id,
            ROW_NUMBER() OVER (
                PARTITION BY CAST(e.rolecommon.role_id AS VARCHAR) 
                ORDER BY e."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 e
        WHERE e."$part_date" >= '2026-06-24'
          AND e."$part_event" IN ('resource_change', 'hero_choose', 'daily_role_snapshot', 'active_shop', 'item_exchange')
          AND e.rolecommon.role_id IS NOT NULL
          AND COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) IS NOT NULL
    )
    WHERE rn = 1
),

-- 4. 每日角色快照 (排除黑名单的同时，按 role_id 给每一行快照对齐合规的平台 UUID)
DailySnapshot AS (
    SELECT
        s1."$part_date" AS stat_date,
        s1."#user_id" AS user_id,
        CAST(s1."#account_id" AS VARCHAR) AS role_id, -- daily_role_snapshot 中的 #account_id 代表 role_id
        -- 优先读快照事件自持的 lcx_id，为空时调用中间桥梁表的映射
        COALESCE(s1.sdkcommon.lcx_id, s1.fc_sdk_common.lcx_id, m.lcx_id) AS lcx_id,
        -- 【负值算0规则】资产遭遇扣减至负数时归为0计，避免侵食打低真实均温
        CASE WHEN COALESCE(s1.currency_info.total_gold, 0) < 0 THEN 0 ELSE COALESCE(s1.currency_info.total_gold, 0) END AS total_gold,               -- 纪念币
        CASE WHEN COALESCE(s1.currency_info.total_diamond, 0) < 0 THEN 0 ELSE COALESCE(s1.currency_info.total_diamond, 0) END AS total_diamond,         -- 意志结晶
        CASE WHEN COALESCE(s1.currency_info.total_gacha_money, 0) < 0 THEN 0 ELSE COALESCE(s1.currency_info.total_gacha_money, 0) END AS total_gacha_money, -- 普通阅览券
        CASE WHEN COALESCE(s1.total_amount, 0) < 0 THEN 0 ELSE COALESCE(s1.total_amount, 0) END AS total_amount,                                     -- 跃之星(免费) *保留埋点互换
        CASE WHEN COALESCE(s1.total_free_amount, 0) < 0 THEN 0 ELSE COALESCE(s1.total_free_amount, 0) END AS total_free_amount,                           -- 跃之星(付费)
        ROW_NUMBER() OVER (
            PARTITION BY s1."$part_date", s1."#user_id" 
            ORDER BY s1."#event_time" DESC
        ) AS rn
    FROM ta.v_event_23 s1
    -- 依据角色 ID 左向关联补充平台官方 UUID
    LEFT JOIN RoleLcxMapping m ON CAST(s1."#account_id" AS VARCHAR) = m.role_id
    WHERE s1.${PartDate:date1}
      AND s1."$part_event" = 'daily_role_snapshot'
      AND s1.total_fight_trophy ${Number:number1}
      AND s1.season_fight_ranked ${Number:number2}
      -- 安全过黑名单校验
      AND s1."#account_id" NOT IN (SELECT role_id FROM RoleBlacklist WHERE role_id IS NOT NULL)
),

-- 5. 通过双边完全统一的 UUID【lcx_id = lcx_id】顺畅匹配滑动周活跃窗口！
WAUSnapshot AS (
    SELECT DISTINCT
        s.stat_date,
        s.user_id,
        s.total_diamond,
        s.total_gold,
        s.total_gacha_money,
        s.total_amount,
        s.total_free_amount
    FROM DailySnapshot s
    INNER JOIN UserActivity a 
        ON s.lcx_id = a.lcx_id 
        -- 校验在往前推6天至今天内 [stat_date-6, stat_date] 共7日的活跃迹象
        AND DATE_DIFF('day', CAST(a.act_date AS DATE), CAST(s.stat_date AS DATE)) BETWEEN 0 AND 6
    WHERE s.rn = 1
      AND s.lcx_id IS NOT NULL
)

-- 6. 聚合得出每天真实周活跃玩家的道具与货币均量
SELECT 
    stat_date AS "$part_date",
    COUNT(DISTINCT user_id) AS "周活跃快照人数(WAU)", 
    AVG(total_diamond) AS "意志结晶人均量",
    AVG(total_gold) AS "纪念币人均量",
    -- AVG(total_gacha_money) AS "阅览券人均量",
    -- 埋点的搞错了 
    AVG(total_amount) AS "跃之星(免费)人均量",                               
    AVG(total_free_amount) AS "跃之星(付费)人均量"
FROM WAUSnapshot
GROUP BY 1
ORDER BY 1 DESC;
