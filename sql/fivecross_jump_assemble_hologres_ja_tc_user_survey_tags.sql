WITH
UserTags AS (
    SELECT
        TRIM(lid) AS lid,
        MAX(ip_fan_segment) AS ip_fan_segment,
        MAX(game_skill_tier) AS game_skill_tier,
        MAX(net_issue_flag) AS net_issue_flag,
        MAX(device_issue_flag) AS device_issue_flag,
        MAX(satisfaction_trend) AS satisfaction_trend
    FROM (
        SELECT day, lid, tid, qid, RIGHT(TRIM(qid),3) AS real_qid, answerraw,
        -- 1. IP 粉丝标签
        CASE
            WHEN tid = '0006500200739' AND answerraw = '至少有一部動畫/漫畫作品追到最新劇情，且會主動關注/搜尋/了解該作品的資訊' THEN 'Core_IP_Fans'
            WHEN tid = '0006500200739' AND answerraw = '看過其中至少一部動畫/漫畫作品，但不會主動去關注/搜尋/了解該作品的資訊' THEN 'Casual_Viewers'
            WHEN tid = '0006500200739' AND answerraw = '對上述作品都不了解，動畫/漫畫都沒看過' THEN 'Non-IP_Users'
        END AS ip_fan_segment,
        -- 2. 游戏段位标签
        CASE
            WHEN tid = '0006500200739' AND answerraw IN ('大師以上（含排行榜）','大師','傳奇','神話') THEN 'High-Tier_Competitors'
            WHEN tid = '0006500200739' AND answerraw IN ('鑽石','黃金','白銀','青銅') THEN 'Mid-Tier_Competitors'
            WHEN tid = '0006500200739' AND answerraw IN ('近半年我沒有打排位，只玩一般對戰或娛樂模式','近半年沒有玩過競技類型遊戲','我沒玩過競技類型遊戲','不記得了') THEN 'Casual/Non-Competitors'
        END AS game_skill_tier,
        -- 3. 网络卡顿标记 (Yes/No)
        CASE
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') AND answerraw IN ('網路狀況不佳，有延遲','網路延遲、斷線情況嚴重','網路很卡，经常延遲') THEN 'Yes'
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') THEN 'No'
            ELSE NULL
        END AS net_issue_flag,
        -- 4. 设备卡顿标记 (Yes/No)
        CASE
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') AND answerraw IN ('手機過熱、掉幀等性能問題比較嚴重','手機過熱、掉幀、卡頓等情況較嚴重','發熱、掉幀等性能問題比較嚴重','對戰時掉幀/幀率低，畫面卡頓') THEN 'Yes'
            WHEN tid IN ('0006500200740','0006500200741','0006500200743') THEN 'No'
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
UserRetention AS (
    SELECT
        s1.lid,
        ARRAY_AGG( (s1.login_date - s2.reg_date)::INT ORDER BY s1.login_date ASC ) AS return_days_array
    FROM UserLogdate_Detail s1
    LEFT JOIN UserRegdate s2 ON s1.lid = s2.lid
    WHERE s2.reg_date IS NOT NULL
    AND s2.day BETWEEN 20251125 AND 20251128
    GROUP BY 1
),
-- 【新增】 获取dena_id和lid的映射关系
DenaIdMapping AS (
    SELECT
        did AS dena_id,
        lcm_id AS lid
    FROM dm_platform.lcx_user_info
    WHERE day >= 20231204
    AND app_id = '65002007'
    AND lcm_id IS NOT NULL
    GROUP BY did, lcm_id
)
-- 最终查询: 输出每个lid的标签和留存情况
SELECT
    m.dena_id,
    t.lid,
    t.ip_fan_segment,
    t.game_skill_tier,
    t.net_issue_flag,
    t.device_issue_flag,
    t.satisfaction_trend,
    r.return_days_array AS retention_list,
    CASE WHEN 1 = ANY(r.return_days_array) THEN 'Yes' ELSE 'No' END AS is_retained_on_d2,
    CASE WHEN 2 = ANY(r.return_days_array) THEN 'Yes' ELSE 'No' END AS is_retained_on_d3
FROM UserTags t
LEFT JOIN UserRetention r ON t.lid = r.lid
LEFT JOIN DenaIdMapping m ON t.lid = m.lid -- 【新增】 关联dena_id
ORDER BY m.dena_id, t.lid;