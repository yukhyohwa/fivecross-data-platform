/*
================================================================================
项目：蜡笔小新 - 新老用户广告点击偏好与收益对比
描述：
  1. 统计日期：2026年5月8日 - 2026年5月11日
  2. 统计维度：注册时间 + 事件时间（每天）
  3. 统计指标：该分群的DAU、成功看广告的人数、成功看广告的次数、产生的广告收入。
备注：包含内部及Windows测试账号的黑名单过滤。通过 new_role 提取注册时间。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 获取 5月8日-5月11日 期间的所有活跃用户（DAU 基础盘）
DAU_Base AS (
    SELECT 
        "$part_date" AS event_date, 
        "#user_id"
    FROM ta.v_event_13
    WHERE "$part_date" BETWEEN '2026-05-08' AND '2026-05-11'
    AND  "$part_event" IN ('login','new_role')
    GROUP BY "$part_date", "#user_id"
),

-- 2. 查找这些活跃用户的注册时间（以 new_role 事件为准）
User_Reg AS (
    SELECT 
        v."#distinct_id", "#user_id",
        MIN(v."$part_date") AS reg_date
    FROM ta.v_event_13 v
 --   JOIN (SELECT DISTINCT "#user_id" FROM DAU_Base) d ON v."#user_id" = d."#user_id"
    WHERE v."$part_event" = 'new_role'
    GROUP BY 1,2
),

-- 3. 统计这几天里，每天每个用户的广告观看情况（用 distinct_id 关联）
Ad_Stats AS (
    SELECT 
        v."$part_date" AS event_date,
        ur."#user_id",
        COUNT(CASE WHEN CAST(v.status AS INTEGER) = 1 THEN 1 END) AS ad_views,
        SUM(CASE WHEN CAST(v.status AS INTEGER) = 1 THEN
                CASE WHEN v."#os"='Android' THEN CAST(v.value AS DOUBLE)/1000 ELSE CAST(v.value AS DOUBLE) END 
            ELSE 0.0 END) AS ad_revenue
    FROM ta.v_event_13 v
    JOIN User_Reg ur ON v."#distinct_id" = ur."#distinct_id"
    WHERE v."$part_date" BETWEEN '2026-05-08' AND '2026-05-11'
      AND v."$part_event" = 'game_ad_impression'
    GROUP BY 1,2
)

-- 4. 汇总输出
SELECT 
    COALESCE(r.reg_date, '早期注册/无日志') AS "用户注册时间",
    d.event_date AS "事件发生时间(活跃日)",
    
    COUNT(DISTINCT d."#user_id") AS "该群组活跃人数(DAU)",
    COUNT(DISTINCT CASE WHEN a.ad_views > 0 THEN a."#user_id" END) AS "成功看广告人数",
    
    -- 渗透率辅助列（可选）
    ROUND(CAST(COUNT(DISTINCT CASE WHEN a.ad_views > 0 THEN a."#user_id" END) AS DOUBLE) 
          / NULLIF(COUNT(DISTINCT d."#user_id"), 0), 4) AS "看广告人数占比",
          
    COALESCE(SUM(a.ad_views), 0) AS "成功看广告总次数",
    
    -- 人均广告次数
    ROUND(CAST(COALESCE(SUM(a.ad_views), 0) AS DOUBLE) 
          / NULLIF(COUNT(DISTINCT CASE WHEN a.ad_views > 0 THEN a."#user_id" END), 0), 2) AS "看广告者人均次数",
          
    ROUND(COALESCE(SUM(a.ad_revenue), 0.0), 4) AS "广告收入(USD)"
    
FROM DAU_Base d
LEFT JOIN UserBlacklist ub ON d."#user_id" = ub."#user_id"
LEFT JOIN User_Reg r ON d."#user_id" = r."#user_id"
LEFT JOIN Ad_Stats a ON d.event_date = a.event_date AND d."#user_id" = a."#user_id"
WHERE ub."#user_id" IS NULL
GROUP BY 
    COALESCE(r.reg_date, '早期注册/无日志'),
    d.event_date
ORDER BY 
    d.event_date DESC,
    COALESCE(r.reg_date, '早期注册/无日志') DESC;
