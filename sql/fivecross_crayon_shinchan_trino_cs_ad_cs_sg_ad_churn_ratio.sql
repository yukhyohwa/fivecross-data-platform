/*
================================================================================
项目：蜡笔小新 - 5月8日新用户且5月9日流失队列的广告观看比例
描述：
  1. 目标队列：5月8日的新用户（基于 new_role 事件的 distinct_id），且在 5月9日 未产生任何事件（流失）。
  2. 分析维度：这批流失用户在 5月8日 观看过广告 vs 未观看过广告的占比。
  3. 标识标准：直接使用 #distinct_id。
================================================================================
*/

-- 1. 获取 5月8日 新用户
WITH NewUsers AS (
    SELECT DISTINCT "#distinct_id"
    FROM ta.v_event_13
    WHERE "$part_date" = '2026-05-08'
      AND "$part_event" = 'new_role'
),

-- 2. 获取 5月8日 每个用户的最终等级 (取带有 role_lev 的最后一条记录)
UserLevel AS (
    SELECT 
        "#distinct_id",
        CASE 
            WHEN last_lev IS NULL THEN '未知/无等级记录'
            WHEN CAST(last_lev AS INTEGER) < 10 THEN '1-9'
            WHEN CAST(last_lev AS INTEGER) <= 15 THEN '10-15'
            ELSE '16及以上'
        END AS level_group,
        CASE 
            WHEN last_lev IS NULL THEN -1
            WHEN CAST(last_lev AS INTEGER) < 10 THEN 0
            WHEN CAST(last_lev AS INTEGER) <= 15 THEN 10
            ELSE 16
        END AS level_group_sort
    FROM (
        SELECT 
            "#distinct_id",
            MAX_BY(role_lev, "#event_time") AS last_lev
        FROM ta.v_event_13
        WHERE "$part_date" = '2026-05-08'
          AND role_lev IS NOT NULL
        GROUP BY "#distinct_id"
    ) t
),

-- 3. 获取 5月9日 有活跃的用户
D2_Active AS (
    SELECT DISTINCT "#distinct_id"
    FROM ta.v_event_13
    WHERE "$part_date" = '2026-05-09'
),

-- 4. 获取 5月8日 看过广告的用户
AdUsers AS (
    SELECT DISTINCT "#distinct_id"
    FROM ta.v_event_13
    WHERE "$part_date" = '2026-05-08'
      AND "$part_event" = 'game_ad_impression'
      AND CAST(status AS INTEGER) = 1  -- 状态为1代表成功观看
)

-- 5. 统计新增、流失、流失率以及流失占比
SELECT 
    COALESCE(l.level_group, '未知/无等级记录') AS "等级段(10级一组)",
    CASE WHEN a."#distinct_id" IS NOT NULL THEN '5月8日点过广告' ELSE '5月8日没点过广告' END AS "广告观看情况",
    COUNT(n."#distinct_id") AS "5月8日新用户数",
    COUNT(CASE WHEN d."#distinct_id" IS NULL THEN n."#distinct_id" END) AS "流失人数",
    CAST(ROUND(CAST(COUNT(CASE WHEN d."#distinct_id" IS NULL THEN n."#distinct_id" END) AS DOUBLE) / NULLIF(COUNT(n."#distinct_id"), 0) * 100, 2) AS VARCHAR) || '%' AS "流失率",
    CAST(ROUND(CAST(COUNT(CASE WHEN d."#distinct_id" IS NULL THEN n."#distinct_id" END) AS DOUBLE) / NULLIF(SUM(COUNT(CASE WHEN d."#distinct_id" IS NULL THEN n."#distinct_id" END)) OVER (PARTITION BY COALESCE(l.level_group, '未知/无等级记录')), 0) * 100, 2) AS VARCHAR) || '%' AS "该等级段内流失占比"
FROM NewUsers n
LEFT JOIN UserLevel l ON n."#distinct_id" = l."#distinct_id"
LEFT JOIN D2_Active d ON n."#distinct_id" = d."#distinct_id"
LEFT JOIN AdUsers a ON n."#distinct_id" = a."#distinct_id"
GROUP BY 
    COALESCE(l.level_group, '未知/无等级记录'),
    COALESCE(l.level_group_sort, -1),
    CASE WHEN a."#distinct_id" IS NOT NULL THEN '5月8日点过广告' ELSE '5月8日没点过广告' END
ORDER BY 
    COALESCE(l.level_group_sort, -1) DESC,
    "广告观看情况";
