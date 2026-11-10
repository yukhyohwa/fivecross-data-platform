-- ================================================================================
-- 游戏: 灌篮高手 (Slam Dunk)
-- 区域: 全球版 (Global)
-- 描述: 2020年各区域每日DAU统计
-- 引擎: MaxCompute (ODPS)
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

-- 查询2020年全球版各区域每日DAU
SELECT 
    a.day,
    CASE 
        WHEN SUBSTR(b.zone_id, 1, 1) = '1' THEN '東南亞'
        WHEN SUBSTR(b.zone_id, 1, 1) = '2' THEN '歐洲'
        WHEN SUBSTR(b.zone_id, 1, 1) = '3' THEN '南美'
        WHEN SUBSTR(b.zone_id, 1, 1) = '4' THEN '北美'
        ELSE '其他'
    END AS region,
    COUNT(DISTINCT a.lcm_id) AS dau
FROM 
    (
        -- 获取2020年的日活用户
        SELECT 
            day,
            lcm_id
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 63002013
          AND day >= 20200101
          AND day < 20210101
    ) AS a
JOIN 
    (
        -- 获取用户所属区域（使用最早的区域记录）
        SELECT 
            mbga_uid,
            MIN(zone) AS zone_id
        FROM g63002013.daily_user_snapshot
        WHERE day >= 20200101
        GROUP BY mbga_uid
    ) AS b
ON a.lcm_id = b.mbga_uid
GROUP BY 
    a.day,
    CASE 
        WHEN SUBSTR(b.zone_id, 1, 1) = '1' THEN '東南亞'
        WHEN SUBSTR(b.zone_id, 1, 1) = '2' THEN '歐洲'
        WHEN SUBSTR(b.zone_id, 1, 1) = '3' THEN '南美'
        WHEN SUBSTR(b.zone_id, 1, 1) = '4' THEN '北美'
        ELSE '其他'
    END
ORDER BY 
    a.day ASC,
    region;
