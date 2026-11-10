-- ODPS SQL 常用查询�?(Business Intelligence Report Library)
-- ********************************************************************
-- Author: 张君�?
-- Create Time: 2020-12-17
-- Last Modified: 2026-01-12
-- Description: 涵盖多应�?Game 9/12/23/33/63/65�?的业务统计、KPI 报表及异常分�?
-- ********************************************************************

-- 开�?Hive 兼容模式，支持常用窗口函数及语法
SET odps.sql.hive.compatible = TRUE;

-- =================================================================================
-- 目录 (TABLE OF CONTENTS)
-- 1.  核心 KPI 统计 (KPI Statistics & Financials)
-- 2.  Wings & 全球区组筛�?(Zone & Region Filtering)
-- 3.  全球�?KPI 统计 (GL Monthly KPI)
-- 4.  虚拟货币存量与点券计�?(Currency Stocks & Gift Analysis)
-- 5.  战令/通行证购买统�?(Battle Pass & BP Purchasing)
-- 6.  游戏数据库看�?(Game Library & Standard Metrics)
-- 7.  用户留存�?LTV 滚算 (Retention & LTV Calculation)
-- 8.  卡牌配置、收入与角色转化 (Card Config, Revenue & Conversion)
-- 9.  钱包、三方充值与流水 (Wallet & Payment Channel Analysis)
-- 10. Jump 比赛数据统计 (Matchmaking & Battle Analytics)
-- 11. 月卡与订阅统�?(Monthly Card & Subscription)
-- 12. 资源消耗与养成计算 (Resource Consumption & Growth)
-- 13. PCU/ACU 在线与用户量�?(Online Metrics & User Scale)
-- 14. 付费构成与行为分�?(Payment Structure & Behavior)
-- 15. 专项数据对比与大�?KPI (Special Analysis & Regional KPI)
-- =================================================================================



-- =================================================================================
-- 1. 核心 KPI 统计 (KPI Statistics & Financials)
-- =================================================================================

-- 1.1 基础月度活跃与流水统�?(按应用、商店、渠道分�?
SELECT 
    app_id,
    store,
    affname,
    COUNT(DISTINCT lcm_id) AS all_uu,
    COUNT(DISTINCT CASE WHEN day BETWEEN 20240901 AND 20240930 THEN lcm_id END) AS month_uu,
    SUM(CASE WHEN day BETWEEN 20240901 AND 20240930 THEN purchase END) AS month_sales
FROM dm_platform.daily_lcx_user_info  
WHERE day >= 20180101 
  AND app_id IN ('23000113', '65002004', '65002005', '65002007', '23002013', '33002013', '63002013')
GROUP BY app_id, store, affname 
HAVING month_uu > 10;


-- 1.2 详细年月对比统计 (区分 LCX 钱包与直接充值，包含汇率换算)
-- 逻辑：通过 row_number 对汇率表进行月度去重，关联获�?CNY 美元/本币汇率
SELECT 
    a.app_id,
    a.store,
    a.affname,
    COUNT(DISTINCT a.lcm_id) AS all_uu,
    COUNT(DISTINCT CASE WHEN day_typ = 1 THEN a.lcm_id END) AS year_uu,
    COUNT(DISTINCT b.lcm_id) AS year_puu,
    SUM(zhijie_year_sales) AS zhijie_year_sales,
    SUM(pc_year_sales) AS pc_year_sales,
    COUNT(DISTINCT CASE WHEN day_typ = 2 THEN a.lcm_id END) AS month_uu,
    COUNT(DISTINCT CASE WHEN b.zhijie_month_sales > 0 OR b.pc_month_sales > 0 THEN b.lcm_id END) AS month_puu,
    SUM(zhijie_month_sales) AS zhijie_month_sales,
    SUM(pc_month_sales) AS pc_month_sales
FROM (
    -- 用户基础信息分组，标记所属统计自然年/自然�?
    SELECT DISTINCT 
        app_id,
        store,
        affname,
        lcm_id,
        CASE 
            WHEN day BETWEEN 20240901 AND 20240930 THEN 2 -- 统计�?
            WHEN day BETWEEN 20231001 AND 20240930 THEN 1 -- 统计�?
            ELSE 0 
        END AS day_typ 
    FROM dm_platform.daily_lcx_user_info  
    WHERE day >= 20180101 
      AND app_id IN ('23000113', '65002004', '65002005', '65002007', '23002013', '33002013', '63002013')
) AS a 
LEFT OUTER JOIN (
    -- 充值流水统计子�?
    SELECT 
        app_id,
        store,
        lcm_id,
        SUM(CASE WHEN channel_type NOT IN ('LCX_WALLET') THEN price_show * exchange_rate END) AS zhijie_year_sales,
        SUM(CASE WHEN channel_type IN ('LCX_WALLET') THEN price_show * exchange_rate END) AS pc_year_sales,
        SUM(CASE WHEN day BETWEEN 20240901 AND 20240930 AND channel_type NOT IN ('LCX_WALLET') THEN price_show * exchange_rate ELSE 0 END) AS zhijie_month_sales,
        SUM(CASE WHEN day BETWEEN 20240901 AND 20240930 AND channel_type IN ('LCX_WALLET') THEN price_show * exchange_rate ELSE 0 END) AS pc_month_sales
    FROM (
        SELECT 
            app_id,
            SUBSTR(month, 1, 6) AS months, 
            store, 
            lcm_id, 
            price_show, 
            unit_show,
            day,
            channel_type
        FROM dm_platform.daily_lcx_user_purchase
        WHERE day BETWEEN 20231001 AND 20240930 
          AND price_show > 0
    ) a_inner
    LEFT JOIN (
        -- 核心汇率转换逻辑 (CNY)
        SELECT 
            SUBSTR(day_hour, 1, 6) AS months, 
            trans_from, 
            exchange_rate
        FROM (
            SELECT 
                day_hour, 
                TOLOWER(trans_from) AS trans_from, 
                exchange_rate,
                ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
            FROM dm_platform.itunes_exchange_rate_fmp 
            WHERE trans_to = 'cny'
              AND day >= 20230901
        ) tmp 
        WHERE rank1 = 1
    ) b_ex ON a_inner.months = b_ex.months AND LOWER(a_inner.unit_show) = b_ex.trans_from
    GROUP BY app_id, store, lcm_id
) AS b ON a.app_id = b.app_id AND a.lcm_id = b.lcm_id AND a.store = b.store
GROUP BY a.app_id, a.store, a.affname 
HAVING month_uu > 10;


-- 1.3 年度月度多维流水对比 (精简�?
SELECT 
    DISTINCT a.app_id,
    a.store,
    a.all_uu,
    a.year_uu,
    b.year_puu,
    b.zhijie_year_sales,
    b.pc_year_sales,
    a.month_uu,
    b.month_puu,
    b.zhijie_month_sales,
    b.pc_month_sales 
FROM (
    SELECT 
        app_id,
        store,
        COUNT(DISTINCT lcm_id) AS all_uu,
        COUNT(DISTINCT CASE WHEN day BETWEEN 20240901 AND 20240930 THEN lcm_id END) AS month_uu,
        COUNT(DISTINCT CASE WHEN day BETWEEN 20231001 AND 20240930 THEN lcm_id END) AS year_uu 
    FROM dm_platform.daily_lcx_user_info  
    WHERE day >= 20180101 
      AND app_id IN ('23000113', '65002004', '65002005', '65002007', '23002013', '33002013', '63002013')
    GROUP BY app_id, store
) AS a 
LEFT OUTER JOIN (
    SELECT 
        app_id,
        store,
        COUNT(DISTINCT a_inner.lcm_id) AS year_puu,
        COUNT(DISTINCT CASE WHEN day BETWEEN 20240901 AND 20240930 THEN a_inner.lcm_id END) AS month_puu,
        SUM(price_show * exchange_rate) AS zhijie_year_sales,
        SUM(CASE WHEN channel_type IN ('LCX_WALLET') THEN price_show * exchange_rate END) AS pc_year_sales,
        SUM(CASE WHEN day BETWEEN 20240901 AND 20240930 THEN price_show * exchange_rate ELSE 0 END) AS zhijie_month_sales,
        SUM(CASE WHEN day BETWEEN 20240901 AND 20240930 AND channel_type IN ('LCX_WALLET') THEN price_show * exchange_rate ELSE 0 END) AS pc_month_sales
    FROM (
        SELECT 
            app_id,
            SUBSTR(month, 1, 6) AS months, 
            store, 
            lcm_id, 
            price_show, 
            unit_show,
            day,
            channel_type
        FROM dm_platform.daily_lcx_user_purchase
        WHERE day BETWEEN 20231001 AND 20240930 
          AND price_show > 0
    ) a_inner
    LEFT JOIN (
        SELECT 
            SUBSTR(day_hour, 1, 6) AS months, 
            trans_from, 
            exchange_rate
        FROM (
            SELECT 
                day_hour, 
                TOLOWER(trans_from) AS trans_from, 
                exchange_rate,
                ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
            FROM dm_platform.itunes_exchange_rate_fmp 
            WHERE trans_to = 'cny'
              AND day >= 20230901
        ) tmp 
        WHERE rank1 = 1
    ) b_ex ON a_inner.months = b_ex.months AND LOWER(a_inner.unit_show) = LOWER(b_ex.trans_from)
    GROUP BY app_id, store
) AS b ON a.app_id = b.app_id AND a.store = b.store 
WHERE a.month_uu > 10;


-- =================================================================================
-- 2. Wings & 全球区组筛�?(Zone & Region Filtering)
-- =================================================================================

-- 备注：区�?ID 映射
-- 3001: 繁中 (GMT+8), 3002: 韩国 (GMT+9), 3003: 东南�?(GMT+7)
-- 4001: 欧洲 (GMT+0), 5001: 北美 (GMT-5), 6001: 南美 (GMT-3), 7001: 中东 (GMT+3)

-- 2.1 梦想联赛玩家剔除筛�?(Wings)
-- 逻辑：获取快照中的所有角色，剔除掉在指定日期内有战斗记录（具体事件）的玩�?
SELECT 
    a.zone_id,
    a.lcm_id,
    a.role_id
FROM (
    -- 基础用户快照�?
    SELECT 
        lcm_id,
        role_id,
        zone_id,
        MAX(create_day) AS cday,
        MAX(lastlogin_day) AS lday,
        MAX(total_pay) AS tpay,
        MAX(INT(normal_stage)) AS stage
    FROM g65002005.server_role_snapshot 
    WHERE day = 20241008 
      AND INT(create_day) >= 20231205
      AND zone_id IN (4001, 6001, 7001)
    GROUP BY lcm_id, role_id, zone_id
) AS a
LEFT JOIN (
    -- 活跃战斗日志�?
    SELECT 
        lcm_id,
        role_id,
        zone_id,
        COUNT(1) AS num
    FROM g65002005.daily_game_log
    WHERE day BETWEEN 20241002 AND 20241008
      AND zone_id IN (4001, 6001, 7001)
      AND event_name IN ('server_stage_fight')
    GROUP BY lcm_id, role_id, zone_id
) AS b ON a.lcm_id = b.lcm_id AND a.role_id = b.role_id 
WHERE b.role_id IS NULL
ORDER BY a.zone_id;



-- 2.2 账号分层筛�?(充值、登录时间、关卡综合筛�?
SELECT 
    DISTINCT a.lcm_id,
    a.lday AS "账号最后登�?,
    a.tpay AS "账号充�?,
    a.stage AS "账号最后关�?,
    b.role_id AS "匹配角色",
    b.zone_id AS "匹配区组"
FROM (
    SELECT 
        lcm_id,
        MAX(create_day) AS cday,
        MAX(lastlogin_day) AS lday,
        MAX(total_pay) AS tpay,
        MAX(client_ip) AS ip,
        MAX(INT(normal_stage)) AS stage
    FROM g65002005.server_role_snapshot 
    WHERE day = 20250119 
      AND INT(create_day) >= 20231205
    GROUP BY lcm_id
    HAVING tpay = 0 
       AND lday <= 20241231 
       AND stage <= 18
) AS a 
JOIN (
    SELECT 
        lcm_id,
        role_id,
        zone_id,
        MAX(create_day) AS cday,
        MAX(lastlogin_day) AS lday,
        MAX(total_pay) AS tpay,
        MAX(client_ip) AS ip,
        MAX(INT(normal_stage)) AS stage
    FROM g65002005.server_role_snapshot 
    WHERE day = 20250119 
      AND INT(create_day) >= 20231205
      AND zone_id IN (4001)
    GROUP BY lcm_id, role_id, zone_id
    HAVING tpay = 0 
       AND lday <= 20241231 
       AND stage <= 18
) AS b ON a.lcm_id = b.lcm_id;


-- 2.3 重复设备 ID (Android ID) 筛�?
-- 用于识别同一设备下的多账号聚集情�?
SELECT 
    DISTINCT a.android_id,
    b.lcm_id,
    b.zone_id 
FROM (
    SELECT 
        android_id,
        COUNT(DISTINCT lcm_id) AS uu 
    FROM g65002005.server_role_snapshot 
    WHERE day = 20241001 
      AND INT(create_day) >= 20231205
      AND zone_id IN (4001, 5001, 7001)
      AND android_id IS NOT NULL 
      AND android_id NOT IN ('unknown') 
    GROUP BY android_id 
    HAVING uu >= 100
) AS a 
LEFT OUTER JOIN (
    SELECT DISTINCT 
        android_id,
        lcm_id,
        zone_id 
    FROM g65002005.server_role_snapshot 
    WHERE day = 20241001 
      AND INT(create_day) >= 20231205
      AND zone_id IN (4001, 5001, 7001)
      AND android_id IS NOT NULL 
      AND android_id NOT IN ('unknown') 
) AS b ON a.android_id = b.android_id;


-- =================================================================================
-- 3. 全球�?KPI 统计 (GL Monthly KPI)
-- =================================================================================

-- 3.1 跨国�?地区子应用逻辑映射
-- 将不同国家的用户归类到相应的业务区域（Sub-Region ID�?
SELECT 
    CASE 
        WHEN app_id = '65002002' AND SUBSTR(country_name, 1, 2) IN ('台湾', '香港', '澳门') THEN '650020021'
        WHEN app_id = '65002002' AND country_name = '韩国' THEN '650020022' 
        WHEN app_id = '65002002' AND country_name IN ('泰国', '菲律�?, '新加�?, '马来西亚', '印度尼西�?) THEN '650020023' 
        WHEN app_id = '65002004' AND country_name = '韩国' THEN '650020041' 
        WHEN app_id = '65002005' AND country_name IN ('泰国', '菲律�?, '新加�?, '马来西亚', '印度尼西�?, '柬埔�?, '文莱', '印度', '巴基斯坦', '不丹', '老挝', '马尔代夫', '蒙古', '缅甸', '尼泊�?, '斯里兰卡', '哈萨克斯�?, '吉尔吉斯斯坦', '塔吉克斯�?, '土库曼斯�?, '乌兹别克斯坦') THEN '650020051'
        WHEN app_id = '65002005' AND SUBSTR(country_name, 1, 2) IN ('台湾', '香港', '澳门') THEN '650020051'
        WHEN app_id = '65002005' AND country_name = '韩国' THEN '650020052' 
        WHEN app_id = '65002005' AND country_name IN ('沙特阿拉�?, '阿拉伯联合酋长国', '科威�?, '卡塔�?, '土耳其', '埃及', '阿富�?, '伊朗', '阿曼', '阿塞拜疆', '以色�?, '伊拉�?, '阿尔及利�?, '摩洛�?, '突尼�?, '利比�?, '黎巴�?, '毛里塔尼�?, '约旦', '巴林', '索马�?, '吉布�?, '苏丹', '科摩�?, '巴勒斯坦') THEN '650020053'
        ELSE app_id 
    END AS sub_region,
    COUNT(DISTINCT lcm_id) AS uu,
    COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END) AS puu,
    SUM(purchase) AS sales 
FROM dm_platform.monthly_lcx_user_info 
WHERE month BETWEEN 202404 AND 202409
  AND is_water = '不是�?
GROUP BY 1;


-- 3.2 跨国�?地区子应用逻辑映射 (单月精简�?
SELECT 
    CASE 
        WHEN app_id = '65002002' AND SUBSTR(country_name, 1, 2) IN ('台湾', '香港', '澳门') THEN '650020021'
        WHEN app_id = '65002002' AND country_name = '韩国' THEN '650020022' 
        WHEN app_id = '65002002' AND country_name IN ('泰国', '菲律�?, '新加�?, '马来西亚', '印度尼西�?) THEN '650020023' 
        WHEN app_id = '65002004' AND country_name = '韩国' THEN '650020041' 
        WHEN app_id = '65002005' AND country_name IN ('泰国', '菲律�?, '新加�?, '马来西亚', '印度尼西�?, '柬埔�?, '文莱', '印度', '巴基斯坦', '不丹', '老挝', '马尔代夫', '蒙古', '缅甸', '尼泊�?, '斯里兰卡', '哈萨克斯�?, '吉尔吉斯斯坦', '塔吉克斯�?, '土库曼斯�?, '乌兹别克斯坦') THEN '650020051'
        WHEN app_id = '65002005' AND SUBSTR(country_name, 1, 2) IN ('台湾', '香港', '澳门') THEN '650020051'
        WHEN app_id = '65002005' AND country_name = '韩国' THEN '650020052' 
        WHEN app_id = '65002005' AND country_name IN ('沙特阿拉�?, '阿拉伯联合酋长国', '科威�?, '卡塔�?, '土耳其', '埃及', '阿富�?, '伊朗', '阿曼', '阿塞拜疆', '以色�?, '伊拉�?, '阿尔及利�?, '摩洛�?, '突尼�?, '利比�?, '黎巴�?, '�?塔尼�?, '约旦', '巴林', '索马�?, '吉布�?, '苏丹', '科摩�?, '巴勒斯坦') THEN '650020053'
        ELSE app_id 
    END AS sub_region,
    COUNT(DISTINCT lcm_id) AS uu,
    COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END) AS puu,
    SUM(purchase) AS sales 
FROM dm_platform.monthly_lcx_user_info 
WHERE month = 202409 
  AND is_water = '不是�?
GROUP BY 1;


-- =================================================================================
-- 4. 虚拟货币存量与点券计�?(Currency Stocks & Gift Analysis)
-- =================================================================================

-- 4.1 全球各地区负点券账户实时监控 (Stamps Negative Balance)
-- 目的：监控点�?付费+普�?存量为负数的异常账号（如退款导致）
SELECT 
    region AS "|地区",
    lcm_id AS "lcm_id",
    role_id AS "role_id",
    level AS "角色等级",
    zone_id AS "区服ID",
    stamp AS "点券存量",
    day AS "最后登�?,
    region AS name
FROM (
    -- 繁中地区 (TW)
    SELECT 
        'TW' AS region, 
        lcm_id, 
        role_id, 
        level, 
        zone_id, 
        free_stamps + stamps AS stamp, 
        day,
        ROW_NUMBER() OVER(PARTITION BY lcm_id, role_id ORDER BY day DESC) AS rank
    FROM g23002013.dm_server_user_info
    WHERE day BETWEEN 20241001 AND 20241017
    
    UNION ALL 
    
    -- 韩国地区 (KR)
    SELECT 
        'KR' AS region, 
        lcm_id, 
        role_id, 
        level, 
        zone_id, 
        free_stamps + stamps AS stamp, 
        day,
        ROW_NUMBER() OVER(PARTITION BY lcm_id, role_id ORDER BY day DESC) AS rank
    FROM g33002013.dm_server_user_info
    WHERE day BETWEEN 20241001 AND 20241017
    
    UNION ALL 
    
    -- 全球其他地区 (GL)
    SELECT 
        'GL' AS region, 
        lcm_id, 
        role_id, 
        level, 
        zone_id, 
        free_stamps + stamps AS stamp, 
        day,
        ROW_NUMBER() OVER(PARTITION BY lcm_id, role_id ORDER BY day DESC) AS rank
    FROM g63002013.dm_server_user_info
    WHERE day BETWEEN 20241001 AND 20241017
) AS a 
WHERE rank = 1 
  AND stamp < 0
ORDER BY region;



-- =================================================================================
-- 5. 战令/通行证购买统�?(Battle Pass & BP Purchasing)
-- =================================================================================

-- 5.1 通行�?战令解锁与购买人数统�?(解析 server_resource_change 事件)
-- 区分逻辑：second_reason=1 为基础版，second_reason=2 为进阶版（按金额过滤�?
SELECT 
    a.day,
    COUNT(CASE WHEN second_reason = '1' THEN role_id ELSE NULL END) AS bp_buy_1,
    COUNT(CASE WHEN second_reason = '2' AND amount = -880 THEN role_id ELSE NULL END) AS bp_buy_2,
    COUNT(CASE WHEN second_reason = '2' AND amount = -600 THEN role_id ELSE NULL END) AS bp_buy_3
FROM (
    -- 提取战令解锁行为的原始日�?
    SELECT 
        lcm_id,
        role_id,
        second_reason,
        day,
        CAST(event_time / 1000 AS BIGINT) AS time,
        SUM(CAST(diff AS INT)) AS amount
    FROM (
        SELECT 
            lcm_id,
            role_id,
            zone_id,
            GET_JSON_OBJECT(a_tar, '$.reason') AS reason,
            GET_JSON_OBJECT(a_tar, '$.diff') AS diff,
            GET_JSON_OBJECT(a_tar, '$.second_reason') AS second_reason,
            day,
            event_time
        FROM g65002007.daily_game_log
        WHERE day BETWEEN 20240328 AND 20240426 
          AND event_name = 'server_resource_change'
          AND GET_JSON_OBJECT(a_tar, '$.reason') = '解锁进阶战令'
    ) tmp
    GROUP BY lcm_id, role_id, second_reason, day, CAST(event_time / 1000 AS BIGINT)
) AS a
JOIN (
    -- 排除水号后的合法用户过滤�?
    SELECT lcm_id, day
    FROM dm_platform.daily_lcx_user_info
    WHERE day BETWEEN 20240328 AND 20240426 
      AND app_id = 65002007
      AND is_water = '不是�?
      AND is_black = '不是�?
    GROUP BY lcm_id, day
) AS b ON a.lcm_id = b.lcm_id AND a.day = b.day
GROUP BY a.day;


-- 5.2 账户充值与活跃状态深度检�?(活动 ID 过滤)
-- 用于追踪特定活动 ID 下的金币/道具产出
SELECT 
    a.*, 
    obj2, 
    diff2 
FROM (
    -- 筛选特定金额产出的金币事件
    SELECT 
        FROM_UNIXTIME(log_t) AS dtime, 
        user_id, 
        a_tar, 
        a_typ, 
        a_rst, 
        obj, 
        diff 
    FROM g23002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20241015 AND 20241023 
      AND obj = 'dmp:money' 
      AND diff = 666
) AS a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2
WHERE diff2 = 1;


-- =================================================================================
-- 6. 游戏数据库看�?(Game Library & Standard Metrics)
-- =================================================================================

-- 6.1 核心 KPI 汇总看�?(OBT 阶段)
-- 指标包含：DARPU, DARPPU, Retention (D1-D90), LTV (D1-D90)
SELECT 
    app_id,
    app_name,
    app_ab,
    period,
    SUM(nuu) AS total_nuu,
    ROUND(SUM(sales) / SUM(dau), 2) AS darpu,
    ROUND(SUM(sales) / SUM(dpuu), 2) AS darppu,
    ROUND(SUM(dpuu) / SUM(dau), 2) AS dpr,
    ROUND(SUM(r1) / SUM(nuu1), 4) AS rr1,
    ROUND(SUM(r3) / SUM(nuu3), 4) AS rr3,
    ROUND(SUM(r7) / SUM(nuu7), 4) AS rr7,
    ROUND(SUM(r30) / SUM(nuu30), 4) AS rr30,
    ROUND(SUM(lt1) / SUM(nuu), 2) AS ltv1,
    ROUND(SUM(lt7) / SUM(nuu6), 2) AS ltv7,
    ROUND(SUM(lt30) / SUM(nuu29), 2) AS ltv30
FROM dm_platform.game_library 
WHERE partition_value IS NOT NULL 
  AND nuu > 0 
  AND app_name LIKE '%�?' 
  AND period = 'OBT' 
  AND node IN ('M1', 'M2', 'M3')
  AND country_code = 'HK'
GROUP BY app_id, app_name, app_ab, period;


-- 6.2 每日细分维度看板 (分日期、子节点、国�?
SELECT 
    app_id,
    app_name,
    app_ab,
    period,
    days,
    start_date,
    SUM(nuu) AS daily_nuu,
    ROUND(SUM(r1) / NULLIF(SUM(nuu1), 0), 4) AS rr1,
    ROUND(SUM(r2) / NULLIF(SUM(nuu2), 0), 4) AS rr2,
    ROUND(SUM(r3) / NULLIF(SUM(nuu3), 0), 4) AS rr3,
    ROUND(SUM(r7) / NULLIF(SUM(nuu7), 0), 4) AS rr7,
    ROUND(SUM(r30) / NULLIF(SUM(nuu30), 0), 4) AS rr30,
    ROUND(SUM(lt1) / NULLIF(SUM(nuu), 0), 2) AS ltv1,
    ROUND(SUM(lt7) / NULLIF(SUM(nuu6), 0), 2) AS ltv7,
    ROUND(SUM(lt30) / NULLIF(SUM(nuu29), 0), 2) AS ltv30
FROM dm_platform.game_library 
WHERE partition_value IS NOT NULL 
  AND nuu > 0 
  AND period = 'CBT' 
  AND app_name LIKE '%�?' 
  AND country_code = 'HK'
GROUP BY app_id, app_name, app_ab, period, days, start_date;


-- =================================================================================
-- 7. 用户留存�?LTV 滚算 (Retention & LTV Calculation)
-- =================================================================================

-- 7.1 通用手动 KPI 计算 (按月汇总，包含 RR1-RR90, LTV1-LTV90)
-- 逻辑：通过 DATEDIFF 计算留存天数(df)，并根据注册天数(rf)决定分母是否包含该用�?
SELECT 
    SUBSTR(day, 1, 6) AS month,
    SUM(nuu) AS total_nuu,
    COUNT(DISTINCT CASE WHEN SUBSTR(a.day, 1, 6) = SUBSTR(a.day2, 1, 6) AND puu_a > 0 THEN lcm_id END) AS nuu_pu,
    SUM(CASE WHEN SUBSTR(a.day, 1, 6) = SUBSTR(a.day2, 1, 6) THEN sales ELSE 0 END) AS nuu_sales,
    -- 核心：RR 统计需确保用户注册天数大于统计目标天数
    ROUND(SUM(CASE WHEN rf > 1 AND df = 1 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 1 THEN nuu ELSE 0 END), 0), 4) AS rr1,
    ROUND(SUM(CASE WHEN rf > 3 AND df = 3 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 3 THEN nuu ELSE 0 END), 0), 4) AS rr3,
    ROUND(SUM(CASE WHEN rf > 7 AND df = 7 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 7 THEN nuu ELSE 0 END), 0), 4) AS rr7,
    ROUND(SUM(CASE WHEN rf > 30 AND df = 30 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 30 THEN nuu ELSE 0 END), 0), 4) AS rr30,
    -- LTV 统计累计至目标天数前的所有流�?
    ROUND(SUM(CASE WHEN rf >= 1 AND df < 1 THEN sales ELSE 0 END) / NULLIF(SUM(CASE WHEN rf >= 1 THEN nuu ELSE 0 END), 0), 2) AS ltv1,
    ROUND(SUM(CASE WHEN rf >= 7 AND df < 7 THEN sales ELSE 0 END) / NULLIF(SUM(CASE WHEN rf >= 7 THEN nuu ELSE 0 END), 0), 2) AS ltv7,
    ROUND(SUM(CASE WHEN rf >= 30 AND df < 30 THEN sales ELSE 0 END) / NULLIF(SUM(CASE WHEN rf >= 30 THEN nuu ELSE 0 END), 0), 2) AS ltv30
FROM (
    SELECT 
        app_id, 
        lcm_id, 
        os, 
        reg_day AS day, 
        day AS day2,
        CASE WHEN source NOT IN ('market', 'effect') AND SUBSTR(affcode, 1, 6) = 'a10133' THEN 'channel' ELSE source END AS source,
        affcode, 
        channel, 
        campaign, 
        ad_code1, 
        ad_code2, 
        ad_type, 
        1 AS ru,
        CAST(purchase AS DOUBLE) AS sales,
        CASE WHEN user_type = 'nuu' THEN 1 ELSE 0 END AS nuu,
        CASE WHEN total_purchase > 0 THEN 1 ELSE 0 END AS puu_a,    
        DATEDIFF(SUBSTR(CURRENT_TIMESTAMP, 1, 10), SUBSTR(TO_DATE(reg_day, 'yyyyMMdd'), 1, 10)) AS rf,
        DATEDIFF(SUBSTR(TO_DATE(day, 'yyyyMMdd'), 1, 10), SUBSTR(TO_DATE(reg_day, 'yyyyMMdd'), 1, 10)) AS df
    FROM dm_platform.daily_lcm_user_info 
    WHERE app_id = 33002002
      AND day >= '20190403'
      AND is_water = '不是�?
) AS a 
GROUP BY SUBSTR(day, 1, 6);


-- 7.2 连续每日留存详情 (RR1-RR30)
-- 汇总某一特定注册批次及其后续 30 天的留存率变�?
SELECT 
    SUM(nuu) AS total_nuu,
    ROUND(SUM(CASE WHEN rf > 1 AND df = 1 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 1 THEN nuu ELSE 0 END), 0), 4) AS rr1,
    ROUND(SUM(CASE WHEN rf > 3 AND df = 3 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 3 THEN nuu ELSE 0 END), 0), 4) AS rr3,
    ROUND(SUM(CASE WHEN rf > 7 AND df = 7 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 7 THEN nuu ELSE 0 END), 0), 4) AS rr7,
    ROUND(SUM(CASE WHEN rf > 14 AND df = 14 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 14 THEN nuu ELSE 0 END), 0), 4) AS rr14,
    ROUND(SUM(CASE WHEN rf > 30 AND df = 30 THEN ru ELSE 0 END) / NULLIF(SUM(CASE WHEN rf > 30 THEN nuu ELSE 0 END), 0), 4) AS rr30
FROM (
    SELECT 
        app_id, 
        lcm_id, 
        os, 
        reg_day AS day, 
        day AS day2,
        1 AS ru,
        CASE WHEN user_type = 'nuu' THEN 1 ELSE 0 END AS nuu,
        DATEDIFF('2023-11-20', SUBSTR(TO_DATE(reg_day, 'yyyyMMdd'), 1, 10)) AS rf,
        DATEDIFF(SUBSTR(TO_DATE(day, 'yyyyMMdd'), 1, 10), SUBSTR(TO_DATE(reg_day, 'yyyyMMdd'), 1, 10)) AS df
    FROM dm_platform.daily_lcx_user_info 
    WHERE app_id = 65002007
      AND day >= '20230926' 
      AND reg_day >= '20231120'
      AND is_water = '不是�?
) AS a;



-- 5.3 新手通行�?战令购买追踪 (全球�?
-- 逻辑：匹配注册行�?Dmp101001)与充值行�?charge)，并关联战令奖励领取等级
SELECT 
    a.user_id,
    a.create_day,
    c.day AS buy_day,
    b.level - 9000 AS bp_level
FROM (
    -- 用户注册事件
    SELECT 
        CONCAT(SUBSTR(day, 1, 4), '-', SUBSTR(day, 5, 2), '-', SUBSTR(day, 7, 2)) AS create_day,
        mbga_uid,
        user_id,
        day
    FROM g33002013.daily_game_log
    WHERE day BETWEEN 20241215 AND 20250114 
      AND a_typ = 'Dmp101001'
) AS a 
JOIN (
    -- 战令充�?Index 20000402)事件
    SELECT 
        mbga_uid,
        user_id,
        day,
        log_t,
        param1 
    FROM g33002013.daily_game_log
    WHERE day >= 20241215
      AND a_typ = 'charge'
      AND GET_JSON_OBJECT(a_tar, '$.index') = '20000402'
) AS c ON a.user_id = c.user_id
LEFT JOIN (
    -- 战令奖励领取等级 (解析 JSON 列表并提取最大等�?
    SELECT 
        mbga_uid,
        user_id,
        MAX(CAST(REGEXP_REPLACE(lv, '\\[|\\]', '') AS INT)) AS level
    FROM g33002013.daily_game_log

    LATERAL VIEW EXPLODE(SPLIT(GET_JSON_OBJECT(a_tar, '$.index'), ',')) lv_tab AS lv
    WHERE day >= 20241215
      AND a_typ = 'battlepass_reward'
      AND CAST(REGEXP_REPLACE(lv, '\\[|\\]', '') AS INT) BETWEEN 9001 AND 9100 -- KR
    GROUP BY mbga_uid, user_id
) AS b ON a.mbga_uid = b.mbga_uid AND a.user_id = b.user_id;


-- =================================================================================
-- 8. 卡牌配置、收入与角色转化 (Card Config, Revenue & Conversion)
-- =================================================================================

-- 8.1 维表配置参�?(仅作历史记录，建议使用正式维�?
/*
-- 店铺维表插入
INSERT INTO g63002013.dim_shop VALUES (10000069, '传奇商店');

-- 传奇卡牌维表插入 (dim_card & dim_card_h5)
INSERT INTO g63002013.dim_card VALUES 
(99030603, '传奇神宗一�?), (99040901, '伊藤�?), (99030403, '传奇牧绅一'),
(99020403, '传奇鱼住�?),   (99040403, '传奇藤真健司'), (99020502, '传奇池上亮二'),
(99020703, '传奇仙道�?),   (99020602, '传奇越野宏明'), (99021303, '传奇福田吉兆');
*/


-- 8.2 传奇角色整体销售收入统�?(�?SKU 分组)
SELECT 
    a.app_id,
    a.sku,
    a.sku_name,
    COUNT(DISTINCT a.lcm_id) AS uu,
    SUM(a.price_show * b.exchange_rate) AS sales 
FROM (
    SELECT 
        day,
        app_id,
        lcm_id,
        sku,
        sku_name,
        unit_show,
        price_show 
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20251113 AND 20251120 
      AND app_id IN ('23002013', '33002013', '63002013') 
      AND sku LIKE 'tier10.package0069'
) AS a 
LEFT JOIN (
    -- 关联 CNY 汇率
    SELECT 
        SUBSTR(day_hour, 1, 6) AS months, 
        trans_from, 
        exchange_rate
    FROM (
        SELECT 
            day_hour, 
            TOLOWER(trans_from) AS trans_from, 
            exchange_rate,
            ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny' 
          AND day >= 20251101
    ) tmp 
    WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from 
GROUP BY a.app_id, a.sku, a.sku_name;


-- 8.3 传奇牧绅一 (Maki) 专题统计
SELECT 
    a.app_id,
    a.sku_type,
    COUNT(DISTINCT a.lcm_id) AS uu,
    SUM(a.price_show * b.exchange_rate) AS sales 
FROM (
    SELECT 
        app_id,
        lcm_id,
        unit_show,
        price_show,
        CASE 
            WHEN sku IN ('com.denachina.g33002013.samsung.tier27.package133', 'com.denachina.g33002013.onestore.tier27.package133', 'com.denachina.g33002013.google.tier27.package133', 'com.denachina.g33002013.apple.tier27.package133') THEN '傳奇牧加速箱' 
            WHEN sku IN ('com.denachina.g63002013.apple.tier60.maki03', 'com.denachina.g63002013.google.nt3290.maki03', 'com.denachina.g63002013.apk.nt3290.maki03', 'com.denachina.g33002013.samsung.tier58.maki03', 'com.denachina.g33002013.onestore.tier58.maki03', 'com.denachina.g33002013.google.tier58.maki03', 'com.denachina.g33002013.apple.Tier58.maki03') THEN '傳奇阿牧資料豪礼'
            WHEN sku IN ('com.denachina.g33002013.samsung_tier55.package0001', 'com.denachina.g33002013.onestore_tier55.package0001', 'com.denachina.g33002013.google_tier55.package0001', 'com.denachina.g33002013.apple_tier55.package0001') THEN '首席天賦起跑�?
            WHEN sku IN ('com.denachina.g33002013.samsung_tier53.package0002', 'com.denachina.g33002013.onestore_tier53.package0002', 'com.denachina.g33002013.google_tier53.package0002', 'com.denachina.g33002013.apple_tier53.package0002') THEN '首席特訓轉盤�? 
            ELSE 'other' 
        END AS sku_type
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20241219 AND 20250108 
      AND app_id IN ('33002013', '63002013')
) AS a 
LEFT JOIN (
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, TOLOWER(trans_from) AS trans_from, exchange_rate,
               ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny' AND day >= 20231201
    ) tmp WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from 
GROUP BY a.app_id, a.sku_type;


-- 8.4 传奇鱼住�?(Uozumi) 专题统计
SELECT 
    a.app_id,
    a.sku_type,
    COUNT(DISTINCT a.lcm_id) AS uu,
    SUM(a.price_show * b.exchange_rate) AS sales 
FROM (
    SELECT 
        app_id,
        lcm_id,
        unit_show,
        price_show,
        CASE 
            WHEN sku LIKE '%package0003' THEN '傳奇鱼柱资料豪礼'  
            WHEN sku LIKE '%package0004' THEN '傳奇鱼柱加速箱'
            WHEN sku LIKE '%package0005' THEN '傳奇鱼柱奇遇�? 
            WHEN sku LIKE '%package0008' THEN '陵南支柱起跑�?
            WHEN sku LIKE '%package0009' THEN '傳奇支柱转盘�? 
            ELSE 'other' 
        END AS sku_type
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20250116 AND 20250205 
      AND app_id IN ('23002013', '33002013', '63002013')
) AS a 
LEFT JOIN (
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, TOLOWER(trans_from) AS trans_from, exchange_rate,
               ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny' AND day >= 20250101
    ) tmp WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from 
GROUP BY a.app_id, a.sku_type;


-- 8.5 传奇藤真健司 (Fujima) 专题统计
SELECT 
    a.app_id,
    a.sku_type,
    COUNT(DISTINCT a.lcm_id) AS uu,
    SUM(a.price_show * b.exchange_rate) AS sales 
FROM (
    SELECT 
        app_id,
        lcm_id,
        unit_show,
        price_show,
        CASE 
            WHEN sku LIKE '%package0020' THEN '傳奇藤真加速箱'  
            WHEN sku LIKE '%package0021' THEN '傳奇藤真奇遇�?
            WHEN sku LIKE '%package0023' THEN '傳奇藤真起跑�? 
            WHEN sku LIKE '%package0019' THEN '翔陽傳奇福利爆击'
            WHEN sku LIKE '%package0024' THEN '傳奇藤真资料豪礼' 
            ELSE 'other' 
        END AS sku_type
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20250320 AND 20250409 
      AND app_id IN ('23002013', '33002013', '63002013')
) AS a 
LEFT JOIN (
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, TOLOWER(trans_from) AS trans_from, exchange_rate,
               ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny' AND day >= 20250301
    ) tmp WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from 
GROUP BY a.app_id, a.sku_type;


-- 8.6 传奇仙道�?(Sendoh) 专题统计
SELECT 
    a.app_id,
    a.sku_type,
    COUNT(DISTINCT a.lcm_id) AS uu,
    SUM(a.price_show * b.exchange_rate) AS sales 
FROM (
    SELECT 
        app_id,
        lcm_id,
        unit_show,
        price_show,
        CASE 
            WHEN sku LIKE '%package0034' THEN '傳奇仙道加速箱'  
            WHEN sku LIKE '%package0035' THEN '傳奇仙道奇遇�?
            WHEN sku LIKE '%package0036' THEN '傳奇仙道起跑�? 
            WHEN sku LIKE '%package0037' THEN '傳奇仙道资料豪礼' 
            ELSE 'other' 
        END AS sku_type
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20250605 AND 20250625 
      AND app_id IN ('23002013', '33002013', '63002013')
) AS a 
LEFT JOIN (
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, TOLOWER(trans_from) AS trans_from, exchange_rate,
               ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny' AND day >= 20250601
    ) tmp WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from 
GROUP BY a.app_id, a.sku_type;


-- 8.7 传奇福田吉兆 (Fukuda) 专题统计
SELECT 
    a.app_id,
    a.sku_type,
    COUNT(DISTINCT a.lcm_id) AS uu,
    SUM(a.price_show * b.exchange_rate) AS sales 
FROM (
    SELECT 
        app_id,
        lcm_id,
        unit_show,
        price_show,
        CASE 
            WHEN sku LIKE '%package0060' THEN '傳奇福田加速箱'  
            WHEN sku LIKE '%package0061' THEN '傳奇福田奇遇�?
            WHEN sku LIKE '%package0062' THEN '傳奇福田起跑�? 
            WHEN sku LIKE '%package0064' THEN '得分高手转盘�?
            WHEN sku LIKE '%package0063' THEN '傳奇福田资料豪礼' 
            ELSE 'other' 
        END AS sku_type
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20250925 AND 20251015 
      AND app_id IN ('23002013', '33002013', '63002013')
) AS a 
LEFT JOIN (
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, exchange_rate
    FROM (
        SELECT day_hour, TOLOWER(trans_from) AS trans_from, exchange_rate,
               ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny' AND day >= 20251001
    ) tmp WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from 
GROUP BY a.app_id, a.sku_type;



-- 8.8 传奇转盘消耗道具统�?(专属转盘�?& 扭蛋�?
-- 适用角色 ID 及道�?ID 参考：
-- 牧绅一: 140035900 (扭蛋�?, 140035901 (转盘�?
-- 鱼住: 140035980 (试炼�?, 140035969 (转盘�?
-- 藤真: 140036011 (扭蛋�?, 140036012 (转盘�?
-- 仙道: 140036084 (扭蛋�?, 140036086 (转盘�?
-- 福田: 141024775 (扭蛋�?, 141024776 (转盘�?

-- 8.8.1 商城购买情况汇�?
SELECT 
    shop_id,
    shop_name,
    item_id,
    item_name,
    COUNT(DISTINCT CONCAT(lcm_id, role_id)) AS "总购买人�?,
    SUM(CAST(amount AS BIGINT)) AS "总消耗点�?
FROM g23002013.server_shop_detail
WHERE day BETWEEN 20250925 AND 20251015
  AND coin_typ = 'stamps' 
  AND lcm_id NOT IN (SELECT DISTINCT lcm_id FROM dm_platform.dim_user_blacklist WHERE app_id IN ('23002013', '33002013', '63002013'))
  AND item_id IN ('81102065', '81102066', '81102067', '81100362', '81100364', '81100365') -- 示例：福田道�?
GROUP BY shop_id, shop_name, item_id, item_name
ORDER BY SUM(CAST(amount AS BIGINT)) DESC;

-- 8.8.2 转盘产出/消耗深度日志解�?
SELECT 
    -SUM(diff2) AS total_stamp_spend 
FROM (
    -- 步骤1：定位产出特定币种的日志
    SELECT log_t, user_id, mbga_uid, a_rst 
    FROM g63002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20250925 AND 20251015
      AND mbga_uid NOT IN (SELECT DISTINCT lcm_id FROM dm_platform.dim_user_blacklist WHERE app_id IN ('23002013', '33002013', '63002013'))
      AND obj LIKE '%141024776%' AND diff > 0
) AS a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2 
WHERE obj2 IN ('dmp:stamp', 'dmp:freestamps') AND diff2 < 0;
 


-- =================================================================================
-- 9. 钱包、充值与第三方支付监�?(Wallet & Payment Analysis)
-- =================================================================================

-- 9.1 全球点券转换消耗监�?(针对 4 种特定点券类�?
SELECT 
    -SUM(diff2) AS total_conversion_spend 
FROM (
    -- 步骤1：解析日志定位点券产�?
    SELECT log_t, user_id, mbga_uid, a_rst 
    FROM g63002013.daily_game_log 
    LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE day BETWEEN 20250116 AND 20250205 
      AND mbga_uid NOT IN (SELECT DISTINCT lcm_id FROM dm_platform.dim_user_blacklist WHERE app_id IN ('23002013', '33002013', '63002013'))
      AND (obj LIKE '%140035949%' OR obj LIKE '%140035950%' OR obj LIKE '%140035951%' OR obj LIKE '%140035952%')
      AND diff > 0
) AS a 
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj2, diff2 
WHERE obj2 IN ('dmp:stamp', 'dmp:freestamps') AND diff2 < 0;


-- 9.2 基础充值明细与汇率换算汇�?(多游�?多渠�?
-- 逻辑：通过 event_time 换算为日期，并左联月度平均汇�?
SELECT 
    a.app_id,
    FROM_UNIXTIME(CAST(a.event_time / 1000 AS INT)) AS formatted_event_time,
    a.lcm_id,
    a.order_id,
    a.sku,
    a.sku_name,
    a.unit_show,
    a.price_show,
    b.exchange_rate,
    a.device_id,
    a.os,
    a.store,
    a.country_code
FROM (
    -- 核心充值库
    SELECT * 
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20241201 AND 20241231 
      AND app_id IN (23002013, 33002013, 63002013, 23000113, 65002004, 65002005, 65002007)
) AS a 
LEFT JOIN (
    -- 获取对应月份汇率 (�?rank1=1 的记录作为月基准)
    SELECT 
        SUBSTR(day_hour, 1, 6) AS months, 
        trans_from, 
        exchange_rate
    FROM (
        SELECT 
            day_hour, 
            TOLOWER(trans_from) AS trans_from, 
            exchange_rate,
            ROW_NUMBER() OVER(PARTITION BY trans_to, trans_from, SUBSTR(day, 1, 6) ORDER BY day_hour) AS rank1
        FROM dm_platform.itunes_exchange_rate_fmp 
        WHERE trans_to = 'cny'
    ) tmp 
    WHERE rank1 = 1
) AS b ON LOWER(a.unit_show) = b.trans_from AND SUBSTR(FROM_UNIXTIME(CAST(a.event_time / 1000 AS INT)), 1, 6) = b.months
WHERE a.price_show > 0;


-- 9.3 平台钱包 (LCX_WALLET) 充值与区组快照关联
-- 逻辑：从 memo1 解析 zoneId，并关联对应日的角色快照
SELECT 
    a.day,
    a.order_id,
    a.app_id,
    a.lcm_id,
    a.store,
    a.sku_name,
    a.price_show,
    a.pay_amount,
    c.exchange_rate,
    a.channel_type,
    d.user_id,
    d.zone
FROM (
    SELECT 
        SUBSTR(day, 1, 6) AS months,
        day,
        order_id,
        price_show,
        lcm_id,
        unit_show,
        pay_amount,
        sku_name,
        app_id,
        store,
        channel_type,
        sku,
        GET_JSON_OBJECT(memo1, '$.zoneId') AS zone_id 
    FROM dm_platform.daily_lcx_user_purchase
    WHERE day BETWEEN 20250301 AND 20250331 
      AND channel_type = 'LCX_WALLET' 
      AND app_id = 63002013
) AS a  
LEFT JOIN ( 
    -- 充值专用汇率查�?(按月�?Max)
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, MAX(exchange_rate) AS exchange_rate
    FROM dm_platform.itunes_exchange_rate_fmp 
    WHERE trans_to = 'cny' AND day >= 20250301
    GROUP BY SUBSTR(day_hour, 1, 6), trans_from
) AS c ON a.months = c.months AND UPPER(a.unit_show) = c.trans_from
LEFT JOIN (
    -- 关联角色注册/快照信息
    SELECT zone, mbga_uid, user_id 
    FROM g63002013.daily_user_snapshot
    WHERE day = 20250326
) AS d ON a.lcm_id = d.mbga_uid AND a.zone_id = d.zone;


-- 9.4 钱包后台流水审计 (CHARGE/DIRECT_CHARGE)
SELECT 
    a.months,
    a.day,
    a.channel_no,
    a.product_id,
    a.lcm_id,
    a.game_id,
    a.store,
    a.channel_type,
    a.paid_amount,
    a.currency_code,
    c.exchange_rate,
    a.transaction_type
FROM (
    SELECT 
        SUBSTR(day, 1, 6) AS months,
        day,
        channel_no,
        product_id,
        paid_amount,
        lcx_user_id AS lcm_id,
        game_id,
        store,
        channel_type,
        currency_code,
        transaction_type
    FROM dm_platform.transaction_wallet 
    WHERE day BETWEEN 20250901 AND 20250930 
      AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE')
) AS a  
LEFT JOIN (
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, MAX(exchange_rate) AS exchange_rate
    FROM dm_platform.itunes_exchange_rate_fmp 
    WHERE trans_to = 'cny' 
 and day >= 20250101
 group by substr(day_hour,1,6),trans_from
)  c 
on a.months = c.months and upper(a.currency_code) = c.trans_from;


-- =================================================================================
-- 10. 游戏比赛数据汇�?(Battle & Matchmaking Metrics)
-- =================================================================================

-- 10.1 每日场次与匹配时长分�?(按战斗类�? 1-匹配, 2-排位, 10-龙珠; AI 类型: 0-真人, 1-温暖, 3-补偿)
SELECT 
    day,
    COUNT(event_time) AS total_battles,
    -- 匹配局场次统计
    COUNT(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '1' THEN 1 END) AS matchmaking_total,
    COUNT(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '1' AND GET_JSON_OBJECT(a_tar, '$.ai_type') = '0' THEN 1 END) AS matchmaking_pve_human,
    COUNT(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '1' AND GET_JSON_OBJECT(a_tar, '$.ai_type') = '1' THEN 1 END) AS matchmaking_pve_bot_warmth,
    COUNT(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '1' AND GET_JSON_OBJECT(a_tar, '$.ai_type') = '3' THEN 1 END) AS matchmaking_pve_bot_comp,
    -- 排位局场次统计
    COUNT(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '2' THEN 1 END) AS ranked_total,
    COUNT(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '2' AND GET_JSON_OBJECT(a_tar, '$.ai_type') = '0' THEN 1 END) AS ranked_human,
    -- 时长统计 (平均�?
    ROUND(AVG(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '1' THEN CAST(GET_JSON_OBJECT(a_tar, '$.time') AS INT) END), 2) AS matchmaking_avg_wait_time,
    ROUND(AVG(CASE WHEN GET_JSON_OBJECT(a_tar, '$.battle_type') = '2' THEN CAST(GET_JSON_OBJECT(a_tar, '$.time') AS INT) END), 2) AS ranked_avg_wait_time
FROM g65002007.daily_game_log 
WHERE day BETWEEN 20240527 AND 20240831 
  AND event_name = 'server_arena_get' 
GROUP BY day;


-- =================================================================================
-- 11. 月卡与周卡充值监�?(Monthly & Weekly Card Analysis)
-- =================================================================================

-- 11.1 月卡充值日志明�?
-- ID 参考：14100019 (繁体月卡), 14100010/14100012 (韩国月卡/加强�?, 1303001/1303002 (全球�?周卡)
SELECT 
    GET_JSON_OBJECT(a_tar, '$.index') AS card_index,
    mbga_uid,
    user_id,
    zone,
    day,
    DATEDIFF(CURRENT_TIMESTAMP, TO_DATE(day, 'yyyyMMdd')) AS days_since_purchase
FROM g63002013.daily_game_log 
WHERE day >= 20250101 
  AND a_typ = 'charge' 
  AND a_tar LIKE '%1303002%'; -- 示例：监测全球周�?


-- 11.2 特定月卡 SKU 销售流水统�?
SELECT 
    day,
    sku,
    sku_name,
    lcm_id,
    price_show 
FROM dm_platform.daily_lcx_user_purchase 
WHERE day >= 20250101 
  AND sku LIKE 'com.denachina.g63002013.apple.tier1.gift54' 
  AND app_id IN ('33002013', '63002013');



-- =================================================================================
-- 12. 卡牌邮件养成与技能追�?(Card Mail & Upgrades)
-- =================================================================================

-- 12.1 基础养成与比赛明细维表查�?(示例)
SELECT * FROM g23002013.tmp_skill WHERE card_name = '传奇鱼住�?;
SELECT * FROM g23002013.tmp_skill_base;
SELECT * FROM g23002013_dev.tmp_match;
SELECT * FROM g23002013_dev.tmp_peak_detail;


-- =================================================================================
-- 13. 海外点券换算与道具销售监�?(GL Stamp & Item Analysis)
-- =================================================================================

-- 13.1 全球各地区点券消耗对齐统�?(繁体/韩国/全球)
-- 逻辑：通过正则清洗 a_rst 内的 JSON 数组，解�?obj �?diff，汇总点券消�?
SELECT zone_clean, user_id, -SUM(diff) AS total_stamp_cost 
FROM (
    -- 繁体�?(TW)
    SELECT REGEXP_REPLACE(zone, 'ali_tt_', '') AS zone_clean, user_id, CAST(diff AS DOUBLE) AS diff, obj 
    FROM g23002013.game_Log 
    LATERAL VIEW EXPLODE(SPLIT(REGEXP_REPLACE(REGEXP_REPLACE(a_rst, '\\[|\\]', ''), '},{', '}|{'), '\\|')) ss AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE dt BETWEEN 20250605 AND 20250619 AND CAST(log_t AS INT) <= 1750298400
    
    UNION ALL
    -- 韩国�?(KR)
    SELECT REGEXP_REPLACE(zone, 'ali_tt_', '') AS zone_clean, user_id, CAST(diff AS DOUBLE) AS diff, obj 
    FROM g33002013.game_Log 
    LATERAL VIEW EXPLODE(SPLIT(REGEXP_REPLACE(REGEXP_REPLACE(a_rst, '\\[|\\]', ''), '},{', '}|{'), '\\|')) ss AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE dt BETWEEN 20250605 AND 20250619 AND CAST(log_t AS INT) <= 1750298400

    UNION ALL
    -- 全球�?(GL/GL)
    SELECT REGEXP_REPLACE(zone, 'ali_tt_', '') AS zone_clean, user_id, CAST(diff AS DOUBLE) AS diff, obj 
    FROM g63002013.game_Log 
    LATERAL VIEW EXPLODE(SPLIT(REGEXP_REPLACE(REGEXP_REPLACE(a_rst, '\\[|\\]', ''), '},{', '}|{'), '\\|')) ss AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE dt BETWEEN 20250605 AND 20250619 AND CAST(log_t AS INT) <= 1750298400
) tmp 
WHERE obj IN ('dmp:stamps', 'dmp:freestamps') AND diff < 0
GROUP BY zone_clean, user_id;


-- 13.2 道具售卖 (Item Sell) 产出金币深度追踪
-- 逻辑：锁�?a_typ = 'item_sell'，统计特定道具消耗与金币产出的对应关�?
SELECT 
    FROM_UNIXTIME(CAST(log_t AS INT)) AS sell_time,
    zone,
    user_id,
    MAX(CASE WHEN obj = 'dmp:gold' THEN diff END) AS gold_gained,
    MAX(CASE WHEN obj = 'item@40029548' THEN diff END) AS item1_used,
    MAX(CASE WHEN obj = 'item@40029549' THEN diff END) AS item2_used
FROM (
    SELECT log_t, zone, user_id, obj, diff
    FROM g63002013.game_Log
    LATERAL VIEW EXPLODE(SPLIT(REGEXP_REPLACE(REGEXP_REPLACE(a_rst, '\\[|\\]', ''), '},{', '}|{'), '\\|')) ss AS rst
    LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
    WHERE dt BETWEEN 20250612 AND 20250619
      AND CAST(log_t AS INT) <= 1750312800
      AND a_typ = 'item_sell'
) raw
GROUP BY FROM_UNIXTIME(CAST(log_t AS INT)), zone, user_id, log_t
HAVING (COUNT(DISTINCT CASE WHEN obj = 'item@40029548' THEN 1 END) > 0 OR COUNT(DISTINCT CASE WHEN obj = 'item@40029549' THEN 1 END) > 0);


-- 13.3 特定活动 SKU (OneStore/Samsung) 销售明细与角色关联
SELECT 
    a.*, 
    b.user_id AS snapshot_user_id
FROM (
    SELECT 
        FROM_UNIXTIME(report_time) AS dtime,
        order_id,
        lcm_id,
        sku,
        sku_name,
        unit_show,
        price_show,
        GET_JSON_OBJECT(memo1, '$.zoneId') AS zone
    FROM dm_platform.daily_lcx_user_purchase 
    WHERE day = 20250710 AND app_id = '33002013' 
      AND sku IN (
        'com.denachina.g33002013.onestore_tier27.package0041', 'com.denachina.g33002013.onestore_tier14.package0042',
        'com.denachina.g33002013.onestore_tier55.package0043', 'com.denachina.g33002013.onestore_tier53.package0044',
        'com.denachina.g33002013.samsung_tier27.package0041', 'com.denachina.g33002013.samsung_tier14.package0042',
        'com.denachina.g33002013.samsung_tier55.package0043', 'com.denachina.g33002013.samsung_tier53.package0044'
      )
) AS a 
LEFT JOIN (
    -- 关联充值当日活跃且有快照记录的角色
    SELECT DISTINCT mbga_uid, user_id, zone 
    FROM g33002013.daily_user_snapshot 
    WHERE day = 20250710
) AS b ON a.lcm_id = b.mbga_uid AND a.zone = b.zone;




-- =================================================================================
-- 14. 用户留存、关键量级与活跃深度分析 (User Retention & Quantity Deep Dive)
-- =================================================================================

-- 14.1 跨月新增用户留存追踪 (针对特定注册批次)
-- 逻辑：锁定注册日期在 20241001 之后的用户，计算不同周期 (RR1-RR240) 的留存率�?
-- 注意：使�?rf > N 确保分母漂移逻辑，即只统计注册时长已满足检测周期的用户�?
SELECT 
    SUBSTR(day, 1, 6) AS reg_month,
    SUM(nuu) AS daily_new_users,
    CASE WHEN SUM(CASE WHEN rf > 1   THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf > 1   AND df = 1  THEN ru ELSE 0 END) / SUM(CASE WHEN rf > 1   THEN nuu ELSE 0 END) END AS rr1,
    CASE WHEN SUM(CASE WHEN rf > 3   THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf > 3   AND df = 3  THEN ru ELSE 0 END) / SUM(CASE WHEN rf > 3   THEN nuu ELSE 0 END) END AS rr3,
    CASE WHEN SUM(CASE WHEN rf > 7   THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf > 7   AND df = 7  THEN ru ELSE 0 END) / SUM(CASE WHEN rf > 7   THEN nuu ELSE 0 END) END AS rr7,
    CASE WHEN SUM(CASE WHEN rf > 30  THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf > 30  AND df = 30 THEN ru ELSE 0 END) / SUM(CASE WHEN rf > 30  THEN nuu ELSE 0 END) END AS rr30,
    CASE WHEN SUM(CASE WHEN rf > 90  THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf > 90  AND df = 90 THEN ru ELSE 0 END) / SUM(CASE WHEN rf > 90  THEN nuu ELSE 0 END) END AS rr90,
    CASE WHEN SUM(CASE WHEN rf > 240 THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf > 240 AND df = 240 THEN ru ELSE 0 END) / SUM(CASE WHEN rf > 240 THEN nuu ELSE 0 END) END AS rr240
FROM (
    SELECT 
        a.*, b.day,
        CASE WHEN a.day2 = b.day THEN 1 ELSE 0 END AS nuu,
        DATEDIFF(CURRENT_TIMESTAMP, TO_DATE(day, 'yyyyMMdd')) AS rf,
        DATEDIFF(TO_DATE(day2, 'yyyyMMdd'), TO_DATE(day, 'yyyyMMdd')) AS df 
    FROM (
        -- 子查�?A：用户每日活跃记�?
        SELECT app_id, lcm_id, os, day AS day2, 1 AS ru 
        FROM dm_platform.daily_lcx_user_info 
        WHERE app_id = 63002013 AND day >= '20241001' AND reg_day < '20241001' AND is_water = '不是�?
    ) a
    JOIN (
        -- 子查�?B：用户在该统计段内的首日活跃记录（作为留存基准日期）
        SELECT lcm_id, MIN(day) AS day 
        FROM dm_platform.daily_lcx_user_info 
        WHERE app_id = 63002013 AND day >= '20241001' AND reg_day < '20241001' AND is_water = '不是�? 
        GROUP BY lcm_id 
    ) AS b ON a.lcm_id = b.lcm_id 
) AS a 
WHERE SUBSTR(day, 1, 6) >= '202410'
GROUP BY SUBSTR(day, 1, 6);


-- 14.2 平台钱包 (LCX_WALLET) 支付分国�?分商店汇�?
SELECT 
    SUBSTR(day, 1, 6) AS months,
    CASE 
        WHEN SUBSTR(app_id, 1, 1) = '2' THEN 'TW' 
        WHEN SUBSTR(app_id, 1, 1) = '3' THEN 'KR' 
        ELSE 'GL' 
    END AS region_type,
    validation_type,
    store,
    SUM(price_show) AS total_original_sales,
    SUM(price_show * COALESCE(c.exchange_rate, 1)) AS total_cny_sales 
FROM (
    SELECT SUBSTR(day, 1, 6) AS months, day, store, order_id, price_show, lcm_id, unit_show, app_id, validation_type 
    FROM dm_platform.daily_lcx_user_purchase
    WHERE app_id IN (23002013, 33002013, 63002013) 
      AND day BETWEEN 20241201 AND 20251031  
      AND validation_type = 'LCX_WALLET'
) a  
LEFT JOIN (
    -- 获取对应月份汇率均�?
    SELECT SUBSTR(day_hour, 1, 6) AS months, trans_from, MAX(exchange_rate) AS exchange_rate
    FROM dm_platform.itunes_exchange_rate_fmp 
    WHERE trans_to = 'cny' AND day >= 20250101
    GROUP BY SUBSTR(day_hour, 1, 6), trans_from
) c ON a.months = c.months AND UPPER(a.unit_show) = c.trans_from
GROUP BY 1, 2, 3, 4;



-- 14.3 活跃用户登录频次与同时在�?(Concurrent) 估算
-- 逻辑：对于特定日期，�?30 分钟 (1800s) 为窗口，统计区间内活跃的唯一用户�?
SELECT 
    FROM_UNIXTIME(FLOOR(a.dtime / 1800) * 1800) AS time_window_start,
    COUNT(DISTINCT b.lcm_id) AS window_active_uu 
FROM (
    -- 时间轴基�?
    SELECT DISTINCT 1 AS tf, CAST(ROUND(event_time / 1000, 0) AS INT) AS dtime 
    FROM dm_platform.daily_lcx_user_login  
    WHERE day = '20240123' AND app_id = 65002007
) AS a 
JOIN (
    -- 活跃用户时间点关�?
    SELECT DISTINCT 1 AS tf, CAST(ROUND(event_time / 1000, 0) AS INT) AS dtime, lcm_id 
    FROM dm_platform.daily_lcx_user_login  
    WHERE day = '20240123' AND app_id = 65002007
) AS b ON a.tf = b.tf AND b.dtime <= a.dtime
JOIN (
    -- 过滤出此前一天也活跃的老用�?
    SELECT DISTINCT lcm_id 
    FROM dm_platform.daily_lcx_user_login  
    WHERE day = '20240122' AND app_id = 65002007
) AS c ON b.lcm_id = c.lcm_id
GROUP BY 1;


-- 14.4 深度活跃行为记录计数 (针对特定事件)
SELECT 
    event_name,
    COUNT(*) AS event_count
FROM g65002007.daily_game_log
WHERE day = '20240123' AND event_time <= 17060112000000 
GROUP BY event_name;


-- 14.5 活跃角色留存与时长统�?(分注�?活跃)
SELECT 
    COUNT(DISTINCT CASE WHEN day = reg_day THEN lcm_id END) AS new_user_count,
    COUNT(DISTINCT lcm_id) AS active_user_count 
FROM dm_platform.daily_lcx_user_info 
WHERE day = '20240123' AND app_id = 65002007 AND is_water = '不是�? AND event_time <= 1706011200;


-- 14.6 角色在线时长分布统计 (Online Duration Analysis)
-- 逻辑：通过 LEAD 函数获取下一次活跃时间点，若间隔小于 120 秒则计入在线，否则视为离线�?
SELECT 
    ROUND(AVG(online_seconds) / 60, 2) AS avg_online_minutes 
FROM (
    SELECT a.role_id, a.day, SUM(CASE WHEN next_time - log_t >= 120 THEN 0 ELSE next_time - log_t END) AS online_seconds 
    FROM (
        SELECT 
            CAST(event_time / 1000 AS INT) AS log_t,
            role_id,
            day,
            CASE 
                WHEN LEAD(CAST(event_time / 1000 AS INT), 1) OVER(PARTITION BY role_id, day ORDER BY CAST(event_time / 1000 AS INT)) IS NULL THEN CAST(event_time / 1000 AS INT) + 3600
                ELSE LEAD(CAST(event_time / 1000 AS INT), 1) OVER(PARTITION BY role_id, day ORDER BY CAST(event_time / 1000 AS INT)) 
            END AS next_time 
        FROM g65002007.daily_game_log 
        WHERE day = '20240123' AND event_name NOT LIKE '%snapshot%' AND event_time <= 17059248000000 
    ) AS a 
    GROUP BY a.role_id, a.day
) AS t1;



-- 14.7 特定注册时段用户 LTV 与滚�?(LTV & ARPU Tracking)
-- 逻辑：锁定特定注册用户段（如 OBT 期间），计算 1-7 日的累计流水 (LTV) 与留存率�?
SELECT 
    SUBSTR(day, 1, 6) AS reg_month,
    country_code,
    SUM(nuu) AS new_user_count,
    COUNT(DISTINCT CASE WHEN SUBSTR(a.day, 1, 6) = SUBSTR(a.day2, 1, 6) AND puu_a > 0 THEN lcm_id END) AS first_month_puu,
    SUM(CASE WHEN SUBSTR(a.day, 1, 6) = SUBSTR(a.day2, 1, 6) THEN sales ELSE 0 END) AS first_month_sales,
    CASE WHEN SUM(nuu) = 0 THEN 0 ELSE SUM(CASE WHEN SUBSTR(a.day, 1, 6) = SUBSTR(a.day2, 1, 6) THEN sales ELSE 0 END) / SUM(nuu) END AS arpu_m1,
    CASE WHEN SUM(CASE WHEN rf >= 1 THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf >= 1 AND df < 1  THEN sales ELSE 0 END) / SUM(CASE WHEN rf >= 1 THEN nuu ELSE 0 END) END AS ltv1,
    CASE WHEN SUM(CASE WHEN rf >= 7 THEN nuu ELSE 0 END) = 0 THEN 0 ELSE SUM(CASE WHEN rf >= 7 AND df < 7  THEN sales ELSE 0 END) / SUM(CASE WHEN rf >= 7 THEN nuu ELSE 0 END) END AS ltv7
FROM (
    SELECT 
        country_code, app_id, lcm_id, os, reg_day AS day, day AS day2,
        CAST(purchase AS DOUBLE) AS sales,
        CASE WHEN user_type = 'nuu' THEN 1 ELSE 0 END AS nuu,
        CASE WHEN total_purchase > 0 THEN 1 ELSE 0 END AS puu_a,    
        DATEDIFF(TO_DATE('20240201', 'yyyyMMdd'), TO_DATE(reg_day, 'yyyyMMdd')) AS rf,
        DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE(reg_day, 'yyyyMMdd')) AS df
    FROM dm_platform.daily_lcx_user_info 
    WHERE app_id = 65002005 AND day >= '20231205' AND reg_day >= '20231205' AND is_water = '不是�?
      AND country_code IN ('TW', 'HK', 'KR', 'SG')
) a
GROUP BY SUBSTR(day, 1, 6), country_code 
HAVING SUBSTR(day, 1, 6) = '202312';


-- 14.8 海外用户量级分布 (按全球大区合并统�?
-- 逻辑：将繁琐的国家列表聚类为“美欧”、“繁体”、“东南亚”、“中东”四大区�?
SELECT 
    FLOOR(DATEDIFF(TO_DATE(day, 'yyyyMMdd'), TO_DATE('20231204', 'yyyyMMdd')) / 7) AS reg_week_offset,
    CASE 
        WHEN country_name IN ('澳门', '韩国', '香港特别行政�?, '台湾�?) THEN '2.繁体韩国' 
        WHEN country_name IN ('印度尼西�?, '老挝', '柬埔�?, '菲律�?, '文莱', '泰国', '东帝�?, '越南', '缅甸', '马来西亚', '新加�?) THEN '3.东南�? 
        WHEN country_name IN ('阿曼', '阿塞拜疆', '巴勒斯坦', '格鲁吉亚', '也门', '伊拉�?, '土耳其', '阿拉伯联合酋长国', '科威�?, '沙特阿拉�?, '亚美尼亚', '阿富�?, '约旦', '卡塔�?, '叙利�?, '黎巴�?, '巴林', '以色�?, '伊朗', '塞浦路斯') THEN '4.中东'
        ELSE '1.美洲欧洲及其�? 
    END AS region_cluster,  
    COUNT(DISTINCT lcm_id) AS total_uu,
    COUNT(DISTINCT CASE WHEN is_water = '不是�? THEN lcm_id END) AS physical_device_uu
FROM dm_platform.daily_lcx_user_info 
WHERE app_id = 65002005 AND day BETWEEN 20231205 AND 20231231 AND reg_day = day 
GROUP BY 1, 2;


-- 14.9 分区�?(Zone Type) 同时在线 PCU/ACU 深度监测
-- 逻辑：按 5 分钟 (300s) 统计区间活跃角色，计算平�?(ACU) 与峰�?(PCU)
SELECT 
    t1.day,
    t1.zone_type,
    ROUND(AVG(uu)) AS acu,
    MAX(uu) AS pcu 
FROM (
    SELECT 
        a.day,
        zone_type,
        a.times,
        COUNT(DISTINCT b.user_id) AS uu
    FROM (
        -- 基准时间序列
        SELECT DISTINCT day, FROM_UNIXTIME(FLOOR(log_t / 300) * 300, 'yyyy-MM-dd HH:mm:ss') AS times, INT(log_t / 60) AS log_t_min
        FROM g63002013.daily_game_log
        WHERE day BETWEEN 20250618 AND 20250918
    ) a 
    LEFT JOIN (
        -- 角色活跃分布
        SELECT DISTINCT day, user_id, INT(log_t / 60) AS log_t_min, SUBSTR(REGEXP_REPLACE(zone, 'ali_tt_', ''), 1, 1) AS zone_type 
        FROM g63002013.daily_game_log
        WHERE day BETWEEN 20250618 AND 20250918
    ) AS b ON a.day = b.day AND b.log_t_min - a.log_t_min BETWEEN -5 AND 5
    GROUP BY a.day, zone_type, a.times
) AS t1
GROUP BY t1.day, t1.zone_type;

;


select a.months,a.day,a.channel_no,a.product_id,a.lcm_id,a.game_id,a.store,a.channel_type,a.paid_amount,a.currency_code,c.exchange_rate,transaction_type,
d.user_id,d.zone,d.level
from 
(
select substr(day,1,6) as months,day,channel_no,product_id,paid_amount,lcx_user_id as lcm_id,game_id,store,channel_type,currency_code,transaction_type
from dm_platform.transaction_wallet 
where day between 20251016 and 20251020 and transaction_type in ('CHARGE','DIRECT_CHARGE') and game_id in ('33002013') --and channel_type = 'AirWallex'
) a  
LEFT JOIN --处理汇率
(SELECT substr(day_hour,1,6) months,trans_from,max(exchange_rate) exchange_rate
 FROM dm_platform.itunes_exchange_rate_fmp 
 WHERE trans_to = 'cny' 
 and day >= 20250101
 group by substr(day_hour,1,6),trans_from
)  c 
on a.months = c.months and upper(a.currency_code) = c.trans_from
left outer join 
(select distinct ff.mbga_uid,ff.user_id,ff.zone,ff.level from 
(select mbga_uid,user_id,zone,level,
row_number()over(partition by mbga_uid order by level desc) as ranks
from g33002013.daily_user_snapshot 
where day = 20251020
) as ff 
where ranks = 1) as d 
on a.lcm_id = d.mbga_uid;


-- 14.10 用户付费深度阶梯分布统计 (Spending Tier Analysis)
-- 逻辑：按累计付费金额划分阶梯�?-9级），统计各阶梯的活跃用户数�?
SELECT 
    spend_type,
    COUNT(DISTINCT lcm_id) AS user_count 
FROM (
    SELECT 
        lcm_id,
        CASE 
            WHEN MAX(total_purchase) > 0 AND MAX(total_purchase) <= 50 THEN 1 
            WHEN MAX(total_purchase) > 50 AND MAX(total_purchase) <= 150 THEN 2 
            WHEN MAX(total_purchase) > 150 AND MAX(total_purchase) <= 500 THEN 3 
            WHEN MAX(total_purchase) > 500 AND MAX(total_purchase) <= 1200 THEN 4 
            WHEN MAX(total_purchase) > 1200 AND MAX(total_purchase) <= 3000 THEN 5 
            WHEN MAX(total_purchase) > 3000 AND MAX(total_purchase) <= 5000 THEN 6 
            WHEN MAX(total_purchase) > 5000 AND MAX(total_purchase) <= 9999 THEN 7 
            WHEN MAX(total_purchase) > 9999 AND MAX(total_purchase) <= 30000 THEN 8 
            WHEN MAX(total_purchase) > 30000 THEN 9 
        END AS spend_type
    FROM dm_platform.daily_lcx_user_info 
    WHERE app_id = '65002007' AND day >= '20230101' 
    GROUP BY lcm_id
) AS a 
GROUP BY spend_type;


-- 14.11 特定外显/球场道具 (Decoration/Ball) 持有角色活跃追踪
-- 逻辑：通过正则/SPLIT解析 decoration 字段中的道具 ID，关联活跃用户快照�?
SELECT 
    a.user_id,
    a.zone,
    b.ball_id,
    a.last_login 
FROM (
    SELECT 
        DISTINCT mbga_uid, user_id, nickname, zone,
        CASE 
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 0 AND 6 THEN 'V1'
            WHEN total_pay BETWEEN 6 AND 30 THEN 'V2'
            WHEN total_pay BETWEEN 30 AND 100 THEN 'V3'
            WHEN total_pay BETWEEN 100 AND 500 THEN 'V4'
            WHEN total_pay BETWEEN 500 AND 1000 THEN 'V5'
            WHEN total_pay BETWEEN 1000 AND 3000 THEN 'V6' 
            WHEN total_pay BETWEEN 3000 AND 10000 THEN 'V7' 
            WHEN total_pay BETWEEN 10000 AND 30000 THEN 'V8' 
            WHEN total_pay >= 30000 THEN 'V9' 
        END AS vip_level,
        FROM_UNIXTIME(CAST(last_login AS INT)) AS last_login
    FROM g63002013.daily_user_snapshot
    WHERE day = 20251023
) AS a 
JOIN (
    SELECT 
        user_id, 
        SPLIT(SPLIT(decoration, 'item_id":"')[1], '"')[0] AS ball_id 
    FROM g63002013.daily_user_decoration_snapshot 
    LATERAL VIEW EXPLODE(SPLIT(court, '},')) a_tar AS decoration
    WHERE day = 20251023
) AS b ON a.user_id = b.user_id 
WHERE b.ball_id IN (106010020, 106010036, 106010092, 106010116, 106010117, 106010119, 106010121, 106010130, 106010131, 106010144, 106010145, 106010155);


-- =================================================================================
-- 15. 专项数据对比、付费构成与大区 KPI (Special Comparison & Regional KPI)
-- =================================================================================

-- 15.1 OBT 阶段特定国家/区域留存�?LTV 概云
SELECT 
    app_id, app_name, app_ab, period, start_date,
    SUM(nuu) AS new_user_count,
    ROUND(SUM(r1) / 1.0 / SUM(nuu1), 4) AS rr1,
    ROUND(SUM(r7) / 1.0 / SUM(nuu7), 4) AS rr7,
    ROUND(SUM(lt1) / 1.0 / SUM(nuu1), 4) AS ltv1,
    ROUND(SUM(lt7) / 1.0 / SUM(nuu7), 4) AS ltv7
FROM dm_platform.game_library 
WHERE partition_value IS NOT NULL AND nuu != '0' 
  AND period = 'OBT' AND country_code IN ('TW', 'HK', 'KR')
  AND app_id = '65002005' AND os = 'android' AND node = 'M1'
GROUP BY 1, 2, 3, 4, 5;


-- 15.2 特定活动 SKU 角色关联审计 (全球�?
SELECT 
    a.day, 
    FROM_UNIXTIME(CAST(a.event_time / 1000 AS INT)) AS purchase_time,
    a.app_id, a.order_id, a.sku, a.lcm_id, 
    b.user_id, b.zone, a.unit_show, a.price_show 
FROM (
    SELECT day, order_id, app_id, event_time, lcm_id, sku, GET_JSON_OBJECT(memo1, '$.zoneId') AS zone, unit_show, price_show 
    FROM dm_platform.daily_lcx_user_purchase  
    WHERE day BETWEEN 20251120 AND 20251128 AND app_id = '63002013' 
      AND sku LIKE '%package0072%'
) a 
LEFT JOIN (
    SELECT mbga_uid, user_id, zone 
    FROM g63002013.daily_user_snapshot 
    WHERE day = 20251127
) b ON a.zone = b.zone AND a.lcm_id = b.mbga_uid;


-- 15.3 运营活动 (Activity ID) 点券/金币产出监控
-- 逻辑：解�?log 统计特定活动�?dmp:money (或其他代�? 的影响量�?
SELECT 
    FROM_UNIXTIME(log_t) AS dtime, 
    mbga_uid, user_id, 
    GET_JSON_OBJECT(a_tar, '$.activity_id') AS aid,
    GET_JSON_OBJECT(a_tar, '$.type') AS action_type,
    a_typ, zone, obj, diff 
FROM g63002013.daily_game_log  
LATERAL VIEW EXPLODE(a_rst) rst_tab AS rst
LATERAL VIEW JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff 
WHERE day BETWEEN 20251113 AND 20251120 
  AND GET_JSON_OBJECT(a_tar, '$.activity_id') = '40243287' 
  AND obj = 'dmp:money';


-- 15.4 用户付费金额构成分布 (Revenue Composition)
-- 逻辑：锁定特定日期，按当日累计流水对用户进行分群�?-4 类），统�?PUU �?Sales 分布�?
SELECT 
    sales_type,
    COUNT(DISTINCT b.lcm_id) AS puu,
    SUM(sales) AS total_sales 
FROM (
    -- 基础用户池（排除黑名单）
    SELECT DISTINCT lcm_id 
    FROM dm_platform.daily_lcx_user_info 
    WHERE day = 20251125 AND app_id = '65002007' AND is_black = '不是�?
) a 
JOIN (
    -- 计算当日总流�?
    SELECT lcm_id, SUM(purchase) AS sales 
    FROM dm_platform.daily_lcx_user_info 
    WHERE day = 20251125 AND app_id = '65002007' 
    GROUP BY lcm_id
) b ON a.lcm_id = b.lcm_id 
CROSS JOIN (
    -- 定义分组阈�?
    SELECT 
        CASE 
            WHEN sales BETWEEN 1 AND 50 THEN 1
            WHEN sales BETWEEN 50 AND 500 THEN 2 
            WHEN sales BETWEEN 500 AND 2000 THEN 3 
            WHEN sales >= 2000 THEN 4 
        END AS sales_type
) t 
GROUP BY 1;


-- 15.5 全球大区 (Southeast Asia / EU / SA / NA) KPI 板块统计
-- 15.5.1 月度营收与付费渗�?
SELECT 
    a.month,
    CASE 
        WHEN SUBSTR(b.zone_id, 1, 1) = '1' THEN '東南�? 
        WHEN SUBSTR(b.zone_id, 1, 1) = '2' THEN '歐洲' 
        WHEN SUBSTR(b.zone_id, 1, 1) = '3' THEN '南美' 
        WHEN SUBSTR(b.zone_id, 1, 1) = '4' THEN '北美' 
    END AS region_name,
    COUNT(DISTINCT a.lcm_id) AS active_uu,
    COUNT(DISTINCT CASE WHEN purchase > 0 THEN a.lcm_id END) AS puu,
    SUM(purchase) AS total_sales 
FROM (
    SELECT month, purchase, lcm_id 
    FROM dm_platform.monthly_lcx_user_info 
    WHERE month >= 202301 AND app_id = 63002013 
) a 
JOIN (
    -- 关联角色注册�?分区快照
    SELECT mbga_uid, MIN(zone) AS zone_id 
    FROM g63002013.daily_user_snapshot  
    WHERE day = 20251201 
    GROUP BY mbga_uid
) b ON a.lcm_id = b.mbga_uid
GROUP BY 1, 2;

-- 15.5.2 区域 DAU 均值统�?
SELECT 
    SUBSTR(day, 1, 6) AS months,
    region_name,
    ROUND(AVG(uu), 0) AS avg_dau 
FROM (
    SELECT 
        a.day,
        CASE 
            WHEN SUBSTR(b.zone_id, 1, 1) = '1' THEN '東南�? 
            WHEN SUBSTR(b.zone_id, 1, 1) = '2' THEN '歐洲' 
            WHEN SUBSTR(b.zone_id, 1, 1) = '3' THEN '南美' 
            WHEN SUBSTR(b.zone_id, 1, 1) = '4' THEN '北美' 
        END AS region_name,
        COUNT(DISTINCT a.lcm_id) AS uu 
    FROM (
        SELECT day, lcm_id FROM dm_platform.daily_lcx_user_info 
        WHERE day >= 20230101 AND app_id = 63002013 AND is_water = '不是�?
    ) a 
    JOIN (
        SELECT mbga_uid, MIN(zone) AS zone_id FROM g63002013.daily_user_snapshot WHERE day = 20251201 GROUP BY mbga_uid
    ) b ON a.lcm_id = b.lcm_id
    GROUP BY 1, 2
) AS daily_metrics 
GROUP BY 1, 2;


-- 15.6 流失用户召回价值初步评�?
-- 评估逻辑：筛选特定时间段活跃过但后续长期未登录的用户，分析其历史 Device ID 留存�?
SELECT 
    lcm_id, did, MAX(day) AS last_seen_day 
FROM dm_platform.daily_lcx_user_info 
WHERE day BETWEEN 20240327 AND 20250421 AND app_id = 65002007 AND is_water = '不是�? AND store = 'google'
  AND lcm_id NOT IN (
      SELECT DISTINCT lcm_id FROM dm_platform.daily_lcx_user_info WHERE day BETWEEN 20251125 AND 20251202
  )
GROUP BY 1, 2;








