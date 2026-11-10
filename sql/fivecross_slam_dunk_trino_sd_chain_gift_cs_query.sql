SELECT 'TW' area,"giftindex_str" gift,
SPLIT(a_usr,'@')[2] AS role_id,
SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
"#event_time",
"$part_event",
aid_str aid,
linkageindex_str link,
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:stamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 2. 使用 element_at 获取过滤后数组的第一个免费点券消耗值
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:freestamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS freestamps_consumed
FROM ta.v_event_20
WHERE "$part_event" = 'chain_buy'
AND ${PartDate:date1} 
AND aid_str='40243639' AND linkageindex_str='2332' AND giftindex_str IN ('3518','3524')

UNION ALL

SELECT  'WW' area,"giftindex_str" gift,
SPLIT(a_usr,'@')[2] AS role_id,
SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
"#event_time",
"$part_event",
aid_str aid,
linkageindex_str link,
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' 
                    AND x.obj = 'dmp:stamps' 
                    AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 2. 使用 element_at 获取过滤后数组的第一个免费点券消耗值
        ABS(COALESCE(
            TRY(CAST(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x.obj IS NOT NULL AND x.obj <> '' 
                    AND x.obj = 'dmp:freestamps' 
                    AND TRY(CAST(x.diff AS DOUBLE)) < 0),
                1
            ).diff AS DOUBLE)),
            0.0
        )) AS freestamps_consumed
FROM ta.v_event_21
WHERE "$part_event" = 'chain_buy'
AND ${PartDate:date1} 
AND aid_str='40243639' AND linkageindex_str='2332' AND giftindex_str IN ('3518','3524')

UNION ALL

SELECT  'KR' area,"giftindex_str" gift,
SPLIT(a_usr,'@')[2] AS role_id,
SPLIT(SPLIT(a_usr,'@')[1],'_')[3] AS zone_id,
"#event_time",
"$part_event",
aid_str aid,
linkageindex_str link,
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:stamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS stamps_consumed,
        
        -- 2. 使用 element_at 获取过滤后数组的第一个免费点券消耗值
        ABS(COALESCE(
            TRY(CAST(json_extract_scalar(json_parse(element_at(
                FILTER(a_rst, x -> x IS NOT NULL AND x <> '' 
                    AND json_extract_scalar(json_parse(x), '$.obj') = 'dmp:freestamps' 
                    AND TRY(CAST(json_extract_scalar(json_parse(x), '$.diff') AS DOUBLE)) < 0),
                1
            )), '$.diff') AS DOUBLE)),
            0.0
        )) AS freestamps_consumed
FROM ta.v_event_22
WHERE "$part_event" = 'chain_buy'
AND ${PartDate:date1} 
AND aid_str='40243639' AND linkageindex_str='2332' AND giftindex_str IN ('3518','3524')
