/*
================================================================================
项目：蜡笔小新 - 主线副本通过人数统计
描述：统计主线副本 (stage_type=1001) 各关卡的通关人数与战斗次数。
备注：已加入黑名单过滤，字段名保持原始设定。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

dim_stage AS (
    SELECT * 
    FROM (VALUES
        (1001,'主线副本'),
        (1002,'挑战玩具小偷'),
        (1003,'挑战怪物扭蛋人'),
        (1005,'守护古老城市'),
        (1004,'竞技场'),
        (1018,'挑战邪恶的兔兔玩偶'),
        (1019,'挑战邪恶喵巴士'),
        (1006,'守护海滩'),
        (1007,'恐龙拳手大挑战'),
        (1022,'花圃内pvp副本'),
        (1008,'影像副本'),
        (1023,'切磋'),
        (1009,'穿越魔法之门'),
        (1021,'积木大乱斗'),
        (1024,'跨服竞技场'),
        (1010,'宝物预览副本'),
        (1011,'忍道・甜酸试炼'),
        (1012,'冒险试炼'),
        (1013,'宠物旅行'),
        (1014,'动感超人试炼—钻地土拨鼠'),
        (1015,'动感超人试炼—挖铲土拨鼠'),
        (1016,'动感超人试炼—挖矿土拨鼠'),
        (1017,'动感超人比赛'),
        (1020,'社团大评比')
    ) AS t(stage_type, stage_name)
),

FightLogs AS (
    SELECT 
        CAST(v.a_rst[1].key AS INT) AS stage_type,
        ds.stage_name,
        v."#account_id",
        CAST(v.stage_id AS INTEGER) AS stage_id,
        COUNT(v."#event_time") AS fight_times
    FROM ta.v_event_13 v
    LEFT JOIN dim_stage ds ON CAST(v.a_rst[1].key AS INT) = ds.stage_type
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE ${PartDate:date1} 
      AND v."#event_name" IN ('stage_fight')
      AND v.a_rst[1].key = '1001'
      AND ub."#user_id" IS NULL
      -- AND result = 0 -- 若需严格统计“通关”成功人数，可取消此行注释
    GROUP BY 1, 2, 3, 4 
)

SELECT 
    stage_type,
    stage_name,
    stage_id,
    COUNT(DISTINCT "#account_id") AS pass_users,
    SUM(fight_times) AS fight_times
FROM FightLogs
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
