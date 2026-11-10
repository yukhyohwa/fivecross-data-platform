/*
================================================================================
项目：蜡笔小新 - 玩家晶钻(10206)产出与消耗明细日志
功能：输入账号/昵称等信息，查看特定玩家的晶钻变动日志（包含购买了什么）
时间：自适应 ${PartDate:date1}
输入：${roleinfo} → 昵称/账号ID/UUID/distinct_id等模糊搜索
================================================================================
*/

WITH 
-- 1. 根据输入模糊搜索玩家，找到对应的 user_id 和 account_id (参考画像查询)
RoleSearch AS (
    SELECT
        "#account_id" AS account_id,
        "#user_id" AS user_id,
        role_name,
        ROW_NUMBER() OVER (PARTITION BY "#account_id" ORDER BY "#event_time" DESC) AS rn
    FROM ta.v_event_18
    WHERE (
        role_name LIKE '%${roleinfo}%' 
        OR "#account_id" LIKE '%${roleinfo}%' 
        OR TRY(json_extract_scalar(fcsdk_info, '$.uuid')) LIKE '%${roleinfo}%' 
        OR "#distinct_id" LIKE '%${roleinfo}%'
    )
    AND role_name IS NOT NULL
    AND "$part_date" >= '2024-01-01' -- 提高搜索性能
    AND "$part_event" <> 'card_battlepower'
),

MatchedAccounts AS (
    SELECT account_id, user_id, role_name
    FROM RoleSearch
    WHERE rn = 1
),

-- 2. 提取商城购买记录，用于获取购买的具体道具名称
ShopBuyRecords AS (
    SELECT 
        v."#account_id" AS account_id,
        cast(to_unixtime(cast(v."#event_time" AS timestamp(3))) AS bigint) AS event_time_sec,
        COALESCE(dp."product_id@product_name_tc", ARRAY_JOIN(TRANSFORM(v.a_rst, x -> CAST(x.name AS VARCHAR)), '+')) AS product_name,
        CAST(v.shop_item[1].shop_id AS VARCHAR) AS shop_id,
        CASE 
             WHEN v.shop_item[1].shop_id > 10000 THEN '晶钻商城' 
             ELSE '红钻商城' 
        END AS shop_type
    FROM ta.v_event_18 v
    JOIN MatchedAccounts ma ON v."#account_id" = ma.account_id
    LEFT JOIN ta_dim.dim_13_0_20639 dp ON CAST(v.shop_item[1].shop_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER)
    WHERE v."$part_event" = 'shop_buy'
      AND v.${PartDate:date1}
),

-- 3. 提取该玩家的晶钻 (10206) 变动日志
GemLog AS (
    SELECT 
        v."#event_time" AS event_time,
        v."#account_id" AS account_id,
        ma.role_name,
        CAST(t.diff AS BIGINT) AS amount,
        CAST(t.before AS BIGINT) AS amount_before,
        CAST(t.after AS BIGINT) AS amount_after,
        CASE 
            WHEN CAST(t.before AS BIGINT) > CAST(t.after AS BIGINT) THEN '消耗' 
            ELSE '产出' 
        END AS change_type,
        cast(to_unixtime(cast(v."#event_time" AS timestamp(3))) AS bigint) AS event_time_sec
    FROM ta.v_event_18 v
    JOIN MatchedAccounts ma ON v."#account_id" = ma.account_id
    CROSS JOIN UNNEST(v.a_rst) AS t
    WHERE v.${PartDate:date1} 
      AND v."$part_event" = 'item_change'
      AND CAST(t.id AS BIGINT) = 10206
)

-- 4. 关联输出最终结果
SELECT 
    gl.event_time AS "变动时间",
    gl.account_id AS "账号ID",
    gl.role_name AS "角色昵称",
    gl.change_type AS "类型(消耗/产出)",
    gl.amount AS "变动数量",
    gl.amount_before AS "变动前",
    gl.amount_after AS "变动后",
    COALESCE(sb.product_name, '其他途径') AS "变动原因(购买内容)",
    COALESCE(sb.shop_id, '') AS "详情标识(ShopID等)",
    COALESCE(sb.shop_type, '') AS "商城类型"
FROM GemLog gl
LEFT JOIN ShopBuyRecords sb 
    ON gl.account_id = sb.account_id 
    AND gl.event_time_sec = sb.event_time_sec
ORDER BY gl.event_time DESC;
