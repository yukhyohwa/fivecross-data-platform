/*
================================================================================
Game    : Kuroko's Basketball (黑子的篮球)
Region  : TC (繁体大区, AppID=10, v_event_10)
Report  : 2026-08-08 当日付费较多用户的跃之星/点券消耗在哪里，并查看兑换的具体道具
================================================================================
*/
WITH top_paying_users AS (
    -- 1. 筛选出 2026-08-08 当日有过付费行为的用户
    SELECT DISTINCT uuid
    FROM ta.v_event_10
    WHERE "$part_date" = '2026-08-08'
      AND "$part_event" = 'charge'
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND (order_id NOT IN ('11') OR order_id IS NULL)
      AND pay_currency <> 'COIN'
      AND uuid IS NOT NULL AND uuid <> ''
),
StampsEvents AS (
    -- 2. 匹配这些付费用户的事件，分别提取付费点券(10000000) 和 免费点券/跃之星(19000000) 的减少记录 (<0)
    SELECT 
        evt."$part_date",
        evt."$part_event",
        evt.uuid,
        evt.role_name,
        evt.a_rst,
        ABS(
            REDUCE(
                FILTER(evt.a_rst, x -> CAST(x.id AS INTEGER) = 10000000 AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS paid_stamps_consumed,
        ABS(
            REDUCE(
                FILTER(evt.a_rst, x -> CAST(x.id AS INTEGER) = 19000000 AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS free_stamps_consumed
    FROM ta.v_event_10 evt
    INNER JOIN top_paying_users u ON evt.uuid = u.uuid
    WHERE evt."$part_date" = '2026-08-08'
      AND ANY_MATCH(evt.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0)
),
ItemsObtained AS (
    -- 3. 展开 (Explode) 这些事件中获得的道具 (diff > 0)
    SELECT 
        "$part_date",
        "$part_event",
        uuid,
        role_name,
        paid_stamps_consumed,
        free_stamps_consumed,
        t.item_id AS obtained_item_id,
        t.item_diff AS obtained_amount
    FROM StampsEvents
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE CAST(t.item_id AS INTEGER) NOT IN (10000000, 19000000)
        AND t.item_diff > 0
)
-- 4. 最终输出和汇总 (连结道具名称表)
SELECT 
    s1."$part_date" AS "日期",
    s1.uuid AS "用户UUID",
    s1."$part_event" AS "消耗场景(Event)",
    s1.obtained_item_id AS "兑换道具ID",
    COALESCE(s2."shop_item.item_id@name", CAST(s1.obtained_item_id AS VARCHAR)) AS "兑换道具名称",
    SUM(s1.obtained_amount) AS "获得该道具总数量",
    SUM(s1.paid_stamps_consumed) AS "花费的付费点券",
    SUM(s1.free_stamps_consumed) AS "花费的免费点券",
    SUM(s1.paid_stamps_consumed + s1.free_stamps_consumed) AS "花费的点券总数"
FROM ItemsObtained s1 
LEFT JOIN ta_dim.dim_10_0_12928 s2 
    ON s1.obtained_item_id = s2."shop_item.item_id@shop_item_id"
GROUP BY 
    1, 2, 3, 4, 5
ORDER BY 
    SUM(s1.paid_stamps_consumed + s1.free_stamps_consumed) DESC;
