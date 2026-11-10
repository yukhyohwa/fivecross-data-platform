/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : suspicious_ip 分群玩家限时gacha、活跃及最新杯数统计
Description: 直接统计 user_result_cluster_23 表中 cluster_name = 'suspicious_ip' 分群用户的：
             - 限时刊物 (gacha_id = 101) 参与率、人均抽卡次数
             - 平均活跃天数
             - 平均杯数 (season_fight_trophy)
             - 充值付费数据
Environment: Trino (TA)
================================================================================
*/

WITH SuspiciousUsers AS (
    -- 1. 直接获取目标分群的账号列表 (排除黑名单)
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name = 'suspicious_ip'
),

CohortSize AS (
    -- 2. 统计分群总账号数
    SELECT COUNT(DISTINCT lcx_id) AS total_lcx_ids
    FROM SuspiciousUsers
),

GachaActivity AS (
    -- 3. 统计这批账号在 6月24-27 期间参与 "限时刊物" (gacha_id = 101) 的次数
    SELECT 
        COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) AS lcx_id,
        SUM(s1.count) AS draw_count
    FROM ta.v_event_23 s1
    INNER JOIN SuspiciousUsers su ON COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) = su.lcx_id
    WHERE s1."$part_event" = 'active_gacha'
      AND s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-27'
      AND CAST(s1.gacha_id AS INTEGER) = 101
    GROUP BY 1
),

RechargeActivity AS (
    -- 4. 统计这批账号在 6月24-27 期间的累计充值金额
    SELECT 
        s1."#account_id" AS lcx_id,
        ROUND(SUM(CAST(s1.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0)), 2) AS recharge_usd
    FROM ta.v_event_23 s1
    INNER JOIN SuspiciousUsers su ON s1."#account_id" = su.lcx_id
    LEFT JOIN ta_dim.ta_exchange s5 
        ON s1."$part_date" = s5.ex_date 
        AND s1.payload.cur = s5.currency
    WHERE s1."$part_event" = 'PURCHASE'
      AND (s1.payload.validationtype IS NULL OR s1.payload.validationtype <> 'SANDBOX_RECEIPT')
      AND s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-27'
    GROUP BY 1
),

ActiveDays AS (
    -- 5. 统计这批账号在 6月24-27 期间的活跃天数 (以 LOGIN_SUCCESS 为准)
    SELECT 
        s1."#account_id" AS lcx_id,
        COUNT(DISTINCT s1."$part_date") AS active_days
    FROM ta.v_event_23 s1
    INNER JOIN SuspiciousUsers su ON s1."#account_id" = su.lcx_id
    WHERE s1."$part_event" = 'LOGIN_SUCCESS'
      AND s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-27'
    GROUP BY 1
),

UserTrophy AS (
    -- 6. 统计这批账号在 6月24-27 期间在 arena_fight 或 game_fight 中的最新杯数 (season_fight_trophy)
    SELECT 
        lcx_id,
        trophy
    FROM (
        SELECT 
            COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) AS lcx_id,
            CAST(s1.season_fight_trophy AS DOUBLE) AS trophy,
            ROW_NUMBER() OVER(PARTITION BY COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) ORDER BY s1."#event_time" DESC) AS rn
        FROM ta.v_event_23 s1
        INNER JOIN SuspiciousUsers su ON COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) = su.lcx_id
        WHERE  s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-27'
          AND s1.season_fight_trophy IS NOT NULL
    )
    WHERE rn = 1
)

-- 7. 整体统计输出 (分群整体均数统计)
SELECT 
    (SELECT total_lcx_ids FROM CohortSize) AS "分群账号总数",
    
    -- 限时刊物抽卡情况
    COUNT(DISTINCT ga.lcx_id) AS "参与抽卡账号数",
    ROUND(COUNT(DISTINCT ga.lcx_id) * 100.0 / NULLIF((SELECT total_lcx_ids FROM CohortSize), 0), 2) AS "抽卡参与率(%)",
    COALESCE(SUM(ga.draw_count), 0) AS "总抽卡次数",
    ROUND(COALESCE(SUM(ga.draw_count), 0) * 1.0 / NULLIF(COUNT(DISTINCT ga.lcx_id), 0), 2) AS "人均抽卡次数",
    
    -- 付费情况
    COUNT(DISTINCT ra.lcx_id) AS "付费账号数",
    ROUND(COUNT(DISTINCT ra.lcx_id) * 100.0 / NULLIF((SELECT total_lcx_ids FROM CohortSize), 0), 2) AS "付费率(%)",
    ROUND(COALESCE(SUM(ra.recharge_usd), 0.0), 2) AS "总充值金额(USD)",
    
    -- 活跃天数
    ROUND(CAST(SUM(COALESCE(ad.active_days, 0)) AS DOUBLE) / NULLIF((SELECT total_lcx_ids FROM CohortSize), 0), 4) AS "平均活跃天数",
    
    -- 平均杯数
    ROUND(AVG(ut.trophy), 4) AS "平均杯数"
FROM SuspiciousUsers su
LEFT JOIN GachaActivity ga ON su.lcx_id = ga.lcx_id
LEFT JOIN RechargeActivity ra ON su.lcx_id = ra.lcx_id
LEFT JOIN ActiveDays ad ON su.lcx_id = ad.lcx_id
LEFT JOIN UserTrophy ut ON su.lcx_id = ut.lcx_id;
