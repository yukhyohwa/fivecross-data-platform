/*
================================================================================
Game    : Crayon Shin-chan (蜡笔小新) - TC 繁体大区
Table   : ta.v_event_18, user_result_cluster_18
Report  : 台湾小新 每日新增用户 (NUU) 水账号占比与识别统计 (Daily NUU Water User Ratio)
Rule    : 基于 user_result_cluster_18 的 fixed_regdate 确立玩家创角注册日期。
          基于 user_result_cluster_18 的 fixed_deviceid 标签，判定全时间段内单一设备下 
          new_role 创角账号数 > 50 的账号为水账号。
          按 fixed_regdate (每日) 统计：总新增用户数、水账号新增数、正常新增数及水账号占比。
时间宏  : 支持数数后台时间筛选宏 ${PartDate:date1} (动态可选参数)
================================================================================
*/

WITH ScanConfig AS (
    -- 1. 时间窗口配置 (动态解析数数后台 ${PartDate:date1})
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_18
    WHERE ${PartDate:date1}
),

-- 2. 获取玩家固化标签：注册日期 (fixed_regdate) 及固定设备 ID (fixed_deviceid)
UserProfileDetail AS (
    SELECT 
        "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid
    FROM user_result_cluster_18
    WHERE cluster_name IN ('fixed_regdate', 'fixed_deviceid')
    GROUP BY "#user_id"
),

-- 3. 识别全时间段水设备：单一 fixed_deviceid 下 new_role 创角账号数 > 50
WaterDevices AS (
    SELECT 
        u.fixed_deviceid
    FROM ta.v_event_18 v
    INNER JOIN UserProfileDetail u 
        ON v."#user_id" = u."#user_id"
    WHERE v."$part_event" = 'new_role'
      AND u.fixed_deviceid IS NOT NULL 
      AND u.fixed_deviceid <> ''
    GROUP BY u.fixed_deviceid
    HAVING COUNT(DISTINCT COALESCE(NULLIF(CAST(v."#account_id" AS VARCHAR), ''), CAST(v."#user_id" AS VARCHAR))) > 50
),

-- 4. 圈定水账号集合 (包含静态黑名单 is_water/is_windows 及水设备关联账号)
WaterUsers AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_windows', 'is_water', 'internal_users')

    UNION

    SELECT DISTINCT u."#user_id"
    FROM UserProfileDetail u
    INNER JOIN WaterDevices wd 
        ON u.fixed_deviceid = wd.fixed_deviceid
),

-- 5. 以 user_result_cluster_18 的 fixed_regdate 为准，圈定选定时间范围内的每日新增用户 (NUU)
DailyNewUsers AS (
    SELECT
        u."#user_id",
        u.fixed_regdate AS reg_date,
        CASE WHEN w."#user_id" IS NOT NULL THEN 1 ELSE 0 END AS is_water_user
    FROM UserProfileDetail u
    CROSS JOIN ScanConfig sc
    LEFT JOIN WaterUsers w 
        ON u."#user_id" = w."#user_id"
    WHERE u.fixed_regdate >= CAST(sc.target_start_date AS VARCHAR)
      AND u.fixed_regdate <= CAST(sc.target_end_date AS VARCHAR)
)

-- 6. 按每日注册日期 (fixed_regdate) 汇总输出
SELECT
    reg_date                                                                       AS "注册日期",
    COUNT(DISTINCT "#user_id")                                                     AS "总新增用户数(NUU)",
    COUNT(DISTINCT CASE WHEN is_water_user = 1 THEN "#user_id" END)               AS "水账号新增数",
    COUNT(DISTINCT CASE WHEN is_water_user = 0 THEN "#user_id" END)               AS "正常新增用户数",
    CONCAT(
        CAST(
            ROUND(
                COUNT(DISTINCT CASE WHEN is_water_user = 1 THEN "#user_id" END) * 100.0 / NULLIF(COUNT(DISTINCT "#user_id"), 0), 
                2
            ) AS VARCHAR
        ), 
        '%'
    ) AS "水账号占比"
FROM DailyNewUsers
GROUP BY reg_date
ORDER BY reg_date ASC;
