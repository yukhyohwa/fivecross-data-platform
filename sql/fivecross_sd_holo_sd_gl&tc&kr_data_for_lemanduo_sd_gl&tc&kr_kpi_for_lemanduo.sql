/*
================================================================================
Game: Slam Dunk (灌篮高手) - HOLO 多地区 KPI 综合分析 (Daily / Monthly / Returner)
Regions Included:
 - 23002013: 灌篮繁体 (TC)
 - 33002013: 灌篮韩国 (KR)
 - 63002013: 灌篮全球 (GL)

Fields: Game ID, Game Name, Region, Date, NUU, DAU, DPU, Revenue, PayRate, ARPU, ARPPU, RR, LTV
================================================================================
*/

--------------------------------------------------------------------------------
-- 1. Daily KPI Analysis (All 3 Regions)
--------------------------------------------------------------------------------
-- SELECT * FROM daily_kpi_block... (Copy-paste logic from the multi-region join)
WITH daily_active_users AS (
    SELECT '23002013' as app_id, day, lcm_id FROM g23002013.lcx_user_active WHERE day between 20260301 and 20260507
    UNION ALL SELECT '33002013', day, lcm_id FROM g33002013.lcx_user_active WHERE day between 20260301 and 20260507
    UNION ALL SELECT '63002013', day, lcm_id FROM g63002013.lcx_user_active WHERE day between 20260301 and 20260507
),
daily_user_info AS (
    SELECT '23002013' as app_id, day, lcm_id, is_water, user_type FROM g23002013.daily_lcx_user_info WHERE day between 20260301 and 20260507
    UNION ALL SELECT '33002013', day, lcm_id, is_water, user_type FROM g33002013.daily_lcx_user_info WHERE day between 20260301 and 20260507
    UNION ALL SELECT '63002013', day, lcm_id, is_water, user_type FROM g63002013.daily_lcx_user_info WHERE day between 20260301 and 20260507
),
daily_purchase AS (
    SELECT p.app_id, p.day, p.lcm_id, b.exchange_rate * p.price_show as amount 
    FROM (
        SELECT '23002013' as app_id, day, lcm_id, price_show, unit_show FROM g23002013.lcx_user_purchase WHERE day between 20260301 and 20260507 AND price_show > 0
        UNION ALL SELECT '33002013', day, lcm_id, price_show, unit_show FROM g33002013.lcx_user_purchase WHERE day between 20260301 and 20260507 AND price_show > 0
        UNION ALL SELECT '63002013', day, lcm_id, price_show, unit_show FROM g63002013.lcx_user_purchase WHERE day between 20260301 and 20260507 AND price_show > 0
    ) p
    JOIN (SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny') b 
    ON LEFT(CAST(p.day AS TEXT), 6) = LEFT(b.day_hour, 6) AND p.unit_show = b.trans_from
),
daily_reg AS (
    SELECT '23002013' as app_id, day, lcm_id FROM g23002013.lcx_user_reg WHERE day between 20260301 and 20260507
    UNION ALL SELECT '33002013', day, lcm_id FROM g33002013.lcx_user_reg WHERE day between 20260301 and 20260507
    UNION ALL SELECT '63002013', day, lcm_id FROM g63002013.lcx_user_reg WHERE day between 20260301 and 20260507
)
SELECT 
    t1.app_id as "游戏ID", 
    CASE WHEN t1.app_id = '23002013' THEN '灌篮繁体' WHEN t1.app_id = '33002013' THEN '灌篮韩国' ELSE '灌篮全球' END as "游戏名称",
    CASE WHEN t1.app_id = '23002013' THEN 'TC' WHEN t1.app_id = '33002013' THEN 'KR' ELSE 'GL' END as "地区",
    t1.day as "$时间",
    reg."Nuu" as "新增用户数",
    act."Au" as "活跃用户数",
    pur."Puu" as "充值用户数",
    pur."Lnum" as "充值金额",
    CAST(ROUND(CAST(pur."Puu"*100.0/NULLIF(act."Au",0) AS NUMERIC), 2) AS FLOAT8) as "付费率(%)",
    CAST(ROUND(CAST(pur."Lnum"*1.0/NULLIF(act."Au",0) AS NUMERIC), 2) AS FLOAT8) as "ARPU",
    CAST(ROUND(CAST(pur."Lnum"*1.0/NULLIF(pur."Puu",0) AS NUMERIC), 2) AS FLOAT8) as "ARPPU"
FROM (SELECT DISTINCT app_id, day FROM daily_active_users) t1
LEFT JOIN (
    SELECT a.app_id, a.day, COUNT(DISTINCT a.lcm_id) as "Au" 
    FROM daily_active_users a 
    JOIN daily_user_info i ON a.app_id = i.app_id AND a.day = i.day AND a.lcm_id = i.lcm_id 
    WHERE i.is_water = '不是水' GROUP BY 1, 2
) act ON t1.app_id = act.app_id AND t1.day = act.day
LEFT JOIN (
    SELECT app_id, day, COUNT(DISTINCT lcm_id) as "Nuu" 
    FROM daily_reg GROUP BY 1, 2
) reg ON t1.app_id = reg.app_id AND t1.day = reg.day
LEFT JOIN (
    SELECT p.app_id, p.day, COUNT(DISTINCT p.lcm_id) as "Puu", SUM(p.amount) as "Lnum" 
    FROM daily_purchase p 
    JOIN daily_user_info i ON p.app_id = i.app_id AND p.day = i.day AND p.lcm_id = i.lcm_id 
    WHERE i.is_water = '不是水' GROUP BY 1, 2
) pur ON t1.app_id = pur.app_id AND t1.day = pur.day
WHERE act."Au" > 0
ORDER BY 1, 4;



--------------------------------------------------------------------------------
-- 2. Monthly KPI Analysis (All 3 Regions)
--------------------------------------------------------------------------------
WITH monthly_active_users AS (
    SELECT '23002013' as app_id, month, lcm_id FROM g23002013.lcx_user_active WHERE month between 202603 and 202605 GROUP BY 1,2,3
    UNION ALL SELECT '33002013', month, lcm_id FROM g33002013.lcx_user_active WHERE month between 202603 and 202605 GROUP BY 1,2,3
    UNION ALL SELECT '63002013', month, lcm_id FROM g63002013.lcx_user_active WHERE month between 202603 and 202605 GROUP BY 1,2,3
),
monthly_user_info AS (
    SELECT '23002013' as app_id, month, lcm_id, is_water FROM g23002013.monthly_lcx_user_info WHERE month between 202603 and 202605
    UNION ALL SELECT '33002013', month, lcm_id, is_water FROM g33002013.monthly_lcx_user_info WHERE month between 202603 and 202605
    UNION ALL SELECT '63002013', month, lcm_id, is_water FROM g63002013.monthly_lcx_user_info WHERE month between 202603 and 202605
),
monthly_purchase_mapped AS (
    SELECT a.app_id, a.month, a.lcm_id, SUM(a.price_show * b.exchange_rate) as amount
    FROM (
        SELECT '23002013' as app_id, month, lcm_id, price_show, unit_show, day FROM g23002013.lcx_user_purchase WHERE month between 202603 and 202605 AND price_show > 0
        UNION ALL SELECT '33002013', month, lcm_id, price_show, unit_show, day FROM g33002013.lcx_user_purchase WHERE month between 202603 and 202605 AND price_show > 0
        UNION ALL SELECT '63002013', month, lcm_id, price_show, unit_show, day FROM g63002013.lcx_user_purchase WHERE month between 202603 and 202605 AND price_show > 0
    ) a
    LEFT JOIN (SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny') b 
    ON LEFT(CAST(a.day AS TEXT), 6) = LEFT(b.day_hour, 6) AND a.unit_show = b.trans_from
    GROUP BY 1,2,3
)
SELECT 
    t.app_id as "游戏ID", 
    CASE WHEN t.app_id = '23002013' THEN '灌篮繁体' WHEN t.app_id = '33002013' THEN '灌篮韩国' ELSE '灌篮全球' END as "游戏名称",
    CASE WHEN t.app_id = '23002013' THEN 'TC' WHEN t.app_id = '33002013' THEN 'KR' ELSE 'GL' END as "地区",
    t.month as "$时间",
    act."Au" as "活跃用户数",
    pur."Puu" as "充值用户数",
    pur."Lnum" as "充值金额",
    CAST(ROUND(CAST(pur."Lnum"*1.0/NULLIF(act."Au",0) AS NUMERIC), 2) AS FLOAT8) as "ARPU",
    CAST(ROUND(CAST(pur."Lnum"*1.0/NULLIF(pur."Puu",0) AS NUMERIC), 2) AS FLOAT8) as "ARPPU"
FROM (SELECT DISTINCT app_id, month FROM monthly_active_users) t
LEFT JOIN (
    SELECT a.app_id, a.month, COUNT(DISTINCT a.lcm_id) as "Au" 
    FROM monthly_active_users a 
    JOIN monthly_user_info i ON a.app_id=i.app_id AND a.month=i.month AND a.lcm_id=i.lcm_id 
    WHERE i.is_water='不是水' GROUP BY 1,2
) act ON t.app_id=act.app_id AND t.month=act.month
LEFT JOIN (
    SELECT p.app_id, p.month, COUNT(DISTINCT p.lcm_id) as "Puu", SUM(p.amount) as "Lnum" 
    FROM monthly_purchase_mapped p 
    JOIN monthly_user_info i ON p.app_id=i.app_id AND p.month=i.month AND p.lcm_id=i.lcm_id 
    WHERE i.is_water='不是水' GROUP BY 1,2
) pur ON t.app_id=pur.app_id AND t.month=pur.month
ORDER BY 1, 4;



--------------------------------------------------------------------------------
-- 3. Returner User KPI (RUU Version, Multi-Region)
--------------------------------------------------------------------------------
WITH daily_purchase AS (
    SELECT p.app_id, p.day, p.lcm_id, b.exchange_rate * p.price_show as amount 
    FROM (
        SELECT '23002013' as app_id, day, lcm_id, price_show, unit_show FROM g23002013.lcx_user_purchase WHERE day between 20260301 and 20260507 AND price_show > 0
        UNION ALL SELECT '33002013', day, lcm_id, price_show, unit_show FROM g33002013.lcx_user_purchase WHERE day between 20260301 and 20260507 AND price_show > 0
        UNION ALL SELECT '63002013', day, lcm_id, price_show, unit_show FROM g63002013.lcx_user_purchase WHERE day between 20260301 and 20260507 AND price_show > 0
    ) p
    JOIN (SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny') b 
    ON LEFT(CAST(p.day AS TEXT), 6) = LEFT(b.day_hour, 6) AND p.unit_show = b.trans_from
),
ruu_active_info AS (
    SELECT '23002013' as app_id, day, lcm_id FROM g23002013.daily_lcx_user_info WHERE day BETWEEN 20260301 AND 20260507 AND is_water = '不是水' AND user_type = 'ruu'
    UNION ALL
    SELECT '33002013' as app_id, day, lcm_id FROM g33002013.daily_lcx_user_info WHERE day BETWEEN 20260301 AND 20260507 AND is_water = '不是水' AND user_type = 'ruu'
    UNION ALL
    SELECT '63002013' as app_id, day, lcm_id FROM g63002013.daily_lcx_user_info WHERE day BETWEEN 20260301 AND 20260507 AND is_water = '不是水' AND user_type = 'ruu'
)
SELECT 
    r.app_id as "游戏ID",
    CASE WHEN r.app_id = '23002013' THEN '灌篮繁体' WHEN r.app_id = '33002013' THEN '灌篮韩国' ELSE '灌篮全球' END as "游戏名称",
    CASE WHEN r.app_id = '23002013' THEN 'TC' WHEN r.app_id = '33002013' THEN 'KR' ELSE 'GL' END as "地区",
    r.day as "$时间",
    COUNT(DISTINCT r.lcm_id) as "回流活跃(RUU)",
    COUNT(DISTINCT p.lcm_id) as "回流付费人数",
    CAST(SUM(p.amount) AS INT) as "回流充值金额",
    CAST(ROUND(CAST(COUNT(DISTINCT p.lcm_id)*100.0/NULLIF(COUNT(DISTINCT r.lcm_id),0) AS NUMERIC), 2) AS FLOAT8) as "回流付费率(%)",
    CAST(ROUND(CAST(SUM(p.amount)*1.0/NULLIF(COUNT(DISTINCT r.lcm_id),0) AS NUMERIC), 2) AS FLOAT8) as "回流ARPU",
    CAST(ROUND(CAST(SUM(p.amount)*1.0/NULLIF(COUNT(DISTINCT p.lcm_id),0) AS NUMERIC), 2) AS FLOAT8) as "回流ARPPU"
FROM ruu_active_info r
LEFT JOIN daily_purchase p ON r.app_id = p.app_id AND r.day = p.day AND r.lcm_id = p.lcm_id
GROUP BY 1, 2, 3, 4
ORDER BY 1, 4;

--------------------------------------------------------------------------------
-- 4. 获取三个地区的每日流水,KPI完成情况, 确定月份时间
--------------------------------------------------------------------------------
WITH regional_purchase_raw AS (
    -- 繁体 (TC)
    SELECT '23002013' as app_id, a.day, a.price_show * b.exchange_rate as amount
    FROM g23002013.lcx_user_purchase a
    LEFT JOIN (SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny') b 
    ON LEFT(CAST(a.day AS TEXT), 6) = LEFT(b.day_hour, 6) AND a.unit_show = b.trans_from
    WHERE a.day BETWEEN 20260501 AND 20260507

    UNION ALL
    -- 韩国 (KR)
    SELECT '33002013' as app_id, a.day, a.price_show * b.exchange_rate as amount
    FROM g33002013.lcx_user_purchase a
    LEFT JOIN (SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny') b 
    ON LEFT(CAST(a.day AS TEXT), 6) = LEFT(b.day_hour, 6) AND a.unit_show = b.trans_from
    WHERE a.day BETWEEN 20260501 AND 20260507

    UNION ALL
    -- 全球 (GL)
    SELECT '63002013' as app_id, a.day, a.price_show * b.exchange_rate as amount
    FROM g63002013.lcx_user_purchase a
    LEFT JOIN (SELECT day_hour, trans_from, exchange_rate FROM dm_dimension.dim_itunes_exchange_rate_fmp WHERE trans_to = 'cny') b 
    ON LEFT(CAST(a.day AS TEXT), 6) = LEFT(b.day_hour, 6) AND a.unit_show = b.trans_from
    WHERE a.day BETWEEN 20260501 AND 20260507
),
-- 计算每日合计与月度累计数据
daily_actual_sums AS (
    SELECT app_id, day, CAST(SUM(amount) AS INT) as daily_amount
    FROM regional_purchase_raw
    GROUP BY 1, 2
),
actual_with_accum AS (
    SELECT 
        a.app_id, 
        a.day, 
        a.daily_amount,
        (SELECT SUM(b.daily_amount) FROM daily_actual_sums b WHERE a.app_id = b.app_id AND b.day <= a.day) as monthly_accum
    FROM daily_actual_sums a
),
-- 获取 KPI 目标数据 (dm_platform.kpi_target)
kpi_targets AS (
    SELECT 
        CAST(app_id AS TEXT) as app_id, 
        base_date, 
        sales as target_daily, 
        sales_accum as target_accum
    FROM dm_platform.kpi_target 
    WHERE app_id IN (23002013, 33002013, 63002013) 
    AND month = 202605
)
--------------------------------------------------------------------------------
-- 最终关联输出
--------------------------------------------------------------------------------
SELECT 
    k.app_id as "游戏ID",
    CASE 
        WHEN k.app_id = '23002013' THEN '灌篮繁体'
        WHEN k.app_id = '33002013' THEN '灌篮韩国'
        WHEN k.app_id = '63002013' THEN '灌篮全球'
    END as "游戏名称",
    k.base_date as "$时间",
    COALESCE(a.daily_amount, 0) as "{bar}当日实际完成",
    COALESCE(a.monthly_accum, 0) as "{line}当月实际累计",
    k.target_daily as "{bar}当日KPI目标",
    k.target_accum as "{line}当月KPI累计"
FROM kpi_targets k
LEFT JOIN actual_with_accum a ON k.app_id = a.app_id AND k.base_date = a.day
ORDER BY 1, 3;
