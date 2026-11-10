/*
================================================================================
Game        : Slam Dunk (灌篮高手) - GL Region (全球服)
Report      : 道具获取明细与关联点券消耗 (Item Gain Details with Stamps Consumption)
Description : 统计指定道具获取明细，并在同一个事件事务中，使用 element_at 和 FILTER 
              从 a_rst (Row 结构体数组) 中提取点券 ('dmp:stamps') 及免费点券 ('dmp:freestamps') 的消耗。
Environment : Trino (TA - ta.v_event_21)
================================================================================
*/

WITH parsed_data AS (
    -- 第一步：只负责打平数据，绝对不在这里做过滤
    SELECT 
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        t.obj AS obj_str,
        CAST(t.diff AS DOUBLE) AS diff_val,
        
        -- 1. 使用 element_at 提取同事件中点券 ('dmp:stamps') 的消耗量（点号直接访问 ROW 字段 .diff，ABS 转换为正值）
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj = 'dmp:stamps' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        
        -- 2. 使用 element_at 提取同事件中免费点券 ('dmp:freestamps') 的消耗量
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj = 'dmp:freestamps' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 3. 使用 element_at 提取同事件中钻石 ('dmp:money') 的消耗量
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj = 'dmp:money' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS diamonds_consumed

    FROM ta.v_event_21
    CROSS JOIN UNNEST(
        filter(
            a_rst, 
            x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' 
        )
    ) AS t(before_val, obj, diff, after_val)
    -- 分区时间和事件时间这种非 JSON 字段，必须放在这里尽早过滤！
    WHERE "$part_date" >= '2026-05-01'
      AND "#event_time" ${Time:time}
      AND CAST(t.diff AS DOUBLE) > 0
      AND SPLIT(t.obj, '@')[1] = 'item' 
)

-- 第二步：直接拿解析好的干净字段进行过滤和展示
SELECT 
    role_id,
    zone_id,
    "#event_time" AS "获取时间",
    "$part_event",
    obj_str AS "道具ID",
    CAST(diff_val AS BIGINT) AS "获取数量",
    CAST(stamps_consumed AS BIGINT) AS "点券消耗",
    CAST(freestamps_consumed AS BIGINT) AS "免费点券消耗",
    CAST(diamonds_consumed AS BIGINT) AS "钻石消耗"
FROM parsed_data
WHERE diff_val > 0
  AND CAST(SPLIT(obj_str, '@')[2] AS INTEGER) IN (${itemlist}) 
ORDER BY "获取时间" DESC;
