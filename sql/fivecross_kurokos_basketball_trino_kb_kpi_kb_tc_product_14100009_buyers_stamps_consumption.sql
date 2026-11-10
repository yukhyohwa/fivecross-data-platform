/*
================================================================================
Game    : Kuroko's Basketball (黑子的篮球)
Region  : TC (繁体大区, AppID=10, v_event_10)
Report  : 当天购买指定商品 (cfg_id = 14100009) 玩家的点券 (Stamps) 消耗去向分析
Date    : 支持数数后台时间筛选宏 ${PartDate:date1} (例如 2026-07-28 或任意日期)
User ID : uuid (全流程使用 uuid 作为主要玩家关联标识)
Logic   :
  1. 圈定在指定日期内购买了商品 cfg_id = 14100009 的目标玩家 UUID 集合 (BuyersCohort)。
  2. 提取这些目标 UUID 玩家在【同一天】(当天) 触发的点券 (ID: 10000000, 19000000) 消耗事件 (StampsEvents)。
  3. UNNEST 解包该消耗事件中获得的具体道具 (ItemsObtained) 并关联 ta_dim.dim_10_0_12928 道具维表。
  4. 汇总输出该批玩家在当天的点券消耗去向、获得道具名称、人数、消耗点券总数及人均消耗。
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- 1. 圈定指定日期内购买了商品 cfg_id = 14100009 的目标玩家 UUID 队列
--------------------------------------------------------------------------------
BuyersCohort AS (
    SELECT DISTINCT
        uuid,
        "$part_date" AS part_date
    FROM ta.v_event_10
    WHERE ${PartDate:date1}
      AND "$part_event" = 'charge'
      AND CAST(cfg_id AS VARCHAR) = '14100009'
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND (order_id NOT IN ('11') OR order_id IS NULL)
      AND uuid IS NOT NULL AND uuid <> ''
),

--------------------------------------------------------------------------------
-- 2. 提取目标玩家在【同一天】发生的点券 (ID: 10000000, 19000000) 消耗事件
--------------------------------------------------------------------------------
StampsEvents AS (
    SELECT 
        v."$part_date",
        v.uuid,
        v.a_rst,
        ABS(
            REDUCE(
                FILTER(v.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS stamps_consumed
    FROM ta.v_event_10 v
    INNER JOIN BuyersCohort b 
        ON v.uuid = b.uuid 
       AND v."$part_date" = b.part_date  -- 精确限定在购买当天的点券消耗
    WHERE v.${PartDate:date1}
      AND ANY_MATCH(v.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0)
),

--------------------------------------------------------------------------------
-- 3. UNNEST 解包通过消耗点券所获得的具体道具与数量
--------------------------------------------------------------------------------
ItemsObtained AS (
    SELECT 
        s."$part_date",
        s.uuid,
        s.stamps_consumed,
        t.item_id AS obtained_item_id,
        t.item_diff AS obtained_amount
    FROM StampsEvents s
    CROSS JOIN UNNEST(s.a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE CAST(t.item_id AS INTEGER) NOT IN (10000000, 19000000)
      AND t.item_diff > 0
)

--------------------------------------------------------------------------------
-- 4. 汇总输出目标玩家当天的点券消耗去向明细
--------------------------------------------------------------------------------
SELECT 
    s1."$part_date"                                                                        AS "日期",
    s1.obtained_item_id                                                                    AS "获得道具ID",
    COALESCE(s2."shop_item.item_id@name", CAST(s1.obtained_item_id AS VARCHAR))            AS "获得道具名称",
    COUNT(DISTINCT s1.uuid)                                                                AS "消耗点券玩家人数",
    SUM(s1.obtained_amount)                                                                AS "获得道具总数量",
    SUM(s1.stamps_consumed)                                                                AS "消耗点券总数",
    ROUND(SUM(s1.stamps_consumed) * 1.0 / NULLIF(COUNT(DISTINCT s1.uuid), 0), 2)           AS "人均消耗点券"
FROM ItemsObtained s1 
LEFT JOIN ta_dim.dim_10_0_12928 s2 
    ON CAST(s1.obtained_item_id AS VARCHAR) = CAST(s2."shop_item.item_id@shop_item_id" AS VARCHAR)
GROUP BY 
    1, 2, 3
ORDER BY 
    "消耗点券总数" DESC, "消耗点券玩家人数" DESC;
