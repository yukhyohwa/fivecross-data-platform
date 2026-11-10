/*
繁中 App18 OBT｜分服每日活跃。
${PartDate:date1}：开服记录筛选范围；${PartDate:date2}：活跃日期范围。
开服时间取 date1 范围内该服最早的有效 new_role 日期。
注意：仅靠范围内 new_role 无法区分旧服新增角色与真正新开服务器；
本查询不额外读取范围外历史，也不将此日期声明为运营配置开服日期。
活跃为同日同服 login/new_role 的 fc_id 去重数，不要求账号存在注册记录。
沿用参考黑名单：is_water_new、is_windows_new。不补无事件日期。
*/
WITH
Servers AS (
    SELECT
        TRIM(CAST(v.server_id AS VARCHAR)) AS server_id,
        MIN(CAST(v."$part_date" AS DATE)) AS open_date
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date1}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'new_role'
      AND NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM user_result_cluster_18 b
          WHERE b.cluster_name IN ('is_water_new', 'is_windows_new')
            AND TRIM(CAST(b."#varchar_id" AS VARCHAR)) = TRIM(CAST(v.fc_id AS VARCHAR))
      )
    GROUP BY 1
),
DailyActive AS (
    SELECT
        TRIM(CAST(v.server_id AS VARCHAR)) AS server_id,
        CAST(v."$part_date" AS DATE) AS active_date,
        COUNT(DISTINCT TRIM(CAST(v.fc_id AS VARCHAR))) AS active_users
    FROM ta.v_event_18 v
    WHERE v.${PartDate:date2}
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v.server_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM user_result_cluster_18 b
          WHERE b.cluster_name IN ('is_water_new', 'is_windows_new')
            AND TRIM(CAST(b."#varchar_id" AS VARCHAR)) = TRIM(CAST(v.fc_id AS VARCHAR))
      )
    GROUP BY 1, 2
)
SELECT
    s.server_id,
    s.open_date AS "开服时间",
    a.active_date AS "活跃日期",
    a.active_users AS "活跃人数"
FROM Servers s
JOIN DailyActive a ON s.server_id = a.server_id
ORDER BY a.active_date DESC, s.open_date, s.server_id;
