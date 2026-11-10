/*
================================================================================
Game        : Kuroko's Basketball (黑子) - KR Region
Report      : 7月新增用户指定道具(30001533, 30001537)购买及关联货币消耗统计
Date Range  : 2026-07-01 ~ 2026-07-30
Description : 统计7月1日到30日期间注册的新增用户，在获取 30001533, 30001537 时的
              付费点券、免费点券及钻石消耗总计。
              区分 30001533 和 30001537 分行展示。
================================================================================
*/

WITH 
-- 1. 识别 7月1日 ~ 7月30日 的新增用户
-- 计算出 uuid 的最早 login 时间，看最早 login 时间在不在 7 月
NewUsers AS (
    SELECT uuid
    FROM ta.v_event_12
    WHERE "$part_event" = 'login'
      AND uuid IS NOT NULL
      AND uuid <> ''
    GROUP BY uuid
    HAVING MIN(CAST("$part_date" AS DATE)) BETWEEN DATE '2026-07-01' AND DATE '2026-07-30'
),

-- 2. 提取指定日期范围内这些新增用户的资源变化明细
AllChanges AS (
    SELECT 
        s1.uuid,
        s1."#event_time" AS event_time,
        s1."$part_event" AS part_event,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_12 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t
    JOIN NewUsers nu ON s1.uuid = nu.uuid
    WHERE s1."$part_date" BETWEEN '2026-07-01' AND '2026-07-30'
      AND s1.uuid IS NOT NULL
      AND s1.a_rst IS NOT NULL
),

-- 3. 按事务 (同一用户、同一秒、同一事件) 聚合
TransactionPulse AS (
    SELECT
        uuid,
        event_time,
        part_event,
        -- 分别提取 30001533 和 30001537 的产出数量
        SUM(CASE WHEN item_id = 30001533 AND item_diff > 0 THEN item_diff ELSE 0 END) AS gain_33,
        SUM(CASE WHEN item_id = 30001537 AND item_diff > 0 THEN item_diff ELSE 0 END) AS gain_37,
        
        -- 提取对应的三种货币消耗（取绝对值）
        SUM(CASE WHEN item_id = 10000000 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS paid_stamps_spent,
        SUM(CASE WHEN item_id = 19000000 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS free_stamps_spent,
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent
    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        SUM(CASE WHEN item_id IN (30001533, 30001537) AND item_diff > 0 THEN 1 ELSE 0 END) > 0
    )
),

-- 4. 拆分目标道具 (如果在同一个事务中同时获得了这两个道具，拆为独立的两条流水分开统计)
SplitItems AS (
    SELECT 
        uuid, part_event, '30001533' AS target_item, gain_33 AS target_gain, 
        paid_stamps_spent, free_stamps_spent, diamonds_spent
    FROM TransactionPulse WHERE gain_33 > 0
    UNION ALL
    SELECT 
        uuid, part_event, '30001537' AS target_item, gain_37 AS target_gain, 
        paid_stamps_spent, free_stamps_spent, diamonds_spent
    FROM TransactionPulse WHERE gain_37 > 0
)

-- 5. 按事件类型与目标道具汇总输出
SELECT 
    part_event AS "事件类型",
    target_item AS "获取的道具",
    COUNT(DISTINCT uuid) AS "新增参与人数",
    SUM(target_gain) AS "获得道具总量",
    SUM(paid_stamps_spent) AS "付费点券消耗",
    SUM(free_stamps_spent) AS "免费点券消耗",
    SUM(diamonds_spent) AS "钻石消耗",
    SUM(paid_stamps_spent + free_stamps_spent) AS "总点券消耗",
    SUM(paid_stamps_spent + free_stamps_spent + diamonds_spent) AS "总货币消耗"
FROM SplitItems
GROUP BY 1, 2
ORDER BY 1 DESC, 2 ASC;
