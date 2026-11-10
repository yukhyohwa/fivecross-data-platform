/*
================================================================================
Game        : Jump Assemble (众星之聚) - OBT Region
Report      : 主播购买明细统计 (包含购买者画像信息：角色ID、昵称、国家、系统)
Description : 统计主播充值明细，包含原币种与 USD 换算，并关联购买玩家的画像信息。
Environment : Trino (TA)
================================================================================
*/

WITH UsersInfo AS (
    -- 1. 获取每个用户最新的角色信息 (角色ID、角色名/昵称)
    SELECT lcx_id, role_id, role_name
    FROM (
        SELECT 
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") AS lcx_id,
            e.rolecommon.role_id AS role_id,
            e.rolecommon.role_name AS role_name,
            ROW_NUMBER() OVER(PARTITION BY COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id, e."#account_id") ORDER BY e."#event_time" DESC) AS rn
        FROM ta.v_event_23 e
        WHERE e."$part_date" >= '2026-06-24'
          AND e."$part_event" IN ('NUU','PURCHASE','LOGIN_SUCCESS','hero_choose','resource_change')
          AND e.rolecommon.role_name IS NOT NULL AND e.rolecommon.role_name <> ''
    )
    WHERE rn = 1
),

UserProfile AS (
    -- 2. 获取玩家固化标签：国家、系统 (源自 user_result_cluster_23)
    SELECT
        "#varchar_id" AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_os', 'fixed_country')
    GROUP BY 1
)

SELECT 
    s1.streamer_code AS "主播代码",
    s1."$part_date" AS "日期",
    s1."#event_time" AS "时间",
    s1."#account_id" AS "账号ID (lcx_id)",
    COALESCE(CAST(CAST(u.role_id AS BIGINT) AS VARCHAR), '未知') AS "角色ID",
    COALESCE(u.role_name, '未知') AS "角色名 (昵称)",
    COALESCE(p.fixed_country, '未知') AS "国家",
    COALESCE(p.fixed_os, '未知') AS "系统",
    s1.order_id AS "订单号",
    s1.wallet_bundle_id AS "商品ID",
    ROUND(CAST(s1.original_amount AS DOUBLE) / COALESCE(s2.exchange, 1.0), 2) AS "充值金额 (USD)"
FROM ta.v_event_23 s1
LEFT JOIN ta_dim.ta_exchange s2 
    ON s1."$part_date" = s2.ex_date 
    AND s1.currency_code = s2.currency
LEFT JOIN UsersInfo u ON s1."#account_id" = u.lcx_id
LEFT JOIN UserProfile p ON s1."#account_id" = p.lcx_id
WHERE ${PartDate:date1} 
  AND s1."$part_event" = 'streamer_purchase'
ORDER BY 2 DESC, 3 DESC;
