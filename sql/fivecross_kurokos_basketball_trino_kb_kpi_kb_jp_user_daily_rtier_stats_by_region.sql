/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 黑子JP 每日分区域登录人数
             自定义时间范围内的活跃用户按最新登录区域进行分类统计。
================================================================================
*/

WITH 
-------------------------------------------------------
-- 1. 黑名单逻辑
-------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 每日登录用户 (自定义时间范围)
-------------------------------------------------------
DailyLogins AS (
    SELECT 
        s1."$part_date" AS log_date,
        s1.uuid
    FROM ta.v_event_9 s1
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_event" = 'login'
      AND ${PartDate:date1}
      AND b."#user_id" IS NULL
      AND s1.uuid IS NOT NULL AND s1.uuid <> ''
    GROUP BY 1, 2
),

-------------------------------------------------------
-- 3. 获取每个用户最新的区域
-------------------------------------------------------
UserLatestRegion AS (
    SELECT 
        uuid,
        CASE WHEN "#country"='日本' THEN "#city" ELSE '其他国家' END AS region
    FROM (
        SELECT 
            s.uuid, 
            s."#country", 
            s."#city",
            ROW_NUMBER() OVER(PARTITION BY s.uuid ORDER BY s."#time" DESC) as rn
        FROM ta.v_event_9 s
        INNER JOIN (SELECT DISTINCT uuid FROM DailyLogins) u ON s.uuid = u.uuid
        WHERE s."$part_event" = 'login'
    ) 
    WHERE rn = 1
)

-------------------------------------------------------
-- 4. 输出结果，按日期和区域汇聚
-------------------------------------------------------
SELECT 
    t.log_date AS "日期",
    COALESCE(r.region, '其他国家') AS "区域",
    COUNT(DISTINCT t.uuid) AS "总登录人数"
FROM DailyLogins t
LEFT JOIN UserLatestRegion r ON t.uuid = r.uuid
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
