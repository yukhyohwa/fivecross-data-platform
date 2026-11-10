/*
================================================================================
项目：黑子日本 - 道具 3010522 关联消耗统计
时间：2026-04-29 ~ 2026-05-20
目标：统计获得道具 3010522 时关联的点券与钻石消耗
输出：包含总汇总行与每日明细看板
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- 0. 黑名单过滤 (剔除测试号与灌水号)
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- 1. 提取流水明细 (识别点券、钻石及目标道具)
--------------------------------------------------------------------------------
AllChanges AS (
    SELECT 
        s1."$part_date" AS part_date,
        s1."#user_id" AS user_id,
        s1."#event_time" AS event_time,
        s1."#event_name" AS event_name,
        CAST(t.id AS BIGINT) AS item_id,
        CAST(t.diff AS BIGINT) AS item_diff
    FROM ta.v_event_9 s1
    CROSS JOIN UNNEST(s1.a_rst) AS t("diff", "key", "after", "before", "id")
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE s1."$part_date" BETWEEN '2026-04-29' AND '2026-05-20'
        AND s1.a_rst IS NOT NULL
        AND b."#user_id" IS NULL
),

--------------------------------------------------------------------------------
-- 2. 事务脉冲合并 (按 用户 + 秒 + 事件名 聚合)
--------------------------------------------------------------------------------
TransactionPulse AS (
    SELECT
        part_date,
        user_id,
        event_time,
        MAX(event_name) AS event_name,
        -- 点券消耗 (ID: 10000000, 19000000)
        SUM(CASE WHEN item_id IN (10000000, 19000000) AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS stamps_spent,
        -- 钻石消耗 (ID: 10000003)
        SUM(CASE WHEN item_id = 10000003 AND item_diff < 0 THEN ABS(item_diff) ELSE 0 END) AS diamonds_spent,
        -- 目标道具产出数量 (ID: 3010522)
        SUM(CASE WHEN item_id = 3010522 AND item_diff > 0 THEN item_diff ELSE 0 END) AS target_item_gain
    FROM AllChanges
    GROUP BY 1, 2, 3
    HAVING (
        -- 必须包含目标道具 3010522 的获取
        MAX(CASE WHEN item_id = 3010522 AND item_diff > 0 THEN 1 ELSE 0 END) = 1
        -- 且必须有实际的货币消耗
        AND SUM(CASE WHEN item_id IN (10000000, 19000000, 10000003) AND item_diff < 0 THEN 1 ELSE 0 END) > 0
    )
),

--------------------------------------------------------------------------------
-- 3. 统计汇总
--------------------------------------------------------------------------------
SummaryData AS (
    SELECT 
        '2026-04-29 ~ 2026-05-20' AS "日期",
        '【总计汇总】' AS "分类",
        COUNT(DISTINCT user_id) AS "参与人数",
        SUM(target_item_gain) AS "获得道具总量",
        SUM(stamps_spent) AS "消耗点券总量",
        SUM(diamonds_spent) AS "消耗钻石总量",
        SUM(stamps_spent + diamonds_spent) AS "总货币消耗",
        SUM(stamps_spent + diamonds_spent) / NULLIF(SUM(target_item_gain), 0) AS "单件道具平均成本"
    FROM TransactionPulse
),

DailyData AS (
    SELECT 
        part_date AS "日期",
        '每日明细' AS "分类",
        COUNT(DISTINCT user_id) AS "参与人数",
        SUM(target_item_gain) AS "获得道具总量",
        SUM(stamps_spent) AS "消耗点券总量",
        SUM(diamonds_spent) AS "消耗钻石总量",
        SUM(stamps_spent + diamonds_spent) AS "总货币消耗",
        SUM(stamps_spent + diamonds_spent) / NULLIF(SUM(target_item_gain), 0) AS "单件道具平均成本"
    FROM TransactionPulse
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 4. 最终输出
--------------------------------------------------------------------------------
SELECT * FROM SummaryData
UNION ALL
SELECT * FROM DailyData
ORDER BY "分类" DESC, "日期" DESC;
