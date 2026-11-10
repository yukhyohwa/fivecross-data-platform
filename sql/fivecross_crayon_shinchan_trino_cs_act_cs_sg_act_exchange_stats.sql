WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
),
ItemChange AS (
    SELECT 
        "#account_id",
        "#event_time",
        -- 消耗红钻 (ID: 10009)
        SUM(REDUCE(a_rst, CAST(0 AS BIGINT), (s, x) -> s + CASE WHEN CAST(x.id AS BIGINT) = 10009 AND CAST(x.before AS BIGINT) > CAST(x.after AS BIGINT) THEN CAST(x.diff AS BIGINT) ELSE 0 END, s -> s)) AS red_diamond_consumed,
        -- 消耗金币 (ID: 10108)
        SUM(REDUCE(a_rst, CAST(0 AS BIGINT), (s, x) -> s + CASE WHEN CAST(x.id AS BIGINT) = 10108 AND CAST(x.before AS BIGINT) > CAST(x.after AS BIGINT) THEN CAST(x.diff AS BIGINT) ELSE 0 END, s -> s)) AS coin_consumed
    FROM ta.v_event_13
    WHERE "$part_event" = 'item_change'
      AND ${PartDate:date1}
    GROUP BY 1, 2
)

SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '已合并'
    END AS "时间维度",
    v.shop_item[1].shop_id AS "商店ID",
    v.a_rst[1].id AS "道具ID",
    v.a_rst[1].name AS "道具名称",
    SUM(TRY_CAST(v.a_rst[1].diff AS BIGINT)) AS "兑换总量",
    COUNT(DISTINCT v."#account_id") AS "兑换人数",
    -- 消耗红钻 (ID: 10009)
    SUM(ic.red_diamond_consumed) AS "消耗红钻数",
    -- 消耗金币 (ID: 10108)
    SUM(ic.coin_consumed) AS "消耗金币数"
FROM ta.v_event_13 v
LEFT JOIN ItemChange ic 
    ON v."#account_id" = ic."#account_id" 
    AND v."#event_time" = ic."#event_time"
LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
WHERE v."$part_event" = 'shop_buy'
AND v.${PartDate:date1}
AND ub."#user_id" IS NULL
GROUP BY 1, 2, 3, 4
ORDER BY "商店ID", "兑换总量" DESC;
