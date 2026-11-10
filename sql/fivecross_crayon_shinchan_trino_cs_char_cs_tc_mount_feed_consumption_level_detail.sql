WITH NewRole AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v.role_name AS VARCHAR) AS new_role_name
    FROM ta.v_event_18 v
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" BETWEEN '2026-10-14' AND '2026-10-29'
),

SpringSpend AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        SUM(
            TRY_CAST(u.item_before AS BIGINT)
          - TRY_CAST(u.item_after AS BIGINT)
        ) AS spring_spent
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
      AND v."$part_date" BETWEEN '2026-10-26' AND '2026-10-29'
      AND CAST(v."#event_time" AS TIMESTAMP)
            >= TIMESTAMP '2026-10-26 20:30:00'
      AND CAST(v."#event_time" AS TIMESTAMP)
            < TIMESTAMP '2026-10-29 19:30:00'
      AND CAST(u.item_id AS BIGINT) = 10213
      AND TRY_CAST(u.item_before AS BIGINT)
          > TRY_CAST(u.item_after AS BIGINT)
      AND TRY_CAST(u.item_before AS BIGINT)
        - TRY_CAST(u.item_after AS BIGINT)
          = TRY_CAST(u.item_diff AS BIGINT)
    GROUP BY 1, 2
),

LastMountLevel AS (
    SELECT
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        TRY_CAST(v.mount_lev AS BIGINT) AS last_mount_level,
        ROW_NUMBER() OVER (
            PARTITION BY
                TRIM(CAST(v.fc_id AS VARCHAR)),
                CAST(v."#account_id" AS VARCHAR)
            ORDER BY
                CAST(v."#event_time" AS TIMESTAMP) DESC,
                CAST(v."#te_event_id" AS VARCHAR) DESC
        ) AS rn
    FROM ta.v_event_18 v
    WHERE v."$part_event" = 'mount_levup'
      AND v."$part_date" BETWEEN '2026-10-26' AND '2026-10-29'
      AND CAST(v."#event_time" AS TIMESTAMP)
            < TIMESTAMP '2026-10-29 19:30:00'
),

FinalLevel AS (
    SELECT *
    FROM LastMountLevel
    WHERE rn = 1
)

SELECT
    COALESCE(s.role_id, l.role_id) AS "角色ID",
    r.new_role_name AS "创建角色时名称",
    COALESCE(s.fc_id, l.fc_id) AS "fc_id",
    COALESCE(s.spring_spent, 0) AS "累计消耗发条数",
    l.last_mount_level AS "截至10月29日19:30最后等级"
FROM SpringSpend s
FULL OUTER JOIN FinalLevel l
  ON s.role_id = l.role_id
 AND s.fc_id = l.fc_id
LEFT JOIN NewRole r
  ON COALESCE(s.role_id, l.role_id) = r.role_id
 AND COALESCE(s.fc_id, l.fc_id) = r.fc_id
ORDER BY 4 DESC;
