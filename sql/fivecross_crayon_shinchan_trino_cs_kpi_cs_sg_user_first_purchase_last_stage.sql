/*
================================================================================
项目：蜡笔小新 - 用户首充前最后的主线副本统计
描述：统计用户在历史首次充值前，最后一次攻打的主线副本 (stage_type=1001) 的关卡分布。
输出格式：返回 stage_id (关卡ID) 和 num (人数) 两列数据，方便制作饼图等图表。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

-- 1. 提取目标用户的首次充值时间 (锁定在目标查询周期内首充的用户)
TargetFirstCharge AS (
    SELECT 
        fc."#user_id",
        fc.first_charge_time
    FROM (
        SELECT 
            "#user_id",
            "#event_time" AS first_charge_time,
            "$part_date",
            ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY "#event_time" ASC) as charge_rank
        FROM ta.v_event_13
        WHERE "$part_event" = 'charge'
          AND (sandbox IS NULL OR sandbox = FALSE)
          AND (is_freebuy IS NULL OR is_freebuy = FALSE)
    ) fc
    LEFT JOIN UserBlacklist ub ON fc."#user_id" = ub."#user_id"
    WHERE fc.charge_rank = 1 
      AND ub."#user_id" IS NULL
      AND ${PartDate:date1} -- 过滤首充日期在目标范围内的用户
),

-- 2. 提取这些首充用户在充值前的所有主线副本战斗记录 (stage_type=1001)
MainStageFights AS (
    SELECT 
        v."#user_id",
        CAST(v.stage_id AS INTEGER) AS stage_id,
        "stage_id@stage_name_real",
        v."#event_time" AS fight_time
    FROM ta.v_event_13 v
    INNER JOIN TargetFirstCharge fc ON v."#user_id" = fc."#user_id"
    LEFT JOIN ta_dim.dim_13_0_18203 ds ON v.stage_id = ds."stage_id@stage_id"
    WHERE SPLIT("stage_id@stage_name_real",'-')[3] = '5'
       AND  v."#event_name" = 'stage_fight'
      AND v.a_rst[1].key = '1001' 
      AND v."#event_time" < fc.first_charge_time -- 必须在充值之前
),

-- 3. 取出每个用户首充前的最后一次战斗
LastFightBeforeCharge AS (
    SELECT 
        "#user_id",
        stage_id,
        "stage_id@stage_name_real"
    FROM (
        SELECT 
            "#user_id",
            stage_id,
            "stage_id@stage_name_real",
            ROW_NUMBER() OVER(PARTITION BY "#user_id" ORDER BY fight_time DESC) as fight_rank
        FROM MainStageFights
    ) t
    WHERE fight_rank = 1
),

-- 4. 汇总每个关卡的人数
StageStats AS (
    SELECT 
        stage_id,
        "stage_id@stage_name_real",
        COUNT(DISTINCT "#user_id") AS num
    FROM LastFightBeforeCharge
    GROUP BY 1,2
)

-- 5. 输出关卡ID和对应的人数
SELECT 
    "stage_id@stage_name_real",
    num
FROM StageStats
ORDER BY 1 ASC;
