-- ***************************************************************
-- 目的: 查询灌篮高手多版本(TC/GL/KR) 购买骏马欢腾狂欢金卡的玩家名单
-- 时间范围: 2026/2/26 00:00 ~ 15:30
-- SKU: 各地区对应的 package0098
-- ***************************************************************

WITH orders AS (
    -- 1. 提取所有目标地区的支付流水
    SELECT 
        lcm_id, 
        order_id, 
        sku, 
        app_id,
        GET_JSON_OBJECT(memo1, '$.zoneId') AS zone_id,
        FROM_UNIXTIME(CAST(event_time / 1000 AS INT)) AS purchase_time
    FROM 
        dm_platform.daily_lcx_user_purchase
    WHERE 
        day = 20260226 
        AND app_id IN ('23002013', '63002013', '33002013') -- TC, GL, KR
        AND sku IN (
            -- TC (繁体)
            'com.denachina.g23002013.google_tier20.package0098',
            'com.denachina.g23002013.apk_tier20.package0098',
            'com.denachina.g23002013.apple_tier20.package0098',
            -- WW (GL/全球)
            'com.denachina.g63002013.google_tier20.package0098',
            'com.denachina.g63002013.apk_tier20.package0098',
            'com.denachina.g63002013.apple_tier20.package0098',
            -- KR (韩国)
            'com.denachina.g33002013.samsung_tier20.package0098',
            'com.denachina.g33002013.onestore_tier20.package0098',
            'com.denachina.g33002013.google_tier20.package0098',
            'com.denachina.g33002013.apple_tier20.package0098'
        )
        AND FROM_UNIXTIME(CAST(event_time / 1000 AS INT)) >= '2026-02-26 00:00:00'
        AND FROM_UNIXTIME(CAST(event_time / 1000 AS INT)) <= '2026-02-26 15:30:00'
),
mapping AS (
    -- 2. 联合三个地区的角色映射关系 (使用最新权限日志)
    SELECT DISTINCT mbga_uid, user_id, SPLIT(zone, '_')[2] AS zone, '23002013' as app_id FROM g23002013.game_log WHERE dt >= '20260225'
    UNION ALL
    SELECT DISTINCT mbga_uid, user_id, SPLIT(zone, '_')[2] AS zone, '63002013' as app_id FROM g63002013.game_log WHERE dt >= '20260225'
    UNION ALL
    SELECT DISTINCT mbga_uid, user_id, SPLIT(zone, '_')[2] AS zone, '33002013' as app_id FROM g33002013.game_log WHERE dt >= '20260225'
),
snapshot_mapping AS (
    -- 2.5 备选映射关系 (如果实时数据缺失，从 20260107 快照补全)
    SELECT mbga_uid, user_id, zone, app_id
    FROM (
        SELECT mbga_uid, user_id, SPLIT(zone, '_')[2] AS zone, '23002013' as app_id, ROW_NUMBER() OVER (PARTITION BY mbga_uid, SPLIT(zone, '_')[2] ORDER BY level DESC) AS ranks FROM g23002013.daily_user_snapshot WHERE day = 20260225
        UNION ALL
        SELECT mbga_uid, user_id, SPLIT(zone, '_')[2] AS zone, '63002013' as app_id, ROW_NUMBER() OVER (PARTITION BY mbga_uid, SPLIT(zone, '_')[2] ORDER BY level DESC) AS ranks FROM g63002013.daily_user_snapshot WHERE day = 20260225
        UNION ALL
        SELECT mbga_uid, user_id, SPLIT(zone, '_')[2] AS zone, '33002013' as app_id, ROW_NUMBER() OVER (PARTITION BY mbga_uid, SPLIT(zone, '_')[2] ORDER BY level DESC) AS ranks FROM g33002013.daily_user_snapshot WHERE day = 20260225
    ) t WHERE ranks = 1
)
-- 3. 关联并输出结果
SELECT 
    CASE 
        WHEN a.app_id = '23002013' THEN 'TC (繁中)'
        WHEN a.app_id = '63002013' THEN 'GL (全球)'
        WHEN a.app_id = '33002013' THEN 'KR (韩国)'
    END AS region,
    a.zone_id AS zone,
    a.sku,
    a.order_id,
    a.lcm_id AS dena_id,
    COALESCE(b.user_id, c.user_id) AS role_id,
    COUNT(a.order_id) OVER (PARTITION BY a.lcm_id, COALESCE(b.user_id, c.user_id)) AS total_purchase_count,
    a.purchase_time
FROM 
    orders a
LEFT JOIN 
    mapping b ON a.lcm_id = b.mbga_uid AND a.zone_id = b.zone AND a.app_id = b.app_id
LEFT JOIN 
    snapshot_mapping c ON a.lcm_id = c.mbga_uid AND a.zone_id = c.zone AND a.app_id = c.app_id
ORDER BY 
    region, purchase_time ASC;
