-- ***************************************************************
-- 1月1日~5日与6~10日新用户+90天回流用户流失点对比 (灌篮高手 63002013)
-- 目标：对比两个周期新用户及90天回流用户流失前的最后一步 a_typ (事件ID)
-- ***************************************************************


 -- ***************************************************************
-- 1月1日~5日与6~10日新用户+90天回流用户流失点对比 (灌篮高手 63002013)
-- 目标：对比两个周期新用户及90天回流用户流失前的最后一步 a_typ (事件ID)
-- ***************************************************************

WITH 
    -- 1. 筛选目标周期的新用户 (使用 lcm_id)
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
    ChurnedUserBase AS (
        SELECT 
            mbga_uid, 
            MAX(day) as final_active_day
        FROM g63002013.daily_game_log
        WHERE day >= 20260101
        GROUP BY mbga_uid
        HAVING MAX(day) < 20260116 
    ),

    -- 3. 定位流失前的最后一条 a_typ
    FinalEventLog AS (
        SELECT 
            u.cohort_group,
            u.lcm_id,
            l.a_typ,
            GET_JSON_OBJECT(a_tar,"$.guide_id") AS guide_id,
            -- 通过时间戳排序取最后一条
            ROW_NUMBER() OVER(PARTITION BY l.mbga_uid ORDER BY l.day DESC, l.log_t DESC) as last_step_rank
        FROM TargetNewUsers u
        JOIN ChurnedUserBase c ON u.lcm_id = c.mbga_uid
        JOIN (
        SELECT *
        FROM g63002013.daily_game_log
        WHERE day >= 20260101
        ) l ON u.lcm_id = l.mbga_uid AND c.final_active_day = l.day
    )

-- 4. 对比统计
SELECT 
    cohort_group,
    a_typ AS churn_event_id,
    CASE WHEN a_typ = 'Dmp101003' THEN guide_id END AS guide_id,
    COUNT(DISTINCT lcm_id) AS churn_user_cnt,
    ROUND(COUNT(DISTINCT lcm_id) * 100.0 / SUM(COUNT(DISTINCT lcm_id)) OVER(PARTITION BY cohort_group), 2) AS churn_ratio_pct
FROM FinalEventLog
WHERE last_step_rank = 1
GROUP BY cohort_group, a_typ, CASE WHEN a_typ = 'Dmp101003' THEN guide_id END
ORDER BY cohort_group ASC, churn_user_cnt DESC;
