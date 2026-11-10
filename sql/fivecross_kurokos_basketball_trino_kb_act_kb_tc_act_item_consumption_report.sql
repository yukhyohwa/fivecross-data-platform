-------------------------------------------------------
-- 1. 黑名单逻辑 (基于 #user_id)
-------------------------------------------------------
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

-------------------------------------------------------
-- 2. 原始道具变动流水 (过滤黑名单)
-------------------------------------------------------
RawItemChanges AS (
    SELECT 
        v."#user_id" AS user_id,
        v."$part_event" AS event_name,
        v."#event_time" AS event_time,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_10 v
    CROSS JOIN UNNEST(a_rst) AS t(id, "before", diff, "after", "key")
    WHERE v.${PartDate:date2} -- 时间筛选
        AND v."#user_id" NOT IN (SELECT "#user_id" FROM FinalBlacklist)
),

-------------------------------------------------------
-- 3. 提取货币消耗 (点券 10000000, 钻石 10000003)
-------------------------------------------------------
CurrencyLosses AS (
    SELECT 
        user_id,
        event_time,
        event_name,
        SUM(CASE WHEN item_id = 10000000 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS stamps_consumed,
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_consumed
    FROM RawItemChanges
    GROUP BY 1, 2, 3
    HAVING SUM(CASE WHEN item_id IN (10000000, 10000003) AND item_diff < 0 THEN 1 ELSE 0 END) > 0
),

-------------------------------------------------------
-- 4. 提取目标道具获得明细
-------------------------------------------------------
TargetGains AS (
    SELECT 
        user_id,
        event_time,
        event_name,
        item_id,
        SUM(item_diff) AS gain_qty
    FROM RawItemChanges
    WHERE item_id IN (${Variable1}) AND item_diff > 0
    GROUP BY 1, 2, 3, 4
)

-------------------------------------------------------
-- 5. 最终汇总输出
-------------------------------------------------------
SELECT 
    tg.item_id AS "目标道具ID",
    tg.event_name AS "产出途径 ($part_event)",
    COUNT(DISTINCT tg.user_id) AS "触发人数",
    SUM(tg.gain_qty) AS "获得道具总量",
    SUM(cl.stamps_consumed) AS "关联点券消耗",
    SUM(cl.diamonds_consumed) AS "关联钻石消耗"
FROM TargetGains tg
LEFT JOIN CurrencyLosses cl 
    ON tg.user_id = cl.user_id 
    AND tg.event_time = cl.event_time
GROUP BY 1, 2
ORDER BY 1, 5 DESC, 6 DESC;
