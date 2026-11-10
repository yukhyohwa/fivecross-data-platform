/*
================================================================================
Game: Kuroko's Basketball
Region: JP (Japan)
Description: 黑子JP 每日活跃玩家点券进销存 (Stamps Inventory and Consumption)
             1. 每日活跃玩家的当前点券总库存（以每日的24点为当日的结算时间）
             2. 每日身上有点券的活跃玩家数量
             3. 每日身上有点券的玩家的平均点券持有数
             4. 每日活跃玩家的点券获取数量
             5. 每日活跃玩家的点券消耗数量
             6. 每日活跃玩家的点券进销量（获取数量 - 消耗数量）
             7. 每日点券持有数排名前3的玩家的点券持有量与玩家ID
             (支持去重黑名单过滤，支持修复科学计数法)
Author: Antigravity
================================================================================
*/

WITH 
--------------------------------------------------------------------------------
-- Section 0: 黑名单过滤 (Blacklist)
--------------------------------------------------------------------------------
FinalBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_9
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

--------------------------------------------------------------------------------
-- Section 1: 展开并提取涉及点券 (10000000, 19000000) 的 a_rst 数据
--------------------------------------------------------------------------------
StampFlattened AS (
    SELECT
        s1."$part_date" AS part_date,
        s1.gid,
        s1."#event_time" AS event_time,
        CAST(t.id AS INTEGER) AS item_id,
        CAST(t.before AS DOUBLE) AS before,
        CAST(t.diff AS DOUBLE) AS diff,
        CAST(t.after AS DOUBLE) AS after
    FROM ta.v_event_9 s1
    -- 展开 a_rst 数组格式
    CROSS JOIN UNNEST(s1.a_rst) AS t
    -- 关联黑名单表，只留下未在黑名单内的用户
    LEFT JOIN FinalBlacklist b ON s1."#user_id" = b."#user_id"
    WHERE ${PartDate:timerange} 
        AND b."#user_id" IS NULL
        -- 仅筛选出关注的两类点券
        AND CAST(t.id AS INTEGER) IN (10000000, 19000000)
),

--------------------------------------------------------------------------------
-- Section 2: 按天、玩家、点券类型(免费/付费) 计算产出、消耗以及当日的最终存量(after)
--------------------------------------------------------------------------------
PlayerDailyItemStats AS (
    SELECT 
        part_date,
        gid,
        item_id,
        -- 获取：diff 为正数时代表产出
        SUM(IF(diff > 0, diff, 0.0)) AS obtained,
        -- 消耗：diff 为负数时代表消耗（取绝对值）
        SUM(IF(diff < 0, ABS(diff), 0.0)) AS consumed,
        -- 存量：找到当日最后一次涉及该变动/快照事件的 after 金额
        MAX_BY(after, event_time) AS end_of_day_balance
    FROM StampFlattened
    GROUP BY 1, 2, 3
),

--------------------------------------------------------------------------------
-- Section 3: 把免费与付费点券合并，得出该名玩家当天的总产出、消耗与总存量
--------------------------------------------------------------------------------
PlayerDailyStats AS (
    SELECT
        part_date,
        gid,
        SUM(obtained) AS daily_obtained,
        SUM(consumed) AS daily_consumed,
        SUM(end_of_day_balance) AS end_of_day_balance
    FROM PlayerDailyItemStats
    GROUP BY 1, 2
)

--------------------------------------------------------------------------------
-- Section 4: 最终看板指标聚合
--------------------------------------------------------------------------------
SELECT 
    part_date AS "日期",
    -- 1、每日活跃玩家的当前点券总库存（以每日的24点为当日的结算时间）
    SUM(end_of_day_balance) AS "总点券库存",

    -- 2、每日身上有点券的活跃玩家数量
    COUNT(IF(end_of_day_balance > 0, gid, NULL)) AS "持有点券活跃玩家数",

    -- 3、每日身上有点券的玩家的平均点券持有数
    CAST(SUM(end_of_day_balance) / NULLIF(COUNT(IF(end_of_day_balance > 0, gid, NULL)), 0) AS BIGINT) AS "平均点券持有数",

    -- 4、每日活跃玩家的点券获取数量
    SUM(daily_obtained) AS "总获取数量",

    -- 5、每日活跃玩家的点券消耗数量
    SUM(daily_consumed) AS "总消耗数量",

    -- 6、每日活跃玩家的点券进销量（获取数量 - 消耗数量）
    SUM(daily_obtained) - SUM(daily_consumed) AS "点券进销量",

    -- 7.1、每日点券持有数排名前3的玩家的点券持有量（数组形式输出）
    transform(
        slice(reverse(array_sort(array_agg(CAST(ROW(end_of_day_balance, CAST(TRY_CAST(gid AS DOUBLE) AS BIGINT)) AS ROW(balance DOUBLE, gid BIGINT))))), 1, 3), 
        x -> CAST(x.balance AS BIGINT)
    ) AS "Top3点券持有量",

    -- 7.2、每日点券持有数排名前3的玩家ID（剥离科学记数法）
    transform(
        slice(reverse(array_sort(array_agg(CAST(ROW(end_of_day_balance, CAST(TRY_CAST(gid AS DOUBLE) AS BIGINT)) AS ROW(balance DOUBLE, gid BIGINT))))), 1, 3), 
        x -> x.gid
    ) AS "Top3玩家ID"

FROM PlayerDailyStats
GROUP BY 1
ORDER BY 1 ASC;
