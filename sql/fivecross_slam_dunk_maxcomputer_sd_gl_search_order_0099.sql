-- 灌篮GL (GL) 订单购买用户名单查询
-- 产品 ID: com.denachina.g63002013.google_tier10.package0099
-- 时间范围: 北京时间 2026-02-12 00:00 �?2026-02-13 17:30
-- 环境: MaxCompute (ODPS)

SELECT 
    --a.lcm_id AS lid,             -- 对应 lid / lcx_id / lcm_id
    a.lcm_id AS lcx_id, 
    -- a.lcm_id AS lcm_id,
    b.user_id AS roleid,        -- 对应 roleid / gid
    --b.user_id AS gid,
    b.zone AS zone,
    a.order_id,
    a.sku AS product_id,
    a.purchase_time
FROM (
    -- 1. 筛选指定时段内的订单数�? -- 实时用game_log 非实时用sanpshot
    SELECT 
        lcm_id, 
        order_id, 
        sku, 
        GET_JSON_OBJECT(memo1, '$.zoneId') AS zone_id,
        FROM_UNIXTIME(CAST(event_time / 1000 AS INT)) AS purchase_time
    FROM 
        dm_platform.daily_lcx_user_purchase
    WHERE 
        day BETWEEN 20260212 AND 20260213
        AND app_id = '63002013' -- 灌篮GL
        AND sku = 'com.denachina.g63002013.google_tier10.package0099' -- 兼容不同商店前缀 (google/apple/apk)
) a 
LEFT JOIN (
    -- 2. 关联角色快照获取 user_id (roleid)
    -- 使用最新日期的快照
    SELECT DISTINCT 
        mbga_uid, 
        user_id, 
        SPLIT(zone, '_')[2] AS zone
    FROM 
        g63002013.game_log
    WHERE 
        dt BETWEEN 20260212 AND 20260213 -- 使用查询截止日期的快�?
) b ON a.lcm_id = b.mbga_uid AND a.zone_id = b.zone
WHERE 
    a.purchase_time >= '2026-02-12 00:00:00'
    AND a.purchase_time <= '2026-02-13 17:30:00'
ORDER BY 
    a.purchase_time ASC;
