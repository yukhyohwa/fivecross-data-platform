/*
================================================================================
项目：蜡笔小新 - 单用户新手引导与核心关卡时间线排查
描述：提取特定 user/distinct_id 在 5/8 ~ 5/9 的数据，
      按时间顺序穿插展示【核心关卡（-5后缀）】与【新手引导步骤】，用于人工核对关卡和引导的匹配情况。
================================================================================
*/
WITH RawEvents AS (
    SELECT 
        "#distinct_id" AS distinct_id,
        "$part_event" AS event_name,
        "#event_time" AS event_time,
        gamer_guide_id,
        gamer_skip,
        CAST(stage_id AS BIGINT) AS stage_id
    FROM ta.v_event_13
    WHERE "$part_date" IN ('2026-05-08', '2026-05-09')
      AND "#distinct_id" = '953f5d69-cf31-4e31-8979-bfd10abd1280'
      AND "$part_event" IN ('gamer_guide', 'stage_fight')
),

EventTimeline AS (
    SELECT 
        r.event_time,
        r.event_name,
        CASE 
            WHEN r.event_name = 'gamer_guide' THEN 
                COALESCE(g."gamer_guide_id@guide_name", '步骤ID_' || CAST(CAST(r.gamer_guide_id AS INTEGER) AS VARCHAR) || '_' || CAST(CAST(r.gamer_skip AS INTEGER) AS VARCHAR))
            WHEN r.event_name = 'stage_fight' THEN 
                ds."stage_id@stage_name_real"
        END AS event_detail
    FROM RawEvents r
    LEFT JOIN ta_dim.dim_13_0_18504 g 
        ON CAST(CAST(r.gamer_guide_id AS INTEGER) AS VARCHAR) = CAST(CAST(g."gamer_guide_id@gamer_guide_id" AS INTEGER) AS VARCHAR) 
        AND CAST(CAST(r.gamer_skip AS INTEGER) AS VARCHAR) = CAST(CAST(g."gamer_guide_id@gamer_skip" AS INTEGER) AS VARCHAR)
    LEFT JOIN ta_dim.dim_13_0_18203 ds 
        ON r.stage_id = ds."stage_id@stage_id"
)

SELECT 
    event_time AS "事件时间",
    event_name AS "事件类型 (gamer_guide / stage_fight)",
    event_detail AS "事件详情 (关卡名 / 引导步骤名)"
FROM EventTimeline
WHERE event_name = 'gamer_guide' 
   OR (event_name = 'stage_fight' AND SPLIT(event_detail, '-')[3] = '5')
ORDER BY event_time ASC;
