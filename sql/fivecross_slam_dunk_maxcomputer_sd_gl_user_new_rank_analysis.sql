-- ***************************************************************
-- 1月1日~5日新增用户段位卡点与流失深度分析 (修复版 - 引入登录活跃判定)
-- 目标：分析新用户在各段位的停留时间、卡点位置以及最终流失点
-- 环境：MaxCompute (ODPS)
-- ***************************************************************

WITH NewUsers AS (
    -- 1. 锁定 1月1日~5日 新增用户
    SELECT DISTINCT lcm_id, day as reg_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 63002013 
      AND day BETWEEN 20260101 AND 20260105 
      AND reg_day = day
      AND is_water = '不是水'
),

UserActiveDays AS (
    -- 2. 获取这些新用户在全周期内的真实【登录活跃轨迹】
    -- 不再信任全量更新的 Snapshot 表日期，改用活跃日志表
    SELECT 
        u.lcm_id,
        u.reg_day,
        l.day as active_day
    FROM NewUsers u
    JOIN dm_platform.daily_lcx_user_info l ON u.lcm_id = l.lcm_id
    WHERE l.app_id = 63002013 
      AND l.day >= 20260101
      AND l.is_water = '不是水'
),

UserFinalActive AS (
    -- 3. 确定用户真正的最后活跃日 (基于登录日志)
    SELECT 
        lcm_id, 
        MAX(active_day) as real_final_day
    FROM UserActiveDays
    GROUP BY lcm_id
),

DailyTrail AS (
    -- 4. 核心轨迹：只对【有登录的天数】关联段位快照
    -- 这样计算出的 stay_days 才是真实的活跃天数，而非快照持有的自然天数
    SELECT /*+ MAPJOIN(d) */
        a.lcm_id,
        a.reg_day,
        a.active_day as day,
        s.match_rank,
        d.rank_name,
        f.real_final_day
    FROM UserActiveDays a
    JOIN UserFinalActive f ON a.lcm_id = f.lcm_id
    -- 仅关联活跃当天的快照
    JOIN (SELECT *, '1' as a1 FROM g63002013.daily_user_snapshot WHERE day >= 20260101) s ON a.lcm_id = s.mbga_uid AND a.active_day = s.day
    -- 使用 MAPJOIN 处理维度表，解决非等值关联限制
    JOIN (SELECT *, '1' as a1 FROM g63002013.dim_rank) d ON s.a1 = d.a1
    WHERE s.match_rank >= d.min_star AND s.match_rank <= d.max_star
),

UserRankAgg AS (
    -- 5. 用户维度段位聚合
    SELECT 
        lcm_id,
        rank_name,
        COUNT(DISTINCT day) as stay_days,
        MIN(day) as enter_day,
        MAX(day) as last_day_in_rank,
        MAX(real_final_day) as real_final_day,
        -- 流失定义：12号以后再也没登录过的用户 (即最后登录日 <= 20260112)
        CASE WHEN MAX(real_final_day) <= 20260112 THEN 1 ELSE 0 END as is_overall_churned,
        -- 流失位置：该用户已流失，且该段位是他最后登录时所处的段位
        CASE WHEN MAX(real_final_day) <= 20260112 AND MAX(day) = MAX(real_final_day) THEN 1 ELSE 0 END as is_churn_here
    FROM DailyTrail
    GROUP BY lcm_id, rank_name
)

-- 6. 最终汇总
SELECT 
    rank_name as `段位名称`,
    COUNT(DISTINCT lcm_id) as `到达人数`,
    
    -- 整体流失情况
    SUM(is_overall_churned) as `到达人数(已流失)`, 
    ROUND(SUM(is_overall_churned) * 100.0 / COUNT(DISTINCT lcm_id), 2) as `流失率(%)`,
    
    -- 活跃指标
    ROUND(AVG(stay_days), 2) as `平均活跃天数`,
    COUNT(DISTINCT CASE WHEN stay_days >= 5 THEN lcm_id END) as `活跃卡住>5天人数`,
    
    -- 核心流失点：最后停留在此段位流失数
    SUM(is_churn_here) as `最后停留在此活跃流失数`
FROM UserRankAgg
GROUP BY rank_name
ORDER BY MIN(enter_day) ASC;
