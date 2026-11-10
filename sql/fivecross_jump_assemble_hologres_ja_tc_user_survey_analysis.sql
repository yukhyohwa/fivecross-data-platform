WITH UserTags AS (
SELECT TRIM(lid) lid,
MAX(ip_fan_segment) AS ip_fan_segment,
MAX(game_skill_tier) AS game_skill_tier

FROM (

SELECT day,lid,tid,qid,RIGHT(TRIM(qid),3) real_qid,answerraw,
CASE 
WHEN answerraw = '至少有一部動畫/漫畫作品追到最新劇情，且會主動關注/搜尋/了解該作品的資訊' THEN 'Core_IP_Fans'
WHEN answerraw = '看過其中至少一部動畫/漫畫作品，但不會主動去關注/搜尋/了解該作品的資訊' THEN 'Casual_Viewers'
WHEN answerraw = '對上述作品都不了解，動畫/漫畫都沒看過'  THEN 'Non-IP_Users'
END ip_fan_segment,
CASE
WHEN answerraw IN ('大師以上（含排行榜）','大師','傳奇','神話') THEN 'High-Tier_Competitors'
WHEN answerraw IN ('鑽石','黃金','白銀','青銅') THEN 'Mid-Tier_Competitors'
WHEN answerraw IN ('近半年我沒有打排位，只玩一般對戰或娛樂模式','近半年沒有玩過競技類型遊戲','我沒玩過競技類型遊戲','不記得了') THEN 'Casual/Non-Competitors'
END game_skill_tier

FROM dm_platform.wj_option_2
WHERE tid = '0006500200739' 
AND day BETWEEN 20251125 AND 20251202
AND LENGTH(lid) = 36
) s

GROUP BY 1
),

UserRegdate AS (
    SELECT 
        s2.lid,
        MIN(s1.day) AS day,
        MIN(TO_DATE(s1.day::TEXT, 'YYYYMMDD')) AS reg_date
    FROM g65002007.lcx_user_login s1
    INNER JOIN UserTags s2 ON s1.lcm_id = s2.lid
    WHERE s1.day BETWEEN 20251124 AND 20251128
    GROUP BY lid
),


--- RR-- 
UserLogdate_Detail AS (
    SELECT DISTINCT 
        s2.lid, 
        TO_DATE(s1.day::TEXT, 'YYYYMMDD') AS login_date
    FROM g65002007.lcx_user_login s1
    INNER JOIN UserTags s2 ON s1.lcm_id = s2.lid
    WHERE s1.day BETWEEN 20251125 AND 20251202
)


SELECT ip_fan_segment,game_skill_tier,
    COUNT(TRIM(p1.lid)) FILTER (WHERE 0 = ANY(return_days_array)) AS rr_0,
    COUNT(TRIM(p1.lid)) FILTER (WHERE 1 = ANY(return_days_array)) AS rr_1,
    COUNT(TRIM(p1.lid)) FILTER (WHERE 2 = ANY(return_days_array)) AS rr_2,
    COUNT(TRIM(p1.lid)) FILTER (WHERE 3 = ANY(return_days_array)) AS rr_3
FROM (
SELECT 
    s1.lid,
    ARRAY_AGG( (s1.login_date - s2.reg_date)::INT ORDER BY s1.login_date ASC ) AS return_days_array
FROM UserLogdate_Detail s1
LEFT JOIN UserRegdate s2 ON s1.lid = s2.lid
WHERE s2.reg_date IS NOT NULL 
AND s2.day BETWEEN 20251125 AND 20251128
GROUP BY 1
) p1

LEFT JOIN UserTags p2 ON TRIM(p1.lid) = TRIM(p2.lid)
GROUP BY 1,2 


----- LTV
RevenueBase AS (
    SELECT 
        c.lcm_id,
        (TO_DATE(c.day::TEXT, 'YYYYMMDD') - u.reg_date) AS day_diff,
        SUM(c.consume_amount) / 5.0 AS revenue_val
    FROM g65002007.lcx_user_consume c
    INNER JOIN UserRegdate u ON c.lcm_id = u.lid
    WHERE c.day >= 20251124 
    GROUP BY 1, 2
)



SELECT
    COALESCE(t.ip_fan_segment, 'Unknown') AS ip_fan_segment,
    COALESCE(t.game_skill_tier, 'Unknown') AS game_skill_tier,
    
    COUNT(DISTINCT TRIM(r.lid)) AS new_account,

    COALESCE(SUM(CASE WHEN rv.day_diff >=0 AND rv.day_diff < 1 THEN rv.revenue_val ELSE 0 END), 0) 
    / NULLIF(COUNT(DISTINCT TRIM(r.lid)), 0)::DOUBLE PRECISION AS ltv_1,
    COALESCE(SUM(CASE WHEN rv.day_diff >=0 AND rv.day_diff < 2 THEN rv.revenue_val ELSE 0 END), 0) 
    / NULLIF(COUNT(DISTINCT TRIM(r.lid)), 0)::DOUBLE PRECISION AS ltv_2,
    COALESCE(SUM(CASE WHEN rv.day_diff >=0 AND rv.day_diff < 3 THEN rv.revenue_val ELSE 0 END), 0) 
    / NULLIF(COUNT(DISTINCT TRIM(r.lid)), 0)::DOUBLE PRECISION AS ltv_3,
    COALESCE(SUM(CASE WHEN rv.day_diff >=0 AND rv.day_diff < 7 THEN rv.revenue_val ELSE 0 END), 0) 
    / NULLIF(COUNT(DISTINCT TRIM(r.lid)), 0)::DOUBLE PRECISION AS ltv_7

FROM UserRegdate r
LEFT JOIN UserTags t ON r.lid = t.lid
LEFT JOIN RevenueBase rv ON r.lid = rv.lcm_id
AND r.day BETWEEN 20251125 AND 20251128
AND TRIM(r.lid) <> '61e1949e-b680-49d2-8717-a9cabdf05864'
GROUP BY 1, 2
ORDER BY 1, 2;


----网络延迟


WITH InternetLagging AS (
SELECT DISTINCT TRIM(lid) lid
FROM dm_platform.wj_option_2
WHERE tid IN ('0006500200740','0006500200741','0006500200743')
AND day BETWEEN 20251125 AND 20251202
AND LENGTH(lid) = 36
AND answerraw IN ('網路狀況不佳，有延遲','網路延遲、斷線情況嚴重','網路很卡，經常延遲')
),
UserTags AS (
SELECT s1.lid,CASE WHEN s2.lid IS NULL THEN 'no_problem' ELSE 'internet_lagging' END user_tags
FROM (
SELECT DISTINCT TRIM(lid) lid
FROM dm_platform.wj_option_2
WHERE tid IN ('0006500200740','0006500200741','0006500200743')
AND day BETWEEN 20251125 AND 20251202
AND LENGTH(lid) = 36
) s1
LEFT JOIN InternetLagging s2 ON s1.LID = s2.lid
)

SELECT 
CASE WHEN s1.country_code IN ('CN','TW','HK') THEN country_code ELSE 'Others' END region_code,
s2.user_tags,
COUNT(DISTINCT TRIM(s1.lcm_id) ) num
FROM g65002007.lcx_user_info s1
INNER JOIN UserTags s2 ON TRIM(s1.lcm_id) = s2.lid
WHERE day BETWEEN 20251125 AND 20251202
GROUP BY 1,2



---手机卡顿

WITH DeviceLaggy AS (
SELECT DISTINCT TRIM(lid) lid
FROM dm_platform.wj_option_2
WHERE tid IN ('0006500200740','0006500200741','0006500200743')
AND day BETWEEN 20251125 AND 20251202
AND LENGTH(lid) = 36
AND answerraw IN (
'手機過熱、掉幀等性能問題比較嚴重',
'手機過熱、掉幀、卡頓等情況較嚴重',
'發熱、掉幀等性能問題比較嚴重',
'對戰時掉幀/幀率低，畫面卡頓')
),
UserTags AS (
SELECT s1.lid,CASE WHEN s2.lid IS NULL THEN 'no_problem' ELSE 'device_laggy' END user_tags
FROM (
SELECT DISTINCT TRIM(lid) lid
FROM dm_platform.wj_option_2
WHERE tid IN ('0006500200740','0006500200741','0006500200743')
AND day BETWEEN 20251125 AND 20251202
AND LENGTH(lid) = 36
) s1
LEFT JOIN DeviceLaggy s2 ON s1.LID = s2.lid
)


SELECT * -- device_model，os_version,manufacturer
FROM UserTags s1

---
WITH DeviceInfo AS (																									
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
    AND "#simulator" = false
)

SELECT "#account_id@user_tags",real_ram,COUNT(DISTINCT s2.lcx_id)
FROM ta_dim.dim_16_0_23614 s1
INNER JOIN DeviceInfo s2 ON s1."#account_id@lid" = s2.lcx_id 
GROUP BY 1,2


----- 用户标签流失

WITH UserTags AS (
SELECT 
        TRIM(lid) AS lid,
        MAX(ip_fan_segment) AS ip_fan_segment,
        MAX(game_skill_tier) AS game_skill_tier,

        -- 【修改点 1】: 直接用 MAX 即可。
        -- 逻辑：如果同时有 'Yes' 和 'No'，MAX('Yes', 'No') = 'Yes'。完美符合“有过卡顿就算卡顿”。
        MAX(net_issue_flag) AS net_issue_flag,
        MAX(device_issue_flag) AS device_issue_flag,
        
        -- 【修改点 2】: 满意度趋势直接取 MAX 聚合
        MAX(satisfaction_trend) AS satisfaction_trend

    FROM (
        SELECT day, lid, tid, qid, RIGHT(TRIM(qid),3) AS real_qid, answerraw,

        -- 1. IP 粉丝标签
        CASE 
            WHEN tid = '0006500200739' AND answerraw = '至少有一部動畫/漫畫作品追到最新劇情，且會主動關注/搜尋/了解該作品的資訊' THEN 'Core_IP_Fans'
            WHEN tid = '0006500200739' AND answerraw = '看過其中至少一部動畫/漫畫作品，但不會主動去關注/搜尋/了解該作品的資訊' THEN 'Casual_Viewers'
            WHEN tid = '0006500200739' AND answerraw = '對上述作品都不了解，動畫/漫畫都沒看過'  THEN 'Non-IP_Users'
        END AS ip_fan_segment,

        -- 2. 游戏段位标签
        CASE
            WHEN tid = '0006500200739' AND answerraw IN ('大師以上（含排行榜）','大師','傳奇','神話') THEN 'High-Tier_Competitors'
            WHEN tid = '0006500200739' AND answerraw IN ('鑽石','黃金','白銀','青銅') THEN 'Mid-Tier_Competitors'
            WHEN tid = '0006500200739' AND answerraw IN ('近半年我沒有打排位，只玩一般對戰或娛樂模式','近半年沒有玩過競技類型遊戲','我沒玩過競技類型遊戲','不記得了') THEN 'Casual/Non-Competitors' 
        END AS game_skill_tier,

        -- 3. 网络卡顿标记 (Yes/No)
        CASE
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') 
                 AND answerraw IN ('網路狀況不佳，有延遲','網路延遲、斷線情況嚴重','網路很卡，經常延遲') 
                 THEN 'Yes'  -- 只要命中，标记为 Yes
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') 
                 THEN 'No'   -- 回答了但没命中，标记为 No
            ELSE NULL        -- 没回答这些题目
        END AS net_issue_flag, 

        -- 4. 设备卡顿标记 (Yes/No)
        CASE
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') 
                 AND answerraw IN ('手機過熱、掉幀等性能問題比較嚴重','手機過熱、掉幀、卡頓等情況較嚴重','發熱、掉幀等性能問題比較嚴重','對戰時掉幀/幀率低，畫面卡頓') 
                 THEN 'Yes' 
            WHEN tid IN ('0006500200740','0006500200741','0006500200743')  
                 THEN 'No' 
            ELSE NULL
        END AS device_issue_flag,

        -- 5. 满意度趋势
        CASE
            WHEN tid = '0006500200741' AND answerraw = '滿意度有變高' THEN 'Satisfaction_Improved'
            WHEN tid = '0006500200741' AND answerraw = '沒變化' THEN 'Satisfaction_Stable'
            WHEN tid = '0006500200741' AND answerraw = '滿意度有變低' THEN 'Satisfaction_Declined'
            ELSE NULL
        END AS satisfaction_trend

        FROM dm_platform.wj_option_2
        WHERE tid IN ('0006500200739','0006500200740','0006500200741','0006500200743')
        AND day BETWEEN 20251125 AND 20251202
        AND LENGTH(lid) = 36
    ) s
    GROUP BY 1
),

UserRegdate AS (
    SELECT 
        s2.lid,
        MIN(country_code) AS country_code,
        MIN(s1.day) AS day,
        MIN(TO_DATE(s1.day::TEXT, 'YYYYMMDD')) AS reg_date
    FROM g65002007.lcx_user_login s1
    INNER JOIN UserTags s2 ON s1.lcm_id = s2.lid
    WHERE s1.day BETWEEN 20251124 AND 20251128
    GROUP BY lid
),

UserLogdate_Detail AS (
    SELECT DISTINCT 
        s2.lid, 
        TO_DATE(s1.day::TEXT, 'YYYYMMDD') AS login_date
    FROM g65002007.lcx_user_login s1
    INNER JOIN UserTags s2 ON s1.lcm_id = s2.lid
    WHERE s1.day BETWEEN 20251125 AND 20251202
),

-- 计算每个用户的留存天数数组
UserRetentionBase AS (
    SELECT 
        s1.lid,
        -- 生成数组，如 {0, 1, 3}
        ARRAY_AGG( (s1.login_date - s2.reg_date)::INT ORDER BY s1.login_date ASC ) AS return_days_array
    FROM UserLogdate_Detail s1
    LEFT JOIN UserRegdate s2 ON s1.lid = s2.lid
    WHERE s2.reg_date IS NOT NULL 
    AND s2.day BETWEEN 20251125 AND 20251128
    GROUP BY 1
    -- 这里先筛选出“必须有次留”的用户，减少后续计算量
    HAVING 1 = ANY(ARRAY_AGG( (s1.login_date - s2.reg_date)::INT ))
)

-- 问卷3
Questionnaire3 AS (
SELECT TRIM(lid) AS lid,title,answerraw
FROM dm_platform.wj_option_2
WHERE tid IN ('0006500200741')
AND day BETWEEN 20251125 AND 20251202
        AND LENGTH(lid) = 36
        AND RIGHT(TRIM(qid),3) = '102'
)




-- 最终查询：基于已次留用户，看三留情况
SELECT 
    p2.ip_fan_segment,
    p2.game_skill_tier,
    net_issue_flag,
    device_issue_flag,
    satisfaction_trend,
    -- 基数：所有次留用户 (Day 1 Retained Users)
    COUNT(TRIM(p1.lid)) AS base_d1_users,

    -------------------------------------------------------
    -- 分组 A: 次留用户中，三留流失 (有1，没3)
    -- 对应你描述的 "有1 没有2(指三留)"
    -------------------------------------------------------
    COUNT(TRIM(p1.lid)) FILTER (WHERE NOT (2 = ANY(return_days_array))) AS churn_at_d3_count,
    
    -------------------------------------------------------
    -- 分组 B: 次留用户中，三留留存 (有1，有3)
    -- 对应你描述的 "有1 有2(指三留)"
    -------------------------------------------------------
    COUNT(TRIM(p1.lid)) FILTER (WHERE 2 = ANY(return_days_array)) AS retained_at_d3_count

FROM UserRetentionBase p1
LEFT JOIN UserTags p2 ON TRIM(p1.lid) = TRIM(p2.lid)
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2;