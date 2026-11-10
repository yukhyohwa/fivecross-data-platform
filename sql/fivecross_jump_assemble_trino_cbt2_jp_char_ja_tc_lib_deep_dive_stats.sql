------------------------------------------------------------------------
------------------------------------------------------------------------
-------------------------------- 留存 -----------------------------------
------------------------------------------------------------------------
------------------------------------------------------------------------



-- 首日用户分内存留存

WITH
-- 目前没有黑名单表格
UserBlacklist AS (
SELECT "lcxuserid" "#account_id"
FROM ta.v_event_16
WHERE "$part_date" >= '2025-09-01'
AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
AND ABS(freeamount) > 0
GROUP BY 1
),

-- ltv/RR 最终时间表更
StartDate AS (
    SELECT MIN("$part_date") start_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
      AND "$part_event" = 'LOGIN_SUCCESS'
),


AccountMetrics AS (
    SELECT *
    FROM (
        SELECT "$part_date","#account_id",
        IF(LOWER(os) LIKE '%android%','Android',ostype) ostype,
        IF("#country_code" IN ('TW','HK','MO'), "#province", "#country") country, 
        ROW_NUMBER()OVER(PARTITION BY "#account_id" ORDER BY "#event_time" ASC) ranknum
        FROM ta.v_event_16
        WHERE "$part_date" BETWEEN '2025-11-24' AND '2025-12-02'
        AND "$part_event" IN ('NUU','LOGIN_SUCCESS','PURCHASE') 
    )
    WHERE ranknum = 1
    AND LOWER(ostype) <> 'ios'
),


DeviceInfo AS (
    SELECT *
    FROM (
        SELECT "$part_date",lcx_id,"#ram","#simulator",
        CASE 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) IN(0,1,2) THEN '4GB-' 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) IN(3) THEN '4GB' 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) IN(4,5) THEN '6GB' 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) IN(6,7) THEN '8GB' 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) IN(8,9,10,11) THEN '12GB' 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) IN(12,13,14,15) THEN '16GB' 
        WHEN CAST(SPLIT_PART(SPLIT_PART("#ram",'/',2),'.',1) AS INTEGER) >=16 THEN '16GB+' END real_ram,
        IF("#country_code" IN ('TW','HK','MO'), "#province", "#country") country, 
        ROW_NUMBER()OVER(PARTITION BY lcx_id ORDER BY "#event_time" ASC) ranknum
        FROM ta.v_event_16
        WHERE "$part_date" BETWEEN '2025-11-24' AND '2025-12-02'
        AND "$part_event" IN ('sdk_login') 
    )
    WHERE ranknum = 1
),

AccountRetentionArrays AS (
    SELECT s1."#account_id" , s2."$part_date" reg_date,  
           TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2."$part_date" AS DATE), d)) AS return_days_array
    FROM (

        SELECT "#account_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM v_event_16 s1
        CROSS JOIN StartDate s2
        WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
          AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS','PURCHASE')
        GROUP BY 1
    ) s1
    INNER JOIN AccountMetrics s2 ON s1."#account_id" = s2."#account_id"
)

    SELECT
        s1."$part_date" time_dimension,
        s3.real_ram,
        -- s1.ostype
        -- s1.country 
        COUNT(DISTINCT s1."#account_id") AS new_account,
        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_180,
        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#account_id") AS DOUBLE) AS rr_360,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 2), 0) week1_retention_rate,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3 AND CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x >= 0 AND x <= 6)) >= 3), 0) week2_return_rate
    FROM AccountMetrics s1
    LEFT JOIN AccountRetentionArrays s2 ON s1."#account_id" = s2."#account_id"
    LEFT JOIN DeviceInfo s3 ON s1."#account_id" = s3.lcx_id
    LEFT JOIN UserBlacklist s4 ON s1."#account_id" = s4."#account_id"
    WHERE s4."#account_id" IS NULL
    AND s1."$part_date" = '2025-11-25'
    GROUP BY 1 , 2 --, 3

------------------------------------------------------------------------
------------------------------------------------------------------------
-------------------------------- 新手引导 -------------------------------
------------------------------------------------------------------------
------------------------------------------------------------------------
WITH
UserBlacklist AS (
    SELECT "lcxuserid" lcx_id
    FROM ta.v_event_16
    WHERE "$part_date" >= '2025-09-01'
    AND "$part_event" = 'LCX_WALLET_SPEND_TRANSACTION'
    AND ABS(freeamount) > 0
    GROUP BY 1
),

DimPeriod AS (
    SELECT DISTINCT
    CASE 
        WHEN ${PartDate:date1} THEN '事件时间'
        WHEN ${PartDate:date2} THEN '对比时间' 
    END period,
    "$part_date"
    FROM v_event_16
    WHERE (${PartDate:date1} OR ${PartDate:date2})
),

CohortUsers AS (
    SELECT 
        "#account_id" AS lcx_id, -- NUU 事件通常用 #account_id
        d.period
    FROM ta.v_event_16 e
    JOIN DimPeriod d ON e."$part_date" = d."$part_date"
    WHERE e."$part_event" = 'NUU'
    GROUP BY 1, 2
),

RoleGuideLogs AS (
    SELECT 
        s1.guide_id,
        s1."$part_event",
        s2.lcx_id,
        s2.period 
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers s2 
        ON (CASE WHEN s1."$part_event" = 'NUU' THEN s1."#account_id" ELSE s1.lcx_id END) = s2.lcx_id
    LEFT JOIN UserBlacklist s3 ON s2.lcx_id = s3.lcx_id
    WHERE 
        s3.lcx_id IS NULL 
        AND s1."$part_event" IN ('NUU','role_guide_before','role_guide')
        AND s1."$part_date" >= (SELECT MIN("$part_date") FROM DimPeriod)
)


SELECT 
    p1.period,
    p1."引导步骤",
    p1.funnel_counts * 1.0 / NULLIF(p2.new_lcxid, 0) "值"
FROM (
    SELECT 
        s1.period,
        CASE 
            WHEN s1."$part_event" IN ('NUU') THEN '注册'
            WHEN s1.guide_id = 2      THEN '问卷完成'
            WHEN s1.guide_id = 3      THEN '选择英雄界面'
            WHEN s1.guide_id = 4      THEN '选择英雄完成'
            WHEN s1.guide_id = 5      THEN '引导加载完成'
            WHEN s1.guide_id = 6      THEN 'PV播放完成'
            WHEN s1.guide_id IN (100001,200001,300001) THEN '开始新手教学'
            WHEN s1.guide_id IN (100011,200011,300011) THEN '移动指定位置'
            WHEN s1.guide_id IN (100021,200021,300021) THEN '拖动普攻木桩'
            WHEN s1.guide_id IN (100031,200031,300031) THEN '点击普攻木桩'
            WHEN s1.guide_id IN (100041,200041,300041) THEN '技能攻击木桩'
            WHEN s1.guide_id IN (100051,200051,300051) THEN '大招攻击木桩'
            WHEN s1.guide_id = 7      THEN '打开战斗界面'
            WHEN s1.guide_id = 8      THEN '开始引导战斗'
            WHEN s1.guide_id = 9      THEN '战斗加载完成'
            WHEN s1.guide_id = 10     THEN '引导战斗完成'
            WHEN s1.guide_id = 11     THEN '获得英雄界面'
            WHEN s1.guide_id = 12     THEN '展示英雄界面'
            WHEN s1.guide_id = 13     THEN '引导流程完成'
            WHEN s1.guide_id = 150    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 151    THEN '点击领取第一个奖励'
            WHEN s1.guide_id = 152    THEN '点击【总奖杯奖励】'
            WHEN s1.guide_id = 200    THEN '点击【角色】'
            WHEN s1.guide_id = 201    THEN '选中当前拥有的英雄'
            WHEN s1.guide_id = 202    THEN '点击设定集界面的【升级】'
            WHEN s1.guide_id = 203    THEN '点击窗口中的【升级】'
            WHEN s1.guide_id = 204    THEN '点击关闭窗口'
            WHEN s1.guide_id = 205    THEN '点击退出【设定集】'
            WHEN s1.guide_id = 206    THEN '点击退出角色列表'
            WHEN s1.guide_id = 300    THEN '点击【休闲对战】'
            WHEN s1.guide_id = 301    THEN '点击更换玩法按钮'
            WHEN s1.guide_id = 302    THEN '将玩法切换为【积分争夺】'
            WHEN s1.guide_id = 400    THEN '点击【开始】'
            WHEN s1.guide_id = 401    THEN '战斗结束'
            WHEN s1.guide_id = 402    THEN '在战斗结算界面，点击【退出】'
            WHEN s1.guide_id = 403    THEN '在房间中，点击【休闲对战】'
            WHEN s1.guide_id = 500    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 501    THEN '点击领取第二个奖励（阅览券）'
            WHEN s1.guide_id = 502    THEN '点击【总奖杯奖励】'
            WHEN s1.guide_id = 503    THEN '点击【刊物】，进入刊物中心'
            WHEN s1.guide_id = 504    THEN '点击【兑换十次】，进行抽奖'
            WHEN s1.guide_id = 505    THEN '点击【刊物中心】，返回'
            WHEN s1.guide_id = 600    THEN '点击【休闲对战】，更换英雄'
            WHEN s1.guide_id = 601    THEN '更换出战英雄'
        END "引导步骤",
        COUNT(DISTINCT lcx_id) funnel_counts
    FROM RoleGuideLogs s1 
    GROUP BY 1, 2
) p1
LEFT JOIN (
    SELECT 
        s1.period,
        COUNT(DISTINCT lcx_id) new_lcxid 
    FROM RoleGuideLogs s1 
    WHERE "$part_event" IN ('NUU')  
    GROUP BY 1
) p2 ON p1.period = p2.period
WHERE p1."引导步骤" IS NOT NULL
ORDER BY p1.period, p1.funnel_counts DESC
------------------------------------------------------------------------
------------------------------------------------------------------------
-------------------------------- 其他 -----------------------------------
------------------------------------------------------------------------
------------------------------------------------------------------------
WITH
-- 目前没有黑名单表格
UserBlacklist AS (
    SELECT 'test' "#account_id" 
),

-- 时间选择
DimPeriod AS (
    SELECT DISTINCT
    CASE 
    WHEN ${PartDate:date1} THEN '事件时间'
    WHEN ${PartDate:date2} THEN '对比时间' END period,
    "$part_date"
    FROM v_event_16
    WHERE (${PartDate:date1} OR ${PartDate:date2})
    AND "$part_event" IN  ('LOGIN_SUCCESS')
),

-- ltv/RR 最终时间表更
StartDate AS (
    SELECT MIN("$part_date") start_date
    FROM ta.v_event_16
    WHERE (${PartDate:date1} OR ${PartDate:date2})
      AND "$part_event" = 'LOGIN_SUCCESS'
),


DeviceMetrics AS (
    SELECT "#account_id" ,MIN("$part_date") reg_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
      AND "$part_event" = 'NUU'
    GROUP BY 1
),


DeviceRetentionArrays AS (
    SELECT s1."#account_id" , s2."$part_date" reg_date,
           TRANSFORM(ARRAY_SORT(s1.return_date_array), d -> DATE_DIFF('day', CAST(s2."$part_date" AS DATE), d)) AS return_days_array
    FROM (

        SELECT "#account_id", ARRAY_AGG(DISTINCT CAST("$part_date" AS DATE)) AS return_date_array
        FROM v_event_16 s1
        CROSS JOIN StartDate s2
        WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
          AND "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
        GROUP BY 1
    ) s1
    INNER JOIN DeviceMetrics s2 ON s1."#account_id" = s2."#account_id"
),


NewDeviceRR AS (
    SELECT

        CASE
            WHEN ${Selector:selector2} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'A' THEN '0000-00-00'
        END AS time_dimension,

        ${Selector:selector3} media_source,
        ${Selector:selector4} campaign,
        CASE WHEN ${Selector:selector5} THEN '已合并' ELSE s3.ad_creative END ad_creative,
        CASE WHEN ${Selector:selector6} THEN '已合并' ELSE s3.country_code END country_code,
        ${Selector:selector7} organic_type,
        CONCAT(MIN(s1."$part_date"), '-', MAX(s1."$part_date")) date_range,
        COUNT(DISTINCT s1."#device_id") AS new_device,
        -- Genesis 19:17
        CAST(COUNT_IF(CONTAINS(return_days_array, 0)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_1,
        CAST(COUNT_IF(CONTAINS(return_days_array, 1)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_2,
        CAST(COUNT_IF(CONTAINS(return_days_array, 2)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_3,
        CAST(COUNT_IF(CONTAINS(return_days_array, 3)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_4,
        CAST(COUNT_IF(CONTAINS(return_days_array, 4)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_5,
        CAST(COUNT_IF(CONTAINS(return_days_array, 5)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_6,
        CAST(COUNT_IF(CONTAINS(return_days_array, 6)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_7,
        CAST(COUNT_IF(CONTAINS(return_days_array, 13)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_14,
        CAST(COUNT_IF(CONTAINS(return_days_array, 29)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_30,
        CAST(COUNT_IF(CONTAINS(return_days_array, 59)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_60,
        CAST(COUNT_IF(CONTAINS(return_days_array, 89)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_90,
        CAST(COUNT_IF(CONTAINS(return_days_array, 179)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_180,
        CAST(COUNT_IF(CONTAINS(return_days_array, 359)) AS DOUBLE) / CAST(COUNT(DISTINCT s1."#device_id") AS DOUBLE) AS rr_360,
 
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x <= 6)) >= 3) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x <= 6)) >= 2), 0) week1_retention_rate,
        CAST(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x BETWEEN 7 AND 13)) >= 1) AS DOUBLE) / NULLIF(COUNT_IF(CARDINALITY(FILTER(return_days_array, x -> x <= 6)) >= 3), 0) week2_return_rate
    FROM DeviceMetrics s1
    LEFT JOIN DeviceRetentionArrays s2 ON s1."#device_id" = s2."#device_id"
    LEFT JOIN DeviceInfo s3 ON s1."#device_id" = s3.device_id
    GROUP BY 1, 2, 3, 4, 5, 6
),


DailyDeviceRevenue AS (
    SELECT
        device_id,
        "$part_date",
        SUM(pay_amount) * 0.01 AS revenue_usd
    FROM v_event_16 s1
    CROSS JOIN StartDate s2
    WHERE "$part_date" BETWEEN s2.start_date AND CAST(CURRENT_DATE AS VARCHAR)
      AND "$part_event" IN ('order_pay')
      AND is_sandbox = false
      AND environment_id = 'zhuzi'
    GROUP BY 1, 2
),


DeviceLtvMap AS (
    SELECT
        s2."#device_id",
        MAP_AGG(
            DATE_DIFF('day', CAST(s2."$part_date" AS DATE), CAST(s1."$part_date" AS DATE)),
            s1.revenue_usd                                                               
        ) AS revenue_map
    FROM DailyDeviceRevenue s1
    INNER JOIN DeviceMetrics s2 ON s1.device_id = s2."#device_id"
    GROUP BY s2."#device_id"
),

NewDeviceLTV AS (
    SELECT

        CASE
            WHEN ${Selector:selector2} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:selector2} = 'A' THEN '0000-00-00'
        END AS time_dimension,
        ${Selector:selector3} media_source,
        ${Selector:selector4} campaign,
        CASE WHEN ${Selector:selector5} THEN '已合并' ELSE s3.ad_creative END ad_creative,
        CASE WHEN ${Selector:selector6} THEN '已合并' ELSE s3.country_code END country_code,
        ${Selector:selector7} organic_type,
        CONCAT(MIN(s1."$part_date"), '-', MAX(s1."$part_date")) date_range,
        COUNT(DISTINCT s1."#device_id") AS new_device,
        -- Genesis 19:17
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 1)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_1,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 2)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_2,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 3)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_3,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 4)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_4,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 5)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_5,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 6)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_6,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 7)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_7,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 14)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_14,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 30)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_30,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 60)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_60,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 90)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_90,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 180)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_180,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 360)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_360,
        CAST(AVG(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 540)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS ltv_540,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 1)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_1,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 2)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_2,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 3)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_3,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 4)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_4,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 5)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_5,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 6)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_6,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 7)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_7,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 14)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_14,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 30)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_30,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 60)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_60,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 90)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_90,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 180)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_180,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 360)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_360,
       CAST(SUM(COALESCE(REDUCE(MAP_VALUES(MAP_FILTER(s4.revenue_map, (k, v) -> k < 540)), 0.0, (k, v) -> k + v, k -> k), 0)) AS DOUBLE) AS revenue_540
    FROM DeviceMetrics s1
    LEFT JOIN DeviceInfo s3 ON s1."#device_id" = s3.device_id
    LEFT JOIN DeviceLtvMap s4 ON s1."#device_id" = s4."#device_id"
    GROUP BY 1, 2, 3, 4, 5, 6
),

ActivityLogs AS (
    SELECT "#device_id", "$part_date", COUNT(1) cnt
    FROM v_event_16
    WHERE "$part_date" > '2022-06-01'
      AND "$part_event" = 'ta_app_start'
      AND environment_id = 'zhuzi'
      AND "#device_id" IS NOT NULL
      AND ("#app_version" NOT IN ('1.0.620', '1.0.619', '1.0.332', '1.0.334','1.0.630') OR "#app_version" IS NULL)
    GROUP BY "#device_id", "$part_date"
),

ReturningUsers90d AS (
    SELECT "#device_id", "$part_date" AS return_date
    FROM (
        SELECT "#device_id", "$part_date",
               LAG(CAST("$part_date" AS DATE), 1) OVER (PARTITION BY "#device_id" ORDER BY "$part_date") AS prev_login_date
        FROM ActivityLogs
    ) s
    WHERE prev_login_date IS NOT NULL
      AND DATE_DIFF('day', prev_login_date, CAST("$part_date" AS DATE)) >= 90
),


DeviceKPI AS (
    SELECT
        CASE 
        WHEN ${Selector:selector2} = 'D' THEN CAST(DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:selector2} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:selector2} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:selector2} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:selector2} = 'A' THEN '0000-00-00'
        END AS time_dimension,
        ${Selector:selector3}  media_source,
        ${Selector:selector4}  campaign,
        CASE WHEN ${Selector:selector5} THEN '已合并' ELSE s3.ad_creative  END ad_creative,
        CASE WHEN ${Selector:selector6} THEN '已合并' ELSE s3.country_code END country_code,
        ${Selector:selector7} organic_type,
        CONCAT(MIN(s1."$part_date"),'-', MAX(s1."$part_date")) date_range,
        COUNT(DISTINCT COALESCE(s1."#device_id", s1.device_id)) AS active_device,
        COUNT(DISTINCT CASE WHEN "$part_event" IN ('order_pay') AND is_sandbox = false THEN COALESCE(s1."#device_id", s1.device_id) END) AS paying_device,
        SUM(CASE WHEN "$part_event" IN ('order_pay') AND is_sandbox = false THEN pay_amount * 0.01 END) total_revenue,
        COUNT(DISTINCT CASE WHEN s6."#device_id" IS NOT NULL THEN COALESCE(s1."#device_id", s1.device_id) END) AS return_device,
        COUNT(DISTINCT CASE WHEN s6."#device_id" IS NOT NULL AND "$part_event" IN ('order_pay') AND is_sandbox = false THEN COALESCE(s1."#device_id",s1.device_id) END) AS return_paying_device,
        SUM(CASE WHEN s6."#device_id" IS NOT NULL AND "$part_event" IN ('order_pay') AND is_sandbox = false THEN pay_amount*0.01 END) returning_user_revenue
    FROM v_event_16 s1
    LEFT JOIN DeviceInfo s3 ON COALESCE(s1."#device_id", s1.device_id) = s3.device_id
    LEFT JOIN ReturningUsers90d s6 ON s1."$part_date" = s6.return_date AND COALESCE(s1."#device_id", s1.device_id) = s6."#device_id"
    WHERE s1.${PartDate:date1}
      AND "$part_event" IN ('order_pay', 'ta_app_install', 'ta_app_start', 'httprequest_activate')
    GROUP BY 1, 2, 3, 4, 5, 6
),


NewDeviceKPI AS (
SELECT 
    CASE 
    WHEN ${Selector:selector2} = 'D'THEN CAST(DATE_TRUNC('day', CAST(s2."$part_date" AS DATE)) AS VARCHAR)
    WHEN ${Selector:selector2} = 'W' THEN CAST(DATE_TRUNC('week', CAST(s2."$part_date" AS DATE)) AS VARCHAR)
    WHEN ${Selector:selector2} = 'M' THEN CAST(DATE_TRUNC('month', CAST(s2."$part_date" AS DATE)) AS VARCHAR)
    WHEN ${Selector:selector2} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(s2."$part_date" AS DATE)) AS VARCHAR)
    WHEN ${Selector:selector2} = 'A' THEN '0000-00-00'
    END AS time_dimension,
    ${Selector:selector3}  media_source,
    ${Selector:selector4}  campaign,
    CASE WHEN ${Selector:selector5} THEN '已合并' ELSE s3.ad_creative  END ad_creative,
    CASE WHEN ${Selector:selector6} THEN '已合并' ELSE s3.country_code END country_code,
    ${Selector:selector7} organic_type,
    CONCAT(MIN(s2."$part_date"),'-', MAX(s2."$part_date")) date_range,
    COUNT(DISTINCT CASE 
    WHEN "$part_event" IN ('order_pay') AND is_sandbox = false 
    AND (
    (${Selector:selector2} = 'D' AND DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'W' AND DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'M' AND DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'S' AND DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'A' ) 
    )
    THEN COALESCE(s1."#device_id",s1.device_id) END) AS new_paying_device,
    SUM(CASE 
    WHEN "$part_event" IN ('order_pay') AND is_sandbox = false 
    AND (
    (${Selector:selector2} = 'D' AND DATE_TRUNC('day', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('day', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'W' AND DATE_TRUNC('week', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('week', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'M' AND DATE_TRUNC('month', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('month', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'S' AND DATE_TRUNC('quarter', CAST(s1."$part_date" AS DATE)) = DATE_TRUNC('quarter', CAST(s2."$part_date" AS DATE))) OR
    (${Selector:selector2} = 'A'  ) 
    )
    THEN pay_amount*0.01 END) AS new_device_revenue
    FROM v_event_16 s1
    INNER JOIN DeviceMetrics s2 ON COALESCE(s1."#device_id",s1.device_id) = s2."#device_id"
    LEFT JOIN DeviceInfo s3 ON COALESCE(s1."#device_id",s1.device_id)  = s3.device_id
    WHERE s1.${PartDate:date1} 
    AND "$part_event" IN ('order_pay','ta_app_install','ta_app_start','httprequest_activate') 
    AND environment_id = 'zhuzi'
    AND  (s1."#app_version" NOT IN ('1.0.620','1.0.619', '1.0.332', '1.0.334','1.0.630') OR  s1."#app_version" IS NULL)
    GROUP BY 1,2,3,4,5,6
) 

SELECT
    p1.date_range, p1.time_dimension, p1.media_source, p1.organic_type, p1.campaign, p1.ad_creative, p1.country_code,
    active_device, paying_device, total_revenue,
    paying_device / CAST(active_device AS DOUBLE) payrate,
    total_revenue / CAST(active_device AS DOUBLE) arpu,
    total_revenue / CAST(paying_device AS DOUBLE) arppu,
    p2.new_device, p5.new_paying_device, p5.new_device_revenue,
    return_device, return_paying_device, returning_user_revenue,
    p5.new_paying_device / CAST(p2.new_device AS DOUBLE) new_device_payrate,
    p5.new_device_revenue / p2.new_device new_device_arpu,
    p5.new_device_revenue / p5.new_paying_device new_device_arppu,
    rr_1,rr_2,rr_3,rr_4,rr_5,rr_6,rr_7,rr_14,rr_30,rr_60,rr_90,rr_180,rr_360,
    week1_retention_rate, week2_return_rate,
    ltv_1,ltv_2,ltv_3,ltv_4,ltv_5,ltv_6,ltv_7,ltv_14,ltv_30,ltv_60,ltv_90,ltv_180,ltv_360,ltv_540,
    total_ad_spend,
    revenue_1/NULLIF(total_ad_spend,0) roi_1,revenue_2/NULLIF(total_ad_spend,0) roi_2,revenue_3/NULLIF(total_ad_spend,0) roi_3,revenue_4/NULLIF(total_ad_spend,0) roi_4,
    revenue_5/NULLIF(total_ad_spend,0) roi_5,revenue_6/NULLIF(total_ad_spend,0) roi_6,revenue_7/NULLIF(total_ad_spend,0) roi_7,revenue_14/NULLIF(total_ad_spend,0) roi_14,
    revenue_30/NULLIF(total_ad_spend,0) roi_30,revenue_60/NULLIF(total_ad_spend,0) roi_60,revenue_90/NULLIF(total_ad_spend,0) roi_90,revenue_180/NULLIF(total_ad_spend,0) roi_180,
    revenue_360/NULLIF(total_ad_spend,0) roi_360,revenue_540/NULLIF(total_ad_spend,0) roi_540
FROM DeviceKPI p1
LEFT JOIN NewDeviceLTV p2 ON p1.date_range = p2.date_range AND p1.time_dimension = p2.time_dimension AND p1.media_source = p2.media_source AND p1.campaign = p2.campaign AND p1.ad_creative = p2.ad_creative AND p1.country_code = p2.country_code AND p1.organic_type = p2.organic_type
LEFT JOIN NewDeviceRR p3 ON p1.date_range = p3.date_range AND p1.time_dimension = p3.time_dimension AND p1.media_source = p3.media_source AND p1.campaign = p3.campaign AND p1.ad_creative = p3.ad_creative AND p1.country_code = p3.country_code AND p1.organic_type = p3.organic_type
-- LEFT JOIN AdSpend p4 ON p1.date_range = p4.date_range AND p1.time_dimension = p4.time_dimension AND p1.media_source = p4.media_source AND p1.campaign = p4.campaign AND p1.ad_creative = p4.ad_creative AND p1.country_code = p4.country_code AND p1.organic_type = p4.organic_type
LEFT JOIN NewDeviceKPI p5 ON p1.date_range = p5.date_range AND p1.time_dimension = p5.time_dimension AND p1.media_source = p5.media_source AND p1.campaign = p5.campaign AND p1.ad_creative = p5.ad_creative AND p1.country_code = p5.country_code AND p1.organic_type = p5.organic_type

