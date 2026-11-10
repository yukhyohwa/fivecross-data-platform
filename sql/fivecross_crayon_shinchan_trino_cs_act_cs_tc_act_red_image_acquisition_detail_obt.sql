WITH NewRole AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v.role_name AS VARCHAR) AS new_role_name
    FROM ta.v_event_18 v
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" BETWEEN '2026-10-14' AND '2026-11-03'
      AND CAST(v."#event_time" AS TIMESTAMP)
            < TIMESTAMP '2026-11-03 22:00:00'
),

RedImageGains AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(u.item_id AS BIGINT) AS item_id,
        CAST(u.item_name AS VARCHAR) AS item_name,
        SUM(
            TRY_CAST(u.item_after AS BIGINT)
          - TRY_CAST(u.item_before AS BIGINT)
        ) AS image_count
    FROM ta.v_event_18 v
    CROSS JOIN UNNEST(v.a_rst) AS u(
        item_after,
        item_before,
        item_diff,
        item_id,
        item_key,
        item_name
    )
    WHERE v."$part_event" = 'item_change'
      AND v."$part_date" BETWEEN '2026-10-14' AND '2026-11-03'
      AND CAST(v."#event_time" AS TIMESTAMP)
            < TIMESTAMP '2026-11-03 22:00:00'
      AND CAST(u.item_id AS BIGINT) IN (
          110033, 110034, 110035, 110036,
          110037, 110038, 110039, 110040,
          110041, 110042, 110043, 110044,
          110045, 110046, 110047, 110048,
          120019, 120020,
          170001, 170002
      )
      AND TRY_CAST(u.item_after AS BIGINT)
          > TRY_CAST(u.item_before AS BIGINT)
    GROUP BY 1, 2, 3, 4
)

SELECT
    g.role_id AS "角色ID",
    r.new_role_name AS "创建角色时名称",
    g.fc_id AS "fc_id",
    g.item_id AS "红色影像ID",
    g.item_name AS "红色影像",
    g.image_count AS "获得个数"
FROM RedImageGains g
LEFT JOIN NewRole r
  ON g.role_id = r.role_id
 AND g.fc_id = r.fc_id
WHERE g.image_count > 0
ORDER BY g.image_count DESC, g.role_id, g.item_id;
