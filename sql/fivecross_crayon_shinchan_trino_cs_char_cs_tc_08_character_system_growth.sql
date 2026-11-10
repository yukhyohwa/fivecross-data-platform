/*
================================================================================
项目名称 : 小新台湾 (Crayon Shin-chan TW) CBT 测试首周报告
模块编号 : 08 - 角色与全系统养成深度对比 (TW CBT vs SG CBT/OBT)
数据表   : 
  - 小新繁体 CBT: ta.v_event_18 (AppID 18)
  - 小新新加坡  : ta.v_event_13 (AppID 13)
核心逻辑 :
  - 统计技能升级 (skill_up)、坐骑升级 (mount_levup)、玩具升级 (toy_up)、马赛克升级 (mosaic_up)、好友养成 (friend_up) 等系统养成频次与覆盖率
================================================================================
*/

WITH ScanConfig AS (
    SELECT
        DATE '{{START_DATE}}' AS tw_start_date,
        DATE '{{END_DATE}}' AS tw_end_date
),

-- 1. 小新繁体 CBT 养成日志 (v_event_18)
TW_Growth AS (
    SELECT
        '1.小新繁体CBT' AS cohort_name,
        e."#user_id" AS user_id,
        CASE
            WHEN e."$part_event" = 'skill_up' THEN '01. 技能升级'
            WHEN e."$part_event" = 'mount_levup' THEN '02. 坐骑进阶'
            WHEN e."$part_event" = 'toy_up' THEN '03. 玩具养成'
            WHEN e."$part_event" = 'mosaic_up' THEN '04. 马赛克升级'
            WHEN e."$part_event" = 'friend_up' THEN '05. 好友养成'
            WHEN e."$part_event" = 'equip_dress' THEN '06. 装备穿戴/强化'
            ELSE e."$part_event"
        END AS growth_system
    FROM ta.v_event_18 e
    CROSS JOIN ScanConfig sc
    WHERE e."$part_date" BETWEEN CAST(sc.tw_start_date AS VARCHAR) AND CAST(sc.tw_end_date AS VARCHAR)
      AND e."$part_event" IN ('skill_up', 'mount_levup', 'toy_up', 'mosaic_up', 'friend_up', 'equip_dress')
),

-- 2. 新加坡 CBT 养成日志 (v_event_13)
SG_Growth AS (
    SELECT
        '2.小新新加坡OBT1' AS cohort_name,
        e."#user_id" AS user_id,
        CASE
            WHEN e."$part_event" = 'skill_up' THEN '01. 技能升级'
            WHEN e."$part_event" = 'mount_levup' THEN '02. 坐骑进阶'
            WHEN e."$part_event" = 'toy_up' THEN '03. 玩具养成'
            WHEN e."$part_event" = 'mosaic_up' THEN '04. 马赛克升级'
            WHEN e."$part_event" = 'friend_up' THEN '05. 好友养成'
            WHEN e."$part_event" = 'equip_dress' THEN '06. 装备穿戴/强化'
            ELSE e."$part_event"
        END AS growth_system
    FROM ta.v_event_13 e
    WHERE e."$part_date" BETWEEN '2026-05-08' AND '2026-05-14'
      AND e."$part_event" IN ('skill_up', 'mount_levup', 'toy_up', 'mosaic_up', 'friend_up', 'equip_dress')
),

CombinedGrowth AS (
    SELECT * FROM TW_Growth
    UNION ALL
    SELECT * FROM SG_Growth
)

SELECT
    cohort_name AS "对比组",
    growth_system AS "养成系统",
    COUNT(DISTINCT user_id) AS "养成参与人数",
    COUNT(1) AS "累计养成次数",
    ROUND(COUNT(1) * 1.0 / NULLIF(COUNT(DISTINCT user_id), 0), 2) AS "人均养成深度(次)"
FROM CombinedGrowth
GROUP BY cohort_name, growth_system
ORDER BY "对比组", "养成系统"
