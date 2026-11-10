/*
================================================================================
Game    : Jump Assemble (众星之聚)
Description: 6/24 OBT新用户角色养成汇总 (集成黑名单与充值档位)
             - 目标用户：2026-06-24 及以后注册，排除内部与灌水号
             - 维度：累计充值档位 (recharge_tier)
             - 指标：全量/A类/S类 角色获取、觉醒、天赋等养成均值
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. 黑名单用户 (集成内部号与灌水号)
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users','is_water')
),

-- 2. 定义 6月24日开始测试的新用户底层名单 (应用黑名单排除)
NewUsers AS (
    SELECT 
        t1."#varchar_id" AS lcx_id,
        MAX(CASE WHEN t1.cluster_name = 'fixed_regdate' THEN t1.tag_value END) AS fixed_regdate 
    FROM user_result_cluster_23 t1
    LEFT JOIN UserBlacklist ub ON t1."#varchar_id" = ub.lcx_id
    WHERE t1.cluster_name = 'fixed_regdate'
      AND ub.lcx_id IS NULL  -- 排除黑名单
    GROUP BY 1
    HAVING MAX(CASE WHEN t1.cluster_name = 'fixed_regdate' THEN t1.tag_value END) >= '2026-06-24'
),

-- 3. 计算用户累计充值总额 (USD)
UserCumulativeRevenue AS (
    SELECT 
        nu.lcx_id,
        COALESCE(SUM(CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(s5.exchange, 1)), 0) AS total_revenue_usd
    FROM NewUsers nu
    LEFT JOIN ta.v_event_23 v ON nu.lcx_id = v."#account_id" 
        AND v."$part_event" = 'PURCHASE' 
        AND COALESCE(v.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
    LEFT JOIN ta_dim.ta_exchange s5 ON v."$part_date" = s5.ex_date 
        AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = s5.currency
    GROUP BY 1
),

-- 4. 根据累计充值金额划分档位
UserTierAssignment AS (
    SELECT 
        lcx_id,
        total_revenue_usd,
        CASE 
            WHEN total_revenue_usd = 0 THEN '0.免费用户'
            WHEN total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM UserCumulativeRevenue
),

-- 5. 提取角色最新快照 (OBT23 使用 COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id) 映射 lcx_id)
CharacterLatest AS (
    SELECT *
    FROM (
        SELECT 
            COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id) AS lcx_id,
            card_id,
            card_name,
            CASE 
                WHEN card_id IN (126,145) THEN 'S' -- OBT 引入 145 作为 S 级角色
                WHEN card_id IN (135,125,158,122,110,134,113,127,157,159,132) THEN 'A'
                ELSE 'R' 
            END card_quality,
            card_level,
            cardinality(card_awake) AS awaken_count,
            cardinality(filter(card_talent_slot, x -> x <> '0' AND x <> '')) AS talent_count,
            ROW_NUMBER() OVER(
                PARTITION BY COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id), card_id 
                ORDER BY "$part_date" DESC, "#event_time" DESC
            ) as rn
        FROM ta.v_event_23 
        WHERE "$part_event" = 'daily_role_card_snapshot'
          AND COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id) IN (SELECT lcx_id FROM NewUsers)
    )
    WHERE rn = 1
),

-- 6. 按用户汇总角色特征
UserCharacterStats AS (
    SELECT 
        nu.lcx_id,
        -- 全量统计
        COUNT(cl.card_id) AS total_cards,
        COUNT(IF(cl.card_level = 10, 1)) AS cards_lvl10,
        COUNT(IF(cl.awaken_count >= 1, 1)) AS cards_awk1,
        COUNT(IF(cl.awaken_count >= 2, 1)) AS cards_awk2,
        COUNT(IF(cl.awaken_count >= 3, 1)) AS cards_awk3,
        COUNT(IF(cl.talent_count >= 2, 1)) AS cards_tal2,
        COUNT(IF(cl.talent_count >= 4, 1)) AS cards_tal4,
        COUNT(IF(cl.talent_count >= 6, 1)) AS cards_tal6,
        
        -- A类统计
        COUNT(IF(cl.card_quality = 'A', 1)) AS a_total_cards,
        COUNT(IF(cl.card_quality = 'A' AND cl.card_level = 10, 1)) AS a_cards_lvl10,
        COUNT(IF(cl.card_quality = 'A' AND cl.awaken_count >= 1, 1)) AS a_cards_awk1,
        COUNT(IF(cl.card_quality = 'A' AND cl.awaken_count >= 2, 1)) AS a_cards_awk2,
        COUNT(IF(cl.card_quality = 'A' AND cl.awaken_count >= 3, 1)) AS a_cards_awk3,
        COUNT(IF(cl.card_quality = 'A' AND cl.talent_count >= 2, 1)) AS a_cards_tal2,
        COUNT(IF(cl.card_quality = 'A' AND cl.talent_count >= 4, 1)) AS a_cards_tal4,
        COUNT(IF(cl.card_quality = 'A' AND cl.talent_count >= 6, 1)) AS a_cards_tal6,
        
        -- S类统计
        COUNT(IF(cl.card_quality = 'S', 1)) AS s_total_cards,
        COUNT(IF(cl.card_quality = 'S' AND cl.card_level = 10, 1)) AS s_cards_lvl10,
        COUNT(IF(cl.card_quality = 'S' AND cl.awaken_count >= 1, 1)) AS s_cards_awk1,
        COUNT(IF(cl.card_quality = 'S' AND cl.awaken_count >= 2, 1)) AS s_cards_awk2,
        COUNT(IF(cl.card_quality = 'S' AND cl.awaken_count >= 3, 1)) AS s_cards_awk3,
        COUNT(IF(cl.card_quality = 'S' AND cl.talent_count >= 2, 1)) AS s_cards_tal2,
        COUNT(IF(cl.card_quality = 'S' AND cl.talent_count >= 4, 1)) AS s_cards_tal4,
        COUNT(IF(cl.card_quality = 'S' AND cl.talent_count >= 6, 1)) AS s_cards_tal6,
        
        -- R类统计
        COUNT(IF(cl.card_quality = 'R', 1)) AS r_total_cards,
        COUNT(IF(cl.card_quality = 'R' AND cl.card_level = 10, 1)) AS r_cards_lvl10,
        COUNT(IF(cl.card_quality = 'R' AND cl.awaken_count >= 1, 1)) AS r_cards_awk1,
        COUNT(IF(cl.card_quality = 'R' AND cl.awaken_count >= 2, 1)) AS r_cards_awk2,
        COUNT(IF(cl.card_quality = 'R' AND cl.awaken_count >= 3, 1)) AS r_cards_awk3,
        COUNT(IF(cl.card_quality = 'R' AND cl.talent_count >= 2, 1)) AS r_cards_tal2,
        COUNT(IF(cl.card_quality = 'R' AND cl.talent_count >= 4, 1)) AS r_cards_tal4,
        COUNT(IF(cl.card_quality = 'R' AND cl.talent_count >= 6, 1)) AS r_cards_tal6
        
    FROM NewUsers nu
    LEFT JOIN CharacterLatest cl ON nu.lcx_id = cl.lcx_id
    GROUP BY 1
)

-- 7. 最终聚合输出 (按充值档位分组)
SELECT
    uta.recharge_tier AS "充值档位",
    COUNT(DISTINCT nu.lcx_id) AS "新用户规模",
    ROUND(SUM(uta.total_revenue_usd), 2) AS "累计充值(USD)",
    
    ----------------------------------------------------------------------
    -- 各维度养成均值
    ----------------------------------------------------------------------
    ROUND(AVG(CAST(ucs.total_cards AS DOUBLE)), 2) AS "平均持有角色数",
    ROUND(AVG(CAST(ucs.cards_lvl10 AS DOUBLE)), 2) AS "平均持有满级(10级)角色数",
    ROUND(AVG(CAST(ucs.cards_awk1 AS DOUBLE)), 2) AS "平均持有1觉+角色数",
    ROUND(AVG(CAST(ucs.cards_awk2 AS DOUBLE)), 2) AS "平均持有2觉+角色数",
    ROUND(AVG(CAST(ucs.cards_awk3 AS DOUBLE)), 2) AS "平均持有3觉+角色数",
    ROUND(AVG(CAST(ucs.cards_tal2 AS DOUBLE)), 2) AS "平均持有天赋2+角色数",
    ROUND(AVG(CAST(ucs.cards_tal4 AS DOUBLE)), 2) AS "平均持有天赋4+角色数",
    ROUND(AVG(CAST(ucs.cards_tal6 AS DOUBLE)), 2) AS "平均持有天赋6+角色数",
 
    
    ROUND(AVG(CAST(ucs.a_total_cards AS DOUBLE)), 2) AS "平均A类持有角色数",
    ROUND(AVG(CAST(ucs.a_cards_lvl10 AS DOUBLE)), 2) AS "平均A类持有满级(10级)角色数",
    ROUND(AVG(CAST(ucs.a_cards_awk1 AS DOUBLE)), 2) AS "平均A类持有1觉+角色数",
    ROUND(AVG(CAST(ucs.a_cards_awk2 AS DOUBLE)), 2) AS "平均A类持有2觉+角色数",
    ROUND(AVG(CAST(ucs.a_cards_awk3 AS DOUBLE)), 2) AS "平均A类持有3觉+角色数",
    ROUND(AVG(CAST(ucs.a_cards_tal2 AS DOUBLE)), 2) AS "平均A类持有天赋2+角色数",
    ROUND(AVG(CAST(ucs.a_cards_tal4 AS DOUBLE)), 2) AS "平均A类持有天赋4+角色数",
    ROUND(AVG(CAST(ucs.a_cards_tal6 AS DOUBLE)), 2) AS "平均A类持有天赋6+角色数",
    
    ROUND(AVG(CAST(ucs.s_total_cards AS DOUBLE)), 2) AS "平均S类持有角色数",
    ROUND(AVG(CAST(ucs.s_cards_lvl10 AS DOUBLE)), 2) AS "平均S类持有满级(10级)角色数",
    ROUND(AVG(CAST(ucs.s_cards_awk1 AS DOUBLE)), 2) AS "平均S类持有1觉+角色数",
    ROUND(AVG(CAST(ucs.s_cards_awk2 AS DOUBLE)), 2) AS "平均S类持有2觉+角色数",
    ROUND(AVG(CAST(ucs.s_cards_awk3 AS DOUBLE)), 2) AS "平均S类持有3觉+角色数",
    ROUND(AVG(CAST(ucs.s_cards_tal2 AS DOUBLE)), 2) AS "平均S类持有天赋2+角色数",
    ROUND(AVG(CAST(ucs.s_cards_tal4 AS DOUBLE)), 2) AS "平均S类持有天赋4+角色数",
    ROUND(AVG(CAST(ucs.s_cards_tal6 AS DOUBLE)), 2) AS "平均S类持有天赋6+角色数",

    ROUND(AVG(CAST(ucs.r_total_cards AS DOUBLE)), 2) AS "平均R类持有角色数",
    ROUND(AVG(CAST(ucs.r_cards_lvl10 AS DOUBLE)), 2) AS "平均R类持有满级(10级)角色数",
    ROUND(AVG(CAST(ucs.r_cards_awk1 AS DOUBLE)), 2) AS "平均R类持有1觉+角色数",
    ROUND(AVG(CAST(ucs.r_cards_awk2 AS DOUBLE)), 2) AS "平均R类持有2觉+角色数",
    ROUND(AVG(CAST(ucs.r_cards_awk3 AS DOUBLE)), 2) AS "平均R类持有3觉+角色数",
    ROUND(AVG(CAST(ucs.r_cards_tal2 AS DOUBLE)), 2) AS "平均R类持有天赋2+角色数",
    ROUND(AVG(CAST(ucs.r_cards_tal4 AS DOUBLE)), 2) AS "平均R类持有天赋4+角色数",
    ROUND(AVG(CAST(ucs.r_cards_tal6 AS DOUBLE)), 2) AS "平均R类持有天赋6+角色数"
FROM NewUsers nu
LEFT JOIN UserTierAssignment uta ON nu.lcx_id = uta.lcx_id
LEFT JOIN UserCharacterStats ucs ON nu.lcx_id = ucs.lcx_id
GROUP BY 1
ORDER BY 1 ASC;
