-- 取4月15日打开宝箱7084005的玩家，判断目标英雄：
--   优先：开箱内容物中直接包含的 card item_id（item_id <> 7084005）
--   兜底：开箱后第一条 card_levelup/card_awake/card_talent 操作的 card_id

WITH

-- Step 1.1: 开箱事件 — 没有获得卡牌记录的用户开箱数据
BoxOpen AS (
    SELECT
        role_id,
        box_open_time
    FROM (
        SELECT
            rolecommon.role_id  AS role_id,
            resourceInfo,
            "#event_time"       AS box_open_time
        FROM ta.v_event_16
        CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
        WHERE "$part_date" = '2026-04-15'
          AND "$part_event" = 'item_use'
          AND t.item_id = 7084005
    ) base
    WHERE cardinality(resourceInfo) = 1
),

-- Step 1.2: 每个玩家开箱后第一条英雄操作（兜底用）
FirstCardAction AS (
    SELECT
        h.rolecommon.role_id    AS role_id,
        h.card_id               AS action_card_id,
        ROW_NUMBER() OVER (
            PARTITION BY h.rolecommon.role_id
            ORDER BY h."#event_time" ASC
        )                       AS rn
    FROM ta.v_event_16 h
    JOIN (SELECT DISTINCT role_id, box_open_time FROM BoxOpen) b
        ON h.rolecommon.role_id = b.role_id
    WHERE h."$part_date" = '2026-04-15'
      AND h."$part_event" IN ('card_levelup', 'card_awake', 'card_talent')
      AND h."#event_time" > b.box_open_time
),

-- Step 2: 开箱事件 — 有获得卡牌记录的用户开箱数据
BoxOpen2 AS (
    SELECT role_id,t.item_id
    FROM (
        SELECT rolecommon.role_id role_id,resourceInfo
        FROM ta.v_event_16
        CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
        WHERE "$part_date" = '2026-04-15' 
        AND "$part_event" = 'item_use'
        AND t.item_id = 7084005
        )
    CROSS JOIN UNNEST(resourceInfo) AS t(item_id, prev, diff, after)
    WHERE t.item_id <> 7084005
)


SELECT
    bo.role_id                                          AS "玩家ID",
    fa.action_card_id                                   AS "首次card操作card_id"
FROM (SELECT DISTINCT role_id, box_open_time FROM BoxOpen) bo
LEFT JOIN (SELECT * FROM FirstCardAction WHERE rn = 1) fa
    ON bo.role_id = fa.role_id
UNION ALL 
SELECT DISTINCT role_id, item_id FROM BoxOpen2