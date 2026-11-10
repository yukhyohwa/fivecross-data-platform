-- 3. 玩法参与渗透率 (D+0, D+1, D+2)
WITH new_roles AS (
    SELECT 
        DISTINCT v."#user_id",
        DATE(v."$part_date") AS reg_date,
        CASE WHEN lm."#account_id@lom" = 'A' THEN 'Y' WHEN lm."#account_id@lom" = 'B' THEN 'N' ELSE '未填写问卷' END AS is_lom
    FROM ta.v_event_13 v
    LEFT JOIN ta_dim.dim_13_0_18164 lm ON v."#account_id" = lm."#account_id@role_id"
    WHERE v."$part_date" BETWEEN '2026-05-08' AND '2026-05-10'
      AND v."$part_event" = 'new_role'
),
cohort_size AS (
    SELECT is_lom, COUNT(DISTINCT "#user_id") AS total_users
    FROM new_roles
    WHERE is_lom IN ('Y', 'N')
    GROUP BY 1
),
StageLogs AS (
    SELECT 
        v."#user_id",
        DATE_DIFF('day', n.reg_date, DATE(v."$part_date")) AS diff_days,
        CAST(v.a_rst[1].key AS VARCHAR) AS stage_type
    FROM ta.v_event_13 v
    INNER JOIN new_roles n ON v."#user_id" = n."#user_id"
    WHERE v."#event_name" = 'stage_fight'
      AND v."$part_date" >= '2026-05-08'
      AND n.is_lom IN ('Y', 'N')
    
    UNION ALL 
    
    SELECT 
        v."#user_id",
        DATE_DIFF('day', n.reg_date, DATE(v."$part_date")) AS diff_days,
        CASE 
            WHEN v."#event_name" = 'match3_combo' THEN '三消'
            WHEN v."#event_name" = 'pet_travel_start' THEN '宠物旅行'
            WHEN v."#event_name" = 'board_tile_land' THEN '大富翁'
        END AS stage_type
    FROM ta.v_event_13 v
    INNER JOIN new_roles n ON v."#user_id" = n."#user_id"
    WHERE v."#event_name" IN ('match3_combo','pet_travel_start','board_tile_land')
      AND v."$part_date" >= '2026-05-08'
      AND n.is_lom IN ('Y', 'N')
),
StageDailyUsers AS (
    SELECT 
        s.is_lom,
        s.diff_days,
        s.stage_type,
        COUNT(DISTINCT s."#user_id") AS stage_users
    FROM (
        SELECT n.is_lom, l.diff_days, l.stage_type, l."#user_id"
        FROM StageLogs l
        INNER JOIN new_roles n ON l."#user_id" = n."#user_id"
    ) s
    WHERE s.diff_days IN (0, 1, 2)
    GROUP BY 1, 2, 3
),
DimStage AS (
    SELECT * FROM (VALUES
        (1001,'主线副本'), (1002,'挑战玩具小偷'), (1003,'挑战怪物扭蛋人'),
        (1005,'守护古老城市'), (1004,'竞技场'), (1018,'挑战邪恶的兔兔玩偶'),
        (1019,'挑战邪恶喵巴士'), (1006,'守护海滩'), (1007,'恐龙拳手大挑战'),
        (1022,'花圃内pvp副本'), (1008,'影像副本'), (1023,'切磋'),
        (1009,'穿越魔法之门'), (1021,'积木大乱斗'), (1024,'跨服竞技场'),
        (1010,'宝物预览副本'), (1011,'忍道・甜酸试炼'), (1012,'冒险试炼'),
        (1013,'宠物旅行'), (1014,'动感超人试炼—钻地土拨鼠'),
        (1015,'动感超人试炼—挖铲土拨鼠'), (1016,'动感超人试炼—挖矿土拨鼠'),
        (1017,'动感超人比赛'), (1020,'社团大评比')
    ) AS t(stage_type, stage_name)
)
SELECT 
    sd.is_lom AS "是否菇勇者",
    CONCAT('D+', CAST(sd.diff_days AS VARCHAR)) AS "注册天数",
    COALESCE(ds.stage_name, sd.stage_type) AS "玩法名称",
    sd.stage_users AS "参与人数",
    cs.total_users AS "同期组内总注册数",
    CAST(sd.stage_users AS DOUBLE) / NULLIF(cs.total_users, 0) AS "参与渗透率"
FROM StageDailyUsers sd
LEFT JOIN cohort_size cs ON sd.is_lom = cs.is_lom
LEFT JOIN DimStage ds ON sd.stage_type = CAST(ds.stage_type AS VARCHAR)
ORDER BY sd.is_lom, sd.diff_days ASC, sd.stage_users DESC;
