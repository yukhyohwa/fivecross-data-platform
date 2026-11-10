/*
================================================================================
Game        : Slam Dunk (灌篮高手) - 所有地区 (TW / GL / KR)
Report      : 道具获取明细与关联点券消耗 (Item Gain Details with Stamps Consumption)
Description : 统计指定道具获取明细，并在同一个事件事务中，使用 element_at 和 FILTER 
              从 a_rst 中提取点券 ('dmp:stamps')、免费点券 ('dmp:freestamps') 及钻石的消耗。
Environment : Trino (TA - ta.v_event_20 / ta.v_event_21 / ta.v_event_22)
================================================================================
*/

WITH parsed_data AS (
    -- ==========================================
    -- 1. TC (台湾/繁体服) - v_event_20
    -- ==========================================
    SELECT 
        'TW' AS region,
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        json_extract_scalar(json_parse(t.item_str), '$.obj') AS obj_str,
        CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) AS diff_val,
        
        -- 点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:stamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 免费点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:freestamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 钻石消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:money' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS diamonds_consumed
    FROM ta.v_event_20
    CROSS JOIN UNNEST(
        filter(
            a_rst, 
            x -> x IS NOT NULL AND x <> '' 
        )
    ) AS t(item_str)
    WHERE "$part_date" >= '2026-05-01'
      AND "#event_time" ${Time:time}
      AND CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) > 0
      AND SPLIT(json_extract_scalar(json_parse(t.item_str), '$.obj'),'@')[1] = 'item' 

    UNION ALL

    -- ==========================================
    -- 2. GL (全球服) - v_event_21
    -- ==========================================
    SELECT 
        'GL' AS region,
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        t.obj AS obj_str,
        CAST(t.diff AS DOUBLE) AS diff_val,
        
        -- 点券消耗
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' AND x.obj = 'dmp:stamps' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 免费点券消耗
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' AND x.obj = 'dmp:freestamps' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 钻石消耗
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' AND x.obj = 'dmp:money' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
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
    WHERE "$part_date" >= '2026-05-01'
      AND "#event_time" ${Time:time}
      AND CAST(t.diff AS DOUBLE) > 0
      AND SPLIT(t.obj, '@')[1] = 'item' 

    UNION ALL

    -- ==========================================
    -- 3. KR (韩国服) - v_event_22
    -- ==========================================
    SELECT 
        'KR' AS region,
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        json_extract_scalar(json_parse(t.item_str), '$.obj') AS obj_str,
        CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) AS diff_val,
        
        -- 点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:stamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 免费点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:freestamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 钻石消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:money' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS diamonds_consumed
    FROM ta.v_event_22
    CROSS JOIN UNNEST(
        filter(
            a_rst, 
            x -> x IS NOT NULL AND x <> '' 
        )
    ) AS t(item_str)
    WHERE "$part_date" >= '2026-05-01'
      AND "#event_time" ${Time:time}
      AND CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) > 0
      AND SPLIT(json_extract_scalar(json_parse(t.item_str), '$.obj'),'@')[1] = 'item' 
)

-- 第二步：直接拿解析好的干净字段进行过滤和展示
SELECT 
    region AS "地区版本",
    role_id,
    zone_id,
    "#event_time" AS "获取时间",
    "$part_event" AS "发生事件名",
    obj_str AS "道具ID",
    CAST(diff_val AS BIGINT) AS "获取数量",
    CAST(stamps_consumed AS BIGINT) AS "点券消耗",
    CAST(freestamps_consumed AS BIGINT) AS "免费点券消耗",
    CAST(diamonds_consumed AS BIGINT) AS "钻石消耗"
FROM parsed_data
WHERE diff_val > 0
  AND CAST(SPLIT(obj_str, '@')[2] AS INTEGER) IN (${itemlist}) 
ORDER BY "获取时间" DESC;




/*
================================================================================
Game        : Slam Dunk (灌篮高手) - 所有地区 (TW / GL / KR)
Report      : 道具获取明细与关联点券消耗 (Item Gain Details with Stamps Consumption) --Version 2
Description : 统计指定道具获取明细，并在同一个事件事务中，使用 element_at 和 FILTER 
              从 a_rst 中提取点券 ('dmp:stamps')、免费点券 ('dmp:freestamps') 及钻石的消耗。
Environment : Trino (TA - ta.v_event_20 / ta.v_event_21 / ta.v_event_22)
================================================================================
*/

WITH matched_days AS (
    SELECT d
    FROM UNNEST(
        sequence(
            DATE '2026-05-01',
            current_date,
            INTERVAL '1' DAY
        )
    ) AS days(d)
    WHERE CAST(d AS TIMESTAMP) ${Time:time}
),

/*
CAST(d AS TIMESTAMP)  DATE '2026-08-06'→ TIMESTAMP '2026-08-06 00:00:00'
TIMESTAMP '2026-08-06 00:00:00' BETWEEN TIMESTAMP '2026-08-06 10:00:00' AND TIMESTAMP '2026-08-10 15:00:00' flase
*/

selected_days AS (
    SELECT DISTINCT
        CAST(date_add('day', offset_day, d) AS VARCHAR) AS part_date
    FROM matched_days
    CROSS JOIN UNNEST(ARRAY[-1, 0, 1]) AS offsets(offset_day)
),

parsed_data AS (
    -- ==========================================
    -- 1. TC (台湾/繁体服) - v_event_20
    -- ==========================================
    SELECT 
        'TW' AS region,
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        json_extract_scalar(json_parse(t.item_str), '$.obj') AS obj_str,
        CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) AS diff_val,
        
        -- 点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:stamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 免费点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:freestamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 钻石消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:money' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS diamonds_consumed
    FROM ta.v_event_20
    CROSS JOIN UNNEST(
        filter(
            a_rst, 
            x -> x IS NOT NULL AND x <> '' 
        )
    ) AS t(item_str)
    WHERE "$part_date" IN (SELECT part_date FROM selected_days)
      AND "#event_time" ${Time:time}
      AND CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) > 0
      AND SPLIT(json_extract_scalar(json_parse(t.item_str), '$.obj'),'@')[1] = 'item' 

    UNION ALL

    -- ==========================================
    -- 2. GL (全球服) - v_event_21
    -- ==========================================
    SELECT 
        'GL(WW)' AS region,
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        t.obj AS obj_str,
        CAST(t.diff AS DOUBLE) AS diff_val,
        
        -- 点券消耗
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' AND x.obj = 'dmp:stamps' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 免费点券消耗
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' AND x.obj = 'dmp:freestamps' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 钻石消耗
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' AND x.obj = 'dmp:money' AND TRY(CAST(x.diff AS DOUBLE)) < 0),
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
    WHERE "$part_date" IN (SELECT part_date FROM selected_days)
      AND "#event_time" ${Time:time}
      AND CAST(t.diff AS DOUBLE) > 0
      AND SPLIT(t.obj, '@')[1] = 'item' 

    UNION ALL

    -- ==========================================
    -- 3. KR (韩国服) - v_event_22
    -- ==========================================
    SELECT 
        'KR' AS region,
        SPLIT(a_usr,'@')[2] AS role_id,
        SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
        "#event_time",
        "$part_event",
        json_extract_scalar(json_parse(t.item_str), '$.obj') AS obj_str,
        CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) AS diff_val,
        
        -- 点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:stamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 免费点券消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:freestamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS freestamps_consumed,
        
        -- 钻石消耗
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:money' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS diamonds_consumed
    FROM ta.v_event_22
    CROSS JOIN UNNEST(
        filter(
            a_rst, 
            x -> x IS NOT NULL AND x <> '' 
        )
    ) AS t(item_str)
    WHERE "$part_date" IN (SELECT part_date FROM selected_days)
      AND "#event_time" ${Time:time}
      AND CAST(json_extract_scalar(json_parse(t.item_str), '$.diff') AS DOUBLE) > 0
      AND SPLIT(json_extract_scalar(json_parse(t.item_str), '$.obj'),'@')[1] = 'item' 
)

-- 第二步：直接拿解析好的干净字段进行过滤和展示
SELECT 
    region AS "地区版本",
    role_id,
    zone_id,
    "#event_time" AS "获取时间",
    "$part_event" AS "发生事件名",
    obj_str AS "道具ID",
    CAST(diff_val AS BIGINT) AS "获取数量",
    CAST(stamps_consumed AS BIGINT) AS "点券消耗",
    CAST(freestamps_consumed AS BIGINT) AS "免费点券消耗",
    CAST(diamonds_consumed AS BIGINT) AS "钻石消耗"
FROM parsed_data
WHERE diff_val > 0
  AND CAST(SPLIT(obj_str, '@')[2] AS INTEGER) IN (${itemlist}) 
ORDER BY "获取时间" DESC;




















