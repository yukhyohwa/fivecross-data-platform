/*
================================================================================
Game: Saint Seiya 2 (SS2) - GL
Description: Active Paying User Composition (週期內付費用戶構成).
             Analyzes users who made a purchase during the selected period, 
             categorized by how many days after registration they made this purchase.
             Includes dimensions: Time, OS, Country, Affcode, Store.
Environment: Trino
Table: ta.v_event_19
================================================================================
*/

WITH IdentifiedEvents AS (
    SELECT 
        v.*,
        CASE 
            WHEN 
               applicationid IN ('23000113','seiya30tw') 
            OR productid IN ('23000113','seiya30tw') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('23000113')
            OR substring(affcode, -8) IN ('23000113') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('23000113','seiya30tw')
            THEN 'Saint Seiya (TC)' 
            WHEN 
               applicationid IN ('60000001') 
            OR productid IN ('60000001') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('60000001')
            OR substring(affcode, -8) IN ('60000001') 
            OR regexp_extract(JSON_EXTRACT_SCALAR(CAST(payload AS JSON), '$.productid'), 'g(\d+)', 1) IN ('60000001')
            THEN 'Saint Seiya (SEA)' 
            WHEN 
               applicationid IN ('65002004') 
            OR productid IN ('65002004') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002004')
            OR substring(affcode, -8) IN ('65002004') 
            OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('65002004')
            THEN 'Three Kingdoms' 
            WHEN 
               applicationid IN ('65002005') 
            OR productid IN ('65002005') 
            OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('65002005')
            OR substring(affcode, -8) IN ('65002005') 
            OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('65002005')
            THEN 'Captain Tsubasa' 
            ELSE 'UNKNOWN' 
        END AS game_name
    FROM ta.v_event_19 v
    WHERE ${PartDate:date1}
),

TargetGameEvents AS (
    SELECT *
    FROM IdentifiedEvents
    WHERE game_name IN ('Saint Seiya (TC)','Saint Seiya (SEA)' )
),

-- 1. [性能優化] 自動計算掃描邊界
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM TargetGameEvents
    WHERE "$part_event" IN ('NUU', 'LOGIN_SUCCESS')
),

-- 2. 黑名單用戶
UserBlacklist AS (
    SELECT 
       DISTINCT  "#varchar_id" AS "#account_id"
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('is_water', 'internal_users')
),

-- 3. 用戶屬性 (獲取註冊日期及維度)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_19 
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 4. 提取付費用戶及其充值事件
PeriodPayingUsers AS (
    SELECT 
        v."#account_id",
        CAST(v."$part_date" AS DATE) AS pay_date,
        DATE_DIFF('day', CAST(up.fixed_regdate AS DATE), CAST(v."$part_date" AS DATE)) AS days_since_reg,
        up.fixed_os,
        up.fixed_country,
        up.fixed_affcode,
        up.fixed_store
    FROM TargetGameEvents v
    INNER JOIN UserProfileDetail up ON v."#account_id" = up."#account_id"
    CROSS JOIN ScanConfig sc
    LEFT JOIN UserBlacklist ub ON v."#account_id" = ub."#account_id"
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'PURCHASE'
      AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype') <> 'SANDBOX_RECEIPT'
      AND ub."#account_id" IS NULL
),

-- 5. 分組標籤定義
PayingComposition AS (
    SELECT 
        *,
        CASE 
            WHEN days_since_reg = 0 THEN 'a. D0付費'
            WHEN days_since_reg BETWEEN 1 AND 3 THEN 'b. D1-D3付費'
            WHEN days_since_reg BETWEEN 4 AND 7 THEN 'c. D4-D7付費'
            WHEN days_since_reg BETWEEN 8 AND 14 THEN 'd. D8-D14付費'
            WHEN days_since_reg BETWEEN 15 AND 30 THEN 'e. D15-D30付費'
            WHEN days_since_reg BETWEEN 31 AND 90 THEN 'f. D31-D90付費'
            ELSE 'g. D91+付費'
        END AS paying_user_type
    FROM PeriodPayingUsers
)

-- 6. 最終彙總報表
SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', pay_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', pay_date) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', pay_date) AS VARCHAR)
        ELSE '已合併'
    END AS time_dimension,
    CASE WHEN ${Selector:ostype} THEN fixed_os ELSE '已合併' END AS os_type,
    CASE WHEN ${Selector:country} THEN fixed_country ELSE '已合併' END AS country, 
    CASE WHEN ${Selector:affcode} THEN fixed_affcode ELSE '已合併' END AS affcode,
    CASE WHEN ${Selector:store} THEN fixed_store ELSE '已合併' END AS store,
    paying_user_type AS "付費用戶構成",
    COUNT(DISTINCT "#account_id") AS "付費人數"
FROM PayingComposition
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1 DESC, 6 ASC;
