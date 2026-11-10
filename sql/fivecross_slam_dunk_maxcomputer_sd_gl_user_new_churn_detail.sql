-- ***************************************************************
-- 新用户+90天回流用户流失明细统计 (灌篮高手 63002013)
-- 目标：获取 1月1日~10日新用户及90天回流用户中流失用户的明细数据
-- 字段：用户群标签，用户id，登录几天，最终等级，比赛场数
-- ***************************************************************

WITH 
    -- 1. 筛选目标周期的新用户
    -- 1a. 基础日志与上一次登录时间
    user_log AS (
        SELECT 
            lcm_id, 
            day, 
            reg_day,
            is_water,
            LAG(day, 1) OVER (PARTITION BY lcm_id ORDER BY day) as last_login_day
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 63002013 
          AND day >= 20250601 -- 向前追溯约半年以识别回流
    ),
    
    -- 1b. 计算登录间隔
    calculated_gap AS (
        SELECT
            lcm_id,
            day,
            reg_day,
            is_water,
            last_login_day,
            DATEDIFF(
                TO_DATE(CAST(day AS STRING), 'yyyymmdd'), 
                TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 
                'dd'
            ) as days_since_last
        FROM user_log
    ),

    -- 1c. 筛选目标周期的 新用户 + 90天回流用户
    TargetNewUsers AS (
        SELECT 
            lcm_id,
            reg_day,
            day as event_day,
            CASE 
                WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN '新增'
                ELSE '回流'
            END AS user_type,
            CASE 
                WHEN day BETWEEN 20260101 AND 20260105 THEN 'Batch_01_05'
                WHEN day BETWEEN 20260106 AND 20260110 THEN 'Batch_06_10'
            END AS cohort_group
        FROM calculated_gap
        WHERE day BETWEEN 20260101 AND 20260110
          AND is_water = '不是水'
          -- 条件：新用户 (注册日期=当天) 或 超过90天没登录的回流用户 (含追溯期外首次登录)
          AND ( (CAST(reg_day AS BIGINT) = CAST(day AS BIGINT)) OR (last_login_day IS NULL OR days_since_last > 90) )
    ),

    -- 2. 识别流失用户及其最后的活跃日期 (业务库使用 mbga_uid)
    ChurnedUsers AS (
        SELECT 
            mbga_uid, 
            MAX(day) as final_active_day
        FROM g63002013.daily_game_log
        WHERE day >= 20260101
        GROUP BY mbga_uid
        HAVING MAX(day) < 20260116 
    ),

    -- 3. 统计比赛、登录天数及获取最后等级
    DetailStats AS (
        SELECT 
            mbga_uid,
            COUNT(DISTINCT day) as login_days_cnt,
            COUNT(DISTINCT CASE 
                WHEN a_typ IN ('match_fight','arena_fight','com_fight','custom_fight','tower_fight') 
                THEN GET_JSON_OBJECT(a_tar, '$.match_id') 
            END) as match_cnt,
            -- 提取最后活跃时的等级 (拼接日期+时间戳+等级，取最大值对应的后缀)
            CAST(SUBSTR(MAX(CONCAT(day, LPAD(CAST(log_t AS STRING), 10, '0'), CAST(param1 AS STRING))), 19) AS BIGINT) as final_level
        FROM g63002013.daily_game_log
        WHERE day >= 20260101
        GROUP BY mbga_uid
    ),

    -- 4. 定位流失前的最后一步
    FinalEventLog AS (
        SELECT 
            mbga_uid,
            a_typ as churn_event_id,
            GET_JSON_OBJECT(a_tar, '$.guide_id') as guide_id,
            ROW_NUMBER() OVER(PARTITION BY mbga_uid ORDER BY day DESC, log_t DESC) as last_step_rank
        FROM g63002013.daily_game_log
        WHERE day >= 20260101
    )

-- 5. 输出明细
SELECT 
    u.cohort_group AS `用户群标签`,
    u.user_type AS `用户类型`,
    u.lcm_id AS `用户id`,
    u.event_day AS `注册/回流日期`,
    c.final_active_day AS `最后登录日期`,
    s.login_days_cnt AS `登录几天`,
    s.final_level AS `最终等级`,
    s.match_cnt AS `打了几场比赛`,
    f.churn_event_id AS `流失事件ID`,
    CASE WHEN f.churn_event_id = 'Dmp101003' THEN f.guide_id ELSE NULL END AS `引导ID`
FROM TargetNewUsers u
JOIN ChurnedUsers c ON u.lcm_id = c.mbga_uid
JOIN DetailStats s ON u.lcm_id = s.mbga_uid
JOIN FinalEventLog f ON u.lcm_id = f.mbga_uid AND f.last_step_rank = 1
ORDER BY `用户群标签`, `打了几场比赛` DESC;
