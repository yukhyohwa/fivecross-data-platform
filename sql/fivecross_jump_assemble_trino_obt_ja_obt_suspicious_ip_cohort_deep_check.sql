/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : suspicious_ip 分群排查汇总 (首尾登录差>=6h或付费用户卡牌与设备变更数量统计)
Description: 
    针对 user_result_cluster_23 表中 cluster_name = 'suspicious_ip' 分群用户中，
    统计以下核心汇总指标：
    1. 符合条件用户数：首次与末次 LOGIN_SUCCESS 时间差 >= 6 小时，或有充值付费记录的玩家总数。
    2. 登录设备ID变更用户数：在上述用户中，首次与末次登录设备 ID 不一致的人数。
    3. 拥有145卡牌用户数：在上述用户中，拥有 card_id = 145 卡牌的人数。
Environment: Trino (TA)
================================================================================
*/

WITH SuspiciousUsers AS (
    -- 1. 直接获取目标分群的账号列表
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name = 'suspicious_ip'
),

RechargeActivity AS (
    -- 2. 统计这批账号在 6月24-27 期间的累计付费金额
    SELECT 
        s1."#account_id" AS lcx_id,
        SUM(CAST(s1.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0)) AS recharge_usd
    FROM ta.v_event_23 s1
    INNER JOIN SuspiciousUsers su ON s1."#account_id" = su.lcx_id
    LEFT JOIN ta_dim.ta_exchange s5 
        ON s1."$part_date" = s5.ex_date 
        AND s1.payload.cur = s5.currency
    WHERE s1."$part_event" = 'PURCHASE'
      AND COALESCE(s1.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
      AND s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-27'
    GROUP BY 1
),

LoginRanked AS (
    -- 3. 对 6月24-27 期间所有活跃登录记录按时间进行首尾排序
    SELECT 
        s1."#account_id" AS lcx_id,
        s1.deviceid,
        s1."#event_time" AS event_time,
        ROW_NUMBER() OVER(PARTITION BY s1."#account_id" ORDER BY s1."#event_time" ASC) AS rn_first,
        ROW_NUMBER() OVER(PARTITION BY s1."#account_id" ORDER BY s1."#event_time" DESC) AS rn_last
    FROM ta.v_event_23 s1
    INNER JOIN SuspiciousUsers su ON s1."#account_id" = su.lcx_id
    WHERE s1."$part_event" = 'LOGIN_SUCCESS'
      AND s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-27'
),

FirstLogin AS (
    -- 4. 首次登录
    SELECT * FROM LoginRanked WHERE rn_first = 1
),

LastLogin AS (
    -- 5. 末次登录
    SELECT * FROM LoginRanked WHERE rn_last = 1
),

FilteredUsers AS (
    -- 6. 过滤获取：首次和末次 LOGIN_SUCCESS 相差 1.5小时以上，或者有充值记录的用户
    SELECT 
        su.lcx_id,
        COALESCE(ra.recharge_usd, 0.0) AS recharge_usd
    FROM SuspiciousUsers su
    LEFT JOIN FirstLogin fl ON su.lcx_id = fl.lcx_id
    LEFT JOIN LastLogin ll ON su.lcx_id = ll.lcx_id
    LEFT JOIN RechargeActivity ra ON su.lcx_id = ra.lcx_id
    WHERE (
        to_unixtime(parse_datetime(CAST(ll.event_time AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS')) - 
        to_unixtime(parse_datetime(CAST(fl.event_time AS VARCHAR), 'yyyy-MM-dd HH:mm:ss.SSS'))
    ) >= 1.5 * 3600
    OR COALESCE(ra.recharge_usd, 0.0) > 0
),

CardCheck AS (
    -- 7. 判断这批账号是否拥有 card_id = 145 卡牌
    SELECT 
        COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) AS lcx_id,
        MAX(CASE WHEN CAST(s1.card_id AS INTEGER) = 145 THEN 1 ELSE 0 END) AS has_card_145
    FROM ta.v_event_23 s1
    INNER JOIN FilteredUsers fu 
        ON COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) = fu.lcx_id
    WHERE s1."$part_event" = 'daily_role_card_snapshot'
      AND s1."$part_date" BETWEEN '2026-06-24' AND '2026-06-28'
    GROUP BY 1
)

-- 8. 聚合计算各项统计指标
SELECT 
    COUNT(DISTINCT fu.lcx_id) AS "符合排查条件用户数(首尾登录差>=6h或充值)",
    COUNT_IF(fl.deviceid IS NOT NULL AND ll.deviceid IS NOT NULL AND fl.deviceid <> ll.deviceid) AS "登录设备ID变更用户数",
    COUNT_IF(cc.has_card_145 = 1) AS "拥有145卡牌用户数"
FROM FilteredUsers fu
LEFT JOIN CardCheck cc ON fu.lcx_id = cc.lcx_id
LEFT JOIN FirstLogin fl ON fu.lcx_id = fl.lcx_id
LEFT JOIN LastLogin ll ON fu.lcx_id = ll.lcx_id;
