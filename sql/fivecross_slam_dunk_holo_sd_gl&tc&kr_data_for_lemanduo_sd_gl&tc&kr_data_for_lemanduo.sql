

--------------------------------------------------------------------------------
-- 1. SD2-充值商品明细
--------------------------------------------------------------------------------
/*
================================================================================
Game: Slam Dunk (灌篮高手) - Holo 海外多地区查询
Regions: 
 - TC (繁体): g23002013
 - KR (韩国): g33002013
 - GL (全球): g63002013
================================================================================
*/
WITH daily_purchase_raw AS (
    SELECT 'TC' as region, day, lcm_id, memo1, sku, price_show, unit_show, sku_name FROM g23002013.lcx_user_purchase WHERE day BETWEEN 20260301 and 20260507
    UNION ALL
    SELECT 'KR' as region, day, lcm_id, memo1, sku, price_show, unit_show, sku_name FROM g33002013.lcx_user_purchase WHERE day BETWEEN 20260301 and 20260507
    UNION ALL
    SELECT 'GL' as region, day, lcm_id, memo1, sku, price_show, unit_show, sku_name FROM g63002013.lcx_user_purchase WHERE day BETWEEN 20260301 and 20260507
),
exchange_rate AS (
    SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny'
)
SELECT
    main.region as "地区",
    main.day as "$时间",
    cast(lcm_amount as int) as "金额",
    buy_uu as "购买人数",
    item_id as "商品ID",
    sku as "sku",
    main.sku_name as "充值商品",
    cast(COALESCE(cast(main.sku_name as text), ' ') as text) as name
FROM (
    SELECT
        sub.region, sub.day, sub.item_id, sub.sku,
        sum(sub.lcm_amount) as lcm_amount,
        sub.sku_name, count(distinct sub.lcm_id) as buy_uu
    FROM (
        SELECT
            a.region, a.day, a.lcm_id, a.sku, a.sku_name,
            split_part(split_part(a.memo1, 'purchasePayload', 2), ',', 2) as item_id,
            sum(b.exchange_rate * a.price_show) as lcm_amount
        FROM daily_purchase_raw a
        LEFT JOIN exchange_rate b 
            ON LEFT(cast(a.day as text), 6) = LEFT(b.day_hour, 6) 
            AND a.unit_show = b.trans_from
        WHERE a.price_show > 0 
          AND left(split_part(split_part(a.memo1, '"zoneId":"', 2), '"', 1), 1) in ('1','2','3')
        GROUP BY 1, 2, 3, 4, 5, 6
    ) sub
    GROUP BY 1, 2, 3, 4, 6
) main
ORDER BY 1, 2;


--------------------------------------------------------------------------------
-- 2. SD2-每日点券消耗
--------------------------------------------------------------------------------
/*
================================================================================
Game: Slam Dunk (灌篮高手) - HOLO 海外 adhoc 查询 (点券消耗)
Regions: 
 - g23002013: 灌篮繁体
 - g33002013: 灌篮韩国
 - g63002013: 灌篮全球
================================================================================
*/

WITH resource_change AS (
    SELECT '23002013' as game_id, '灌篮繁体' as game_name, 'TC' as region, day, lcm_id, reason, reason_name, diff, zone_id, item_id, type FROM g23002013.dm_server_resource_change_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '33002013' as game_id, '灌篮韩国' as game_name, 'KR' as region, day, lcm_id, reason, reason_name, diff, zone_id, item_id, type FROM g33002013.dm_server_resource_change_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '63002013' as game_id, '灌篮全球' as game_name, 'GL' as region, day, lcm_id, reason, reason_name, diff, zone_id, item_id, type FROM g63002013.dm_server_resource_change_odps WHERE day between 20260301 and 20260507
)
SELECT 
    a_main.game_id as "游戏ID",
    a_main.game_name as "游戏名称",
    a_main.region as "地区",
    a_main.day as "$时间",
    reason as "埋点",
    a_main.reason_name as "行为",
    a_main.num as "数量",
    uu as "人数",
    concat(reason, reason_name) as "name" 
FROM (
    SELECT 
        a.game_id, a.game_name, a.region, a.day, a.reason_name, a.reason,
        sum(a.num) as num, sum(lid) uu
    FROM (
        SELECT 
            r.game_id, r.game_name, r.region, r.day, r.lcm_id, r.reason, r.reason_name,
            sum(abs(cast(r.diff as int))) as num, 1 as lid
        FROM resource_change r
        LEFT JOIN dm_platform.dim_user_blacklist_odps b 
            ON r.lcm_id = b.lcm_id AND r.game_id = b.app_id AND b.reason = 'black'
        WHERE r.type = 'use' AND r.item_id in ('stamps','freestamps')
          AND left(RIGHT(r.zone_id, 5), 1) in ('1','2','3')
          AND b.lcm_id IS NULL -- 排除黑名单
        GROUP BY 1, 2, 3, 4, 5, 6, 7
    ) a 
    GROUP BY 1, 2, 3, 4, 5, 6
) as a_main  
ORDER BY 1, 4;


--------------------------------------------------------------------------------
-- 3. SD2-商店消耗分布(点券)
--------------------------------------------------------------------------------
/*
================================================================================
Game: Slam Dunk (灌篮高手) - HOLO 海外 adhoc 查询 (商店消耗分布)
Regions: 
 - g23002013: 灌篮繁体
 - g33002013: 灌篮韩国
 - g63002013: 灌篮全球
================================================================================
*/

WITH shop_detail AS (
    SELECT '23002013' as game_id, '灌篮繁体' as game_name, 'TC' as region, day, shop_id, shop_name, item_id, item_name, lcm_id, role_id, amount, coin_typ, zone FROM g23002013.server_shop_detail_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '33002013' as game_id, '灌篮韩国' as game_name, 'KR' as region, day, shop_id, shop_name, item_id, item_name, lcm_id, role_id, amount, coin_typ, zone FROM g33002013.server_shop_detail_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '63002013' as game_id, '灌篮全球' as game_name, 'GL' as region, day, shop_id, shop_name, item_id, item_name, lcm_id, role_id, amount, coin_typ, zone FROM g63002013.server_shop_detail_odps WHERE day between 20260301 and 20260507
)
SELECT 
    game_id as "游戏ID",
    game_name as "游戏名称",
    region as "地区",
    '20260301~20260507' as "$日期",
    concat(shop_id, ' ', shop_name) as "商店",
    concat(item_id, ' ', item_name) as "商品",
    count(distinct concat(lcm_id, role_id)) as "总人数",
    sum(cast(amount as bigint)) as "总消耗",
    concat(concat(shop_id, ' ', shop_name), concat(item_id, ' ', item_name)) as name
FROM shop_detail
WHERE coin_typ = 'stamps'
  AND left(cast(zone as text), 1) in ('1','2','3')
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1, sum(cast(amount as bigint)) desc;


--------------------------------------------------------------------------------
-- 4. SD2-连锁礼包购买情况
--------------------------------------------------------------------------------
/*
================================================================================
Game: Slam Dunk (灌篮高手) - HOLO 海外 adhoc 查询 (连锁礼包购买情况)
Regions: 
 - g23002013: 灌篮繁体
 - g33002013: 灌篮韩国
 - g63002013: 灌篮全球
================================================================================
*/

WITH chain_buy AS (
    SELECT '23002013' as game_id, '灌篮繁体' as game_name, 'TC' as region, day, vip, linkid, giftid, role_id, lcm_id, extra_info, stamp_cost, money_cost, rmb_cost FROM g23002013.server_chain_buy_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '33002013' as game_id, '灌篮韩国' as game_name, 'KR' as region, day, vip, linkid, giftid, role_id, lcm_id, extra_info, stamp_cost, money_cost, rmb_cost FROM g33002013.server_chain_buy_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '63002013' as game_id, '灌篮全球' as game_name, 'GL' as region, day, vip, linkid, giftid, role_id, lcm_id, extra_info, stamp_cost, money_cost, rmb_cost FROM g63002013.server_chain_buy_odps WHERE day between 20260301 and 20260507
)
SELECT 
    game_id as "游戏ID",
    game_name as "游戏名称",
    region as "地区",
    '20260301~20260507' as "$日期",
    vip as "VIP",
    linkid as "连锁礼包",
    giftid as "礼包ID",
    count(distinct concat(role_id, lcm_id)) as "购买人数",
    sum(cast(extra_info as bigint)) as "购买次数",
    sum(stamp_cost) as "点券消耗",
    sum(money_cost) as "钻石消耗",
    sum(rmb_cost) as "直购消耗",
    concat(vip, linkid, giftid) as name
FROM chain_buy
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY 1, linkid, giftid, vip;

--------------------------------------------------------------------------------
-- 5. SD2-奇遇礼包购买情况
--------------------------------------------------------------------------------
/*
================================================================================
Game: Slam Dunk (灌篮高手) - HOLO 海外 adhoc 查询 (奇遇礼包购买情况)
Regions: 
 - g23002013: 灌篮繁体
 - g33002013: 灌篮韩国
 - g63002013: 灌篮全球
================================================================================
*/

WITH adventure_buy AS (
    SELECT '23002013' as game_id, '灌篮繁体' as game_name, 'TC' as region, day, vip, item_id, activate_uu, activate_times, buy_uu, buy_times, stamps_cost, money_cost FROM g23002013.dm_server_adventure_buy_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '33002013' as game_id, '灌篮韩国' as game_name, 'KR' as region, day, vip, item_id, activate_uu, activate_times, buy_uu, buy_times, stamps_cost, money_cost FROM g33002013.dm_server_adventure_buy_odps WHERE day between 20260301 and 20260507
    UNION ALL
    SELECT '63002013' as game_id, '灌篮全球' as game_name, 'GL' as region, day, vip, item_id, activate_uu, activate_times, buy_uu, buy_times, stamps_cost, money_cost FROM g63002013.dm_server_adventure_buy_odps WHERE day between 20260301 and 20260507
)
SELECT 
    game_id as "游戏ID",
    game_name as "游戏名称",
    region as "地区",
    '20260301~20260507' as "$日期",
    vip as "VIP",
    item_id as "礼包ID",
    sum(activate_uu) as "激活人数",
    sum(activate_times) as "激活次数",
    sum(buy_uu) as "购买人数",
    sum(buy_times) as "购买次数",
    sum(stamps_cost) as "点券消耗",
    sum(money_cost) as "钻石消耗",
    concat(vip, item_id) as name
FROM adventure_buy
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1, vip, item_id;
