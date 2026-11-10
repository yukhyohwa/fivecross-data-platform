/*
================================================================================
项目：蜡笔小新 - 主线副本通过人数统计
描述：统计主线副本 (stage_type=1001) 各关卡的通关人数与战斗次数。
     由于没有战斗胜负记录，所以采用“是否有更高关卡的挑战记录”来判断当前关卡是否通过。
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
      AND v."#event_name" = 'stage_fight'
      AND v.a_rst[1].key = '1001'
      AND ub."#user_id" IS NULL
    GROUP BY 1, 2, 3, 4 
),

UserMaxStage AS (
    -- 计算每个人在所选时间段内挑战过的最高关卡
    SELECT 
        stage_type,
        stage_name,
        "#account_id",
        stage_id,
        fight_times,
        MAX(stage_id) OVER (PARTITION BY "#account_id") AS max_stage_id
    FROM FightLogs
)

SELECT 
    us.stage_type,
    SPLIT(ds."stage_id@stage_name_real",':')[1] AS main_stage_type,
    us.stage_name,
    ds."stage_id@stage_name_real",
    us.stage_id,
    -- 只有当该玩家历史最高挑战关卡 > 当前关卡时，才认为当前关卡已通过
    COUNT(DISTINCT CASE WHEN us.max_stage_id > us.stage_id THEN us."#account_id" END) AS pass_users,
    SUM(us.fight_times) AS fight_times
FROM UserMaxStage us
LEFT JOIN ta_dim.dim_13_0_18203 ds ON us.stage_id = ds."stage_id@stage_id"
WHERE SPLIT("stage_id@stage_name_real",'-')[3] = '5'
GROUP BY 1, 2, 3, 4, 5
ORDER BY us.stage_id ASC;
