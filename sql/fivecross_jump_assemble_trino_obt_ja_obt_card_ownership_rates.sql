/*
================================================================================
Game    : Jump Assemble (众星之聚) - OBT Region
Report  : OBT 角色卡牌持有率统计
Description: 
    根据指定的快照日期 ${PartDate:date1}，统计大盘活跃用户的每张角色卡牌持有玩家数及持有率。
    S级卡牌：126, 145
    A级卡牌：135,125,158,122,110,134,113,127,157,159,132
    R级卡牌：其它
Environment: Trino (TA)
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users','is_water')
),

card_owners AS (
    -- 计算每张卡牌的持有玩家数
    SELECT 
        card_id,
        card_name,
        COUNT(DISTINCT COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id)) AS owner_count
    FROM ta.v_event_23 s1
    LEFT JOIN UserBlacklist ub ON COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) = ub.lcx_id
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'daily_role_card_snapshot'
      AND ub.lcx_id IS NULL
    GROUP BY 
        card_id,
        card_name
), 
total_users AS (
    -- 计算大盘（快照日）的总活跃玩家数
    SELECT 
        COUNT(DISTINCT COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id)) AS total_user_count
    FROM ta.v_event_23 s1
    LEFT JOIN UserBlacklist ub ON COALESCE(s1.fc_sdk_common.lcx_id, s1.sdkcommon.lcx_id) = ub.lcx_id
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'daily_role_card_snapshot'
      AND ub.lcx_id IS NULL
)
SELECT 
    c.card_id,
    CASE 
        WHEN c.card_id IN (126,145) THEN 'S'
        WHEN c.card_id IN (135,125,158,122,110,134,113,127,157,159,132) THEN 'A'
        ELSE 'R' 
    END card_quality,
    c.card_name,
    c.owner_count AS "持有玩家数",
    t.total_user_count AS "大盘活跃玩家数",
    (c.owner_count * 1.0000 / t.total_user_count) AS "持有率"
FROM card_owners c
CROSS JOIN total_users t
ORDER BY 
    "持有率" DESC;
