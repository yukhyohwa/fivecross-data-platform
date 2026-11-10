-- 繁体灌篮 S28 赛季【最快】达标 170 星的前 500 名玩家统计
-- 环境: MaxCompute (ODPS)
-- 区域: 繁体灌篮 (Traditional Chinese - g23002013)

WITH deduplicated_snapshot AS (
    -- 1. 处理合服导致的重复 user_id：保留最后登录时间 (last_login) 最大的记录
    SELECT * FROM (
        SELECT 
            user_id as gid,
            mbga_uid as lcx_id,
            nickname,
            level,
            CAST(match_rank AS BIGINT) as match_rank,
            last_login,
            day,
            ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY CAST(last_login AS BIGINT) DESC) as rn
        FROM g23002013.daily_user_snapshot
        WHERE day = '20260204'
          AND CAST(match_rank AS BIGINT) >= 170
    ) t 
    WHERE rn = 1
),

attained_history AS (
    -- 2. 查找 S28 赛季内所有活跃且达标 170 星的日期记录
    -- 必须满足 a_typ = 'Dmp101002' 确保该日期玩家真实登录，而非僵尸数据
    SELECT 
        s.user_id,
        s.day as reach_day,
        CAST(s.match_rank AS BIGINT) as rank_at_time
    FROM g23002013.daily_user_snapshot s
    INNER JOIN g23002013.daily_game_log l ON s.user_id = l.user_id AND s.day = l.day
    WHERE s.day BETWEEN 20251119 AND 20260204
      AND l.a_typ = 'Dmp101002'
      AND CAST(s.match_rank AS BIGINT) >= 170
),

first_attainment AS (
    -- 3. 计算每个用户首次达标的日期
    SELECT 
        user_id,
        MIN(reach_day) as first_attained_day
    FROM attained_history
    GROUP BY user_id
),

top_500_by_time AS (
    -- 4. 按“获得时间”排序，选取全服最快达标的前 500 名活跃用户
    SELECT 
        s.gid,
        s.lcx_id,
        s.nickname,
        s.level,
        s.match_rank as s28_settle_rank,
        TO_CHAR(FROM_UNIXTIME(CAST(s.last_login AS BIGINT)), 'yyyy-mm-dd hh:mi:ss') as s28_last_login,
        f.first_attained_day
    FROM deduplicated_snapshot s
    INNER JOIN first_attainment f ON s.gid = f.user_id
    ORDER BY f.first_attained_day ASC, s.match_rank DESC
    LIMIT 500
),

new_season_first_login AS (
    -- 5. 统计 2/5 09:00 新赛季开启后的最早动作时间
    SELECT 
        user_id,
        MIN(FROM_UNIXTIME(CAST(log_t AS BIGINT))) AS first_active_time
    FROM (
        SELECT user_id, log_t FROM g23002013.daily_game_log WHERE day >= 20260205 AND a_typ = 'Dmp101002'
        UNION ALL
        SELECT user_id, log_t FROM g23002013.game_log WHERE dt >= 20260205 AND a_typ = 'Dmp101002'
    ) combined
    WHERE FROM_UNIXTIME(CAST(log_t AS BIGINT)) >= DATETIME '2026-02-05 09:00:00'
    GROUP BY user_id
)

SELECT 
    t.gid,
    t.lcx_id,
    t.nickname,
    t.level,
    t.s28_settle_rank,
    t.s28_last_login,
    t.first_attained_day,
    TO_CHAR(n.first_active_time, 'yyyy-mm-dd hh:mi:ss') AS first_login_after_0205_0900
FROM top_500_by_time t
LEFT JOIN new_season_first_login n ON t.gid = n.user_id
ORDER BY t.first_attained_day ASC;
