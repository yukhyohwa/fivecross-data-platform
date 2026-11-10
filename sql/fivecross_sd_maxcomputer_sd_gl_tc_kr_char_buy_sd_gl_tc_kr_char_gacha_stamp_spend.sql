-- 转盘币  140035900 扭蛋券  140035901 转盘币 --牧绅一
-- 转盘币  140035980 人猿大王试炼币  140035969 鱼住传奇转盘卡  --鱼住纯
-- 140036011 传奇藤真扭蛋券 83100553,83100554 140036012 藤真传奇转盘卡  83100556,83100558
-- 140036084 傳奇仙道扭蛋券 83700553,83700554,83700555 140036086 陵南王牌轉盤幣  83700556,83700558,83700558 
-- 141024775 传奇福田扭蛋券 81102065,81102066,81102067 141024776 传奇福田轉盤幣  81100362,81100364,81100365 
-- 141024860 传奇清田扭蛋券 81101796,81101797,81101798 141024862 传奇清田转盘卡  83700592,83700594,83700595 
-- 141024940 传奇永野满转盘卡 

-- SELECT 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name,
--     COUNT(DISTINCT CONCAT(lcm_id, role_id)) AS "总人数",
--     SUM(CAST(amount AS BIGINT)) AS "总消耗"
-- FROM g23002013.server_shop_detail
-- WHERE day BETWEEN 20260101 AND 20260121 
--   AND coin_typ = 'stamps' 
--   AND lcm_id IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.daily_lcx_user_info 
--       WHERE day >= 20241101 
--         AND app_id = 13002010 
--         AND reg_day = day
--   )
--   AND lcm_id NOT IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.dim_user_blacklist 
--       WHERE app_id IN ('23002013', '33002013', '63002013')
--   )
--   -- AND item_id IN ('83100431', '83100434') -- 牧绅一 
--   -- AND item_id IN ('83100486') -- 鱼住纯
--   -- AND item_id IN ('83100553', '83100554', '83100556', '83100558') -- 藤真健司  
--   -- AND item_id IN ('81101798') -- 清田
-- GROUP BY 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name
-- ORDER BY 
--     SUM(CAST(amount AS BIGINT)) DESC;

SELECT 
    obj,
    -SUM(CAST(diff2 AS BIGINT)) AS spend
FROM (
    SELECT 
        log_t,
        user_id,
        mbga_uid,
        obj,
        diff,
        a_typ,
        a_rst
    FROM g63002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20260312 AND 20260401 
      AND mbga_uid NOT IN (
          SELECT DISTINCT lcm_id 
          FROM dm_platform.dim_user_blacklist 
          WHERE app_id IN ('23002013', '33002013', '63002013')
      )
      AND (obj LIKE '%141024940%' OR obj LIKE '%141024940%') 
      AND CAST(diff AS DOUBLE) > 0
) a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2 
WHERE obj2 IN ('dmp:stamps', 'dmp:freestamps') 
  AND CAST(diff2 AS DOUBLE) < 0
GROUP BY 
    obj;-- 转盘币  140035900 扭蛋券  140035901 转盘币 --牧绅一
-- 转盘币  140035980 人猿大王试炼币  140035969 鱼住传奇转盘卡  --鱼住纯
-- 140036011 传奇藤真扭蛋券 83100553,83100554 140036012 藤真传奇转盘卡  83100556,83100558
-- 140036084 傳奇仙道扭蛋券 83700553,83700554,83700555 140036086 陵南王牌轉盤幣  83700556,83700558,83700558 
-- 141024775 传奇福田扭蛋券 81102065,81102066,81102067 141024776 传奇福田轉盤幣  81100362,81100364,81100365 
-- 141024860 传奇清田扭蛋券 81101796,81101797,81101798 141024862 传奇清田转盘卡  83700592,83700594,83700595 
-- 141024940 传奇永野满转盘卡 

-- SELECT 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name,
--     COUNT(DISTINCT CONCAT(lcm_id, role_id)) AS "总人数",
--     SUM(CAST(amount AS BIGINT)) AS "总消耗"
-- FROM g23002013.server_shop_detail
-- WHERE day BETWEEN 20260101 AND 20260121 
--   AND coin_typ = 'stamps' 
--   AND lcm_id IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.daily_lcx_user_info 
--       WHERE day >= 20241101 
--         AND app_id = 13002010 
--         AND reg_day = day
--   )
--   AND lcm_id NOT IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.dim_user_blacklist 
--       WHERE app_id IN ('23002013', '33002013', '63002013')
--   )
--   -- AND item_id IN ('83100431', '83100434') -- 牧绅一 
--   -- AND item_id IN ('83100486') -- 鱼住纯
--   -- AND item_id IN ('83100553', '83100554', '83100556', '83100558') -- 藤真健司  
--   -- AND item_id IN ('81101798') -- 清田
-- GROUP BY 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name
-- ORDER BY 
--     SUM(CAST(amount AS BIGINT)) DESC;

SELECT 
    obj,
    -SUM(CAST(diff2 AS BIGINT)) AS spend
FROM (
    SELECT 
        log_t,
        user_id,
        mbga_uid,
        obj,
        diff,
        a_typ,
        a_rst
    FROM g63002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20260312 AND 20260401 
      AND mbga_uid NOT IN (
          SELECT DISTINCT lcm_id 
          FROM dm_platform.dim_user_blacklist 
          WHERE app_id IN ('23002013', '33002013', '63002013')
      )
      AND (obj LIKE '%141024940%' OR obj LIKE '%141024940%') 
      AND CAST(diff AS DOUBLE) > 0
) a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2 
WHERE obj2 IN ('dmp:stamps', 'dmp:freestamps') 
  AND CAST(diff2 AS DOUBLE) < 0
GROUP BY 
    obj;-- 转盘币  140035900 扭蛋券  140035901 转盘币 --牧绅一
-- 转盘币  140035980 人猿大王试炼币  140035969 鱼住传奇转盘卡  --鱼住纯
-- 140036011 传奇藤真扭蛋券 83100553,83100554 140036012 藤真传奇转盘卡  83100556,83100558
-- 140036084 傳奇仙道扭蛋券 83700553,83700554,83700555 140036086 陵南王牌轉盤幣  83700556,83700558,83700558 
-- 141024775 传奇福田扭蛋券 81102065,81102066,81102067 141024776 传奇福田轉盤幣  81100362,81100364,81100365 
-- 141024860 传奇清田扭蛋券 81101796,81101797,81101798 141024862 传奇清田转盘卡  83700592,83700594,83700595 
-- 141024940 传奇永野满转盘卡 

-- SELECT 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name,
--     COUNT(DISTINCT CONCAT(lcm_id, role_id)) AS "总人数",
--     SUM(CAST(amount AS BIGINT)) AS "总消耗"
-- FROM g23002013.server_shop_detail
-- WHERE day BETWEEN 20260101 AND 20260121 
--   AND coin_typ = 'stamps' 
--   AND lcm_id IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.daily_lcx_user_info 
--       WHERE day >= 20241101 
--         AND app_id = 13002010 
--         AND reg_day = day
--   )
--   AND lcm_id NOT IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.dim_user_blacklist 
--       WHERE app_id IN ('23002013', '33002013', '63002013')
--   )
--   -- AND item_id IN ('83100431', '83100434') -- 牧绅一 
--   -- AND item_id IN ('83100486') -- 鱼住纯
--   -- AND item_id IN ('83100553', '83100554', '83100556', '83100558') -- 藤真健司  
--   -- AND item_id IN ('81101798') -- 清田
-- GROUP BY 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name
-- ORDER BY 
--     SUM(CAST(amount AS BIGINT)) DESC;

SELECT 
    obj,
    -SUM(CAST(diff2 AS BIGINT)) AS spend
FROM (
    SELECT 
        log_t,
        user_id,
        mbga_uid,
        obj,
        diff,
        a_typ,
        a_rst
    FROM g63002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20260312 AND 20260401 
      AND mbga_uid NOT IN (
          SELECT DISTINCT lcm_id 
          FROM dm_platform.dim_user_blacklist 
          WHERE app_id IN ('23002013', '33002013', '63002013')
      )
      AND (obj LIKE '%141024940%' OR obj LIKE '%141024940%') 
      AND CAST(diff AS DOUBLE) > 0
) a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2 
WHERE obj2 IN ('dmp:stamps', 'dmp:freestamps') 
  AND CAST(diff2 AS DOUBLE) < 0
GROUP BY 
    obj;-- 转盘币  140035900 扭蛋券  140035901 转盘币 --牧绅一
-- 转盘币  140035980 人猿大王试炼币  140035969 鱼住传奇转盘卡  --鱼住纯
-- 140036011 传奇藤真扭蛋券 83100553,83100554 140036012 藤真传奇转盘卡  83100556,83100558
-- 140036084 傳奇仙道扭蛋券 83700553,83700554,83700555 140036086 陵南王牌轉盤幣  83700556,83700558,83700558 
-- 141024775 传奇福田扭蛋券 81102065,81102066,81102067 141024776 传奇福田轉盤幣  81100362,81100364,81100365 
-- 141024860 传奇清田扭蛋券 81101796,81101797,81101798 141024862 传奇清田转盘卡  83700592,83700594,83700595 
-- 141024940 传奇永野满转盘卡 

-- SELECT 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name,
--     COUNT(DISTINCT CONCAT(lcm_id, role_id)) AS "总人数",
--     SUM(CAST(amount AS BIGINT)) AS "总消耗"
-- FROM g23002013.server_shop_detail
-- WHERE day BETWEEN 20260101 AND 20260121 
--   AND coin_typ = 'stamps' 
--   AND lcm_id IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.daily_lcx_user_info 
--       WHERE day >= 20241101 
--         AND app_id = 13002010 
--         AND reg_day = day
--   )
--   AND lcm_id NOT IN (
--       SELECT DISTINCT lcm_id 
--       FROM dm_platform.dim_user_blacklist 
--       WHERE app_id IN ('23002013', '33002013', '63002013')
--   )
--   -- AND item_id IN ('83100431', '83100434') -- 牧绅一 
--   -- AND item_id IN ('83100486') -- 鱼住纯
--   -- AND item_id IN ('83100553', '83100554', '83100556', '83100558') -- 藤真健司  
--   -- AND item_id IN ('81101798') -- 清田
-- GROUP BY 
--     shop_id,
--     shop_name,
--     item_id,
--     item_name
-- ORDER BY 
--     SUM(CAST(amount AS BIGINT)) DESC;

SELECT 
    obj,
    -SUM(CAST(diff2 AS BIGINT)) AS spend
FROM (
    SELECT 
        log_t,
        user_id,
        mbga_uid,
        obj,
        diff,
        a_typ,
        a_rst
    FROM g63002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20260312 AND 20260401 
      AND mbga_uid NOT IN (
          SELECT DISTINCT lcm_id 
          FROM dm_platform.dim_user_blacklist 
          WHERE app_id IN ('23002013', '33002013', '63002013')
      )
      AND (obj LIKE '%141024940%' OR obj LIKE '%141024940%') 
      AND CAST(diff AS DOUBLE) > 0
) a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2 
WHERE obj2 IN ('dmp:stamps', 'dmp:freestamps') 
  AND CAST(diff2 AS DOUBLE) < 0
GROUP BY 
    obj;