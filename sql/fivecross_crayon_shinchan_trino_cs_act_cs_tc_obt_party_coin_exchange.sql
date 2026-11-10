WITH
UserBlacklist AS (
    SELECT DISTINCT
        TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN (
        'is_windows_new',
        'internal_users_new',
        'is_water_new'
    )
),

-- 道具维表按 ID 去重，避免关联放大
ItemDim AS (
    SELECT
        TRY_CAST("item_id@item_id" AS BIGINT) AS item_id,
        MAX("item_id@item_name") AS item_name
    FROM ta_dim.dim_18_0_52781
    GROUP BY 1
),

-- 只读取所选日期的道具变动
ItemEvents AS (
    SELECT
        v."$part_date" AS dt,
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS role_id,
        DATE_TRUNC(
            'second',
            CAST(v."#event_time" AS TIMESTAMP)
        ) AS event_second,
        FILTER(
            v.a_rst,
            x ->
                (
                    TRY_CAST(x.id AS BIGINT) = 10069
                    AND TRY_CAST(x.before AS BIGINT)
                        > TRY_CAST(x.after AS BIGINT)
                )
                OR
                (
                    TRY_CAST(x.id AS BIGINT) <> 10069
                    AND TRY_CAST(x.after AS BIGINT)
                        > TRY_CAST(x.before AS BIGINT)
                )
        ) AS changes
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'item_change'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
),

-- 转为标量数组后展开，避免 ROW 数组的列别名数量错误
ItemChanges AS (
    SELECT
        e.dt,
        e.fc_id,
        e.role_id,
        e.event_second,
        u.item_id,
        u.item_before,
        u.item_after,
        NULLIF(TRIM(u.item_name), '') AS log_item_name
    FROM ItemEvents e
    CROSS JOIN UNNEST(
        TRANSFORM(e.changes, x -> TRY_CAST(x.id AS BIGINT)),
        TRANSFORM(e.changes, x -> TRY_CAST(x.before AS BIGINT)),
        TRANSFORM(e.changes, x -> TRY_CAST(x.after AS BIGINT)),
        TRANSFORM(e.changes, x -> CAST(x.name AS VARCHAR))
    ) AS u(item_id, item_before, item_after, item_name)
),

-- 同账号、同角色、同秒汇总消耗和奖励组合
ExchangeGroups AS (
    SELECT
        c.dt,
        c.fc_id,
        c.role_id,
        c.event_second,
        SUM(
            CASE
                WHEN c.item_id = 10069
                 AND c.item_before > c.item_after
                THEN c.item_before - c.item_after
                ELSE 0
            END
        ) AS consume_amount,
        ARRAY_JOIN(
            ARRAY_SORT(
                ARRAY_DISTINCT(
                    ARRAY_AGG(
                        COALESCE(
                            d.item_name,
                            c.log_item_name,
                            CAST(c.item_id AS VARCHAR)
                        )
                    ) FILTER (
                        WHERE c.item_id <> 10069
                          AND c.item_after > c.item_before
                    )
                )
            ),
            ' + '
        ) AS gained_item_names
    FROM ItemChanges c
    LEFT JOIN ItemDim d
        ON c.item_id = d.item_id
    GROUP BY 1, 2, 3, 4
)

SELECT
    dt AS "日期",
    COALESCE(
        NULLIF(gained_item_names, ''),
        '未匹配获得道具'
    ) AS "兑换获得的道具名称(组合)",
    COUNT(DISTINCT fc_id) AS "兑换人数",
    SUM(consume_amount) AS "欢乐币消耗总数"
FROM ExchangeGroups
WHERE consume_amount > 0
GROUP BY 1, 2
ORDER BY 1 DESC, 4 DESC;
