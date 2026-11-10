-- S28 Source Table Generators (Strict Excel Column Mapping)
-- Target Excel: 20251208_球员数据_S28.xlsx
-- Timeframe: 2026-02-05 12:00:00 to 2026-04-06 23:59:59

-- Common Table Expression: Active Users in S28
WITH s28_active_users AS (
    SELECT DISTINCT user_id
    FROM g23002013.daily_user_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND last_login >= 1770264000 -- 2026-02-05 12:00:00 UTC+8
),

-- Valid Rank Sessions (Must have 2 results: True/False)
valid_rank_sessions AS (
    SELECT session, day
    FROM g23002013.daily_match_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND type = 'RankH3V3'
      AND ai = 'false'
    GROUP BY session, day 
    HAVING COUNT(DISTINCT result) = 2
),

-- High Talent Users (Hardcoded >= 58, ID length 4-6)
high_talent_users AS (
    SELECT day, user_id, card_id
    FROM (
        SELECT day, user_id, card_id, 
               COUNT(DISTINCT CASE WHEN LENGTH(s_id) BETWEEN 4 AND 6 THEN s_id END) AS node_count
        FROM g23002013.daily_user_card_snapshot
        LATERAL VIEW EXPLODE(SPLIT(skill, ',|\\\[|\\\]|\\"')) t AS s_id
        WHERE day BETWEEN 20260205 AND 20260406
          AND status = '1'
        GROUP BY day, user_id, card_id
    ) t
    WHERE node_count >= 58
)

-- 1. 排位_源 (Rank Source)
SELECT /*+ MAPJOIN(d) */
    d.rank_id AS rank_id,         
    d.rank_name AS rank_name, 
    m.type AS match_type,    
    v.total_match_count AS total_matches, 
    COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')) AS card_name,    
    COUNT(*) AS appearances,   
    COALESCE(b_stats.total_bans, 0) AS ban_count, 
    SUM(CASE WHEN m.result = 'true' THEN 1 ELSE 0 END) AS wins, 
    SUM(score) AS total_score, 
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoN') AS INT)) AS two_attempts,    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoG') AS INT)) AS two_goals,       
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.layupN') AS INT)) AS layup_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.layupG') AS INT)) AS layup_goals,   
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.dunkN') AS INT)) AS dunk_attempts,  
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.dunkG') AS INT)) AS dunk_goals,     
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeN') AS INT)) AS three_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeG') AS INT)) AS three_goals,   
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.blockG') AS INT)) AS blocks,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.stealG') AS INT)) AS steals,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.rebG') AS INT)) AS rebounds,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.asitN') AS INT)) AS assists,        
    
    AVG(CAST(GET_JSON_OBJECT(m.player, '$.mark') AS DOUBLE) / 10000) AS rating, 
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.intercept') AS INT)) AS intercepts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.groundN') AS INT)) AS floor_balls,  
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.ballT') AS INT)) AS ball_time,      
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoN_open') AS INT)) AS open_mid_attempts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoG_open') AS INT)) AS open_mid_goals,    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeN_open') AS INT)) AS open_three_attempts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeG_open') AS INT)) AS open_three_goals,    
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.downN') AS INT)) AS ankle_break,       
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.downND') AS INT)) AS ankle_broken,      
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.blockND') AS INT)) AS blocked,           
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.beJamMidN') AS INT)) AS contested_mid_attempts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.beJamMidG') AS INT)) AS contested_mid_goals,    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.beJamThreeN') AS INT)) AS contested_three_attempts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.beJamThreeG') AS INT)) AS contested_three_goals,    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.interND') AS INT)) AS intercepted,       
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.stealND') AS INT)) AS stolen,            
    
    m.day                    

FROM g23002013.daily_match_snapshot m
JOIN s28_active_users a ON m.user_id = a.user_id
JOIN valid_rank_sessions vs ON m.session = vs.session AND m.day = vs.day
LEFT JOIN (
    SELECT DISTINCT rank_id, rank_name, min_star, max_star 
    FROM g23002013.dim_rank
) d ON CAST(SPLIT(m.star, '#')[0] AS INT) BETWEEN d.min_star AND d.max_star
LEFT JOIN g23002013.dim_card dc ON GET_JSON_OBJECT(m.player, '$.player') = dc.id
LEFT JOIN (
    SELECT 
        l.day,
        REGEXP_REPLACE(GET_JSON_OBJECT(l.a_tar, '$.ban'), '\\[|\\]|"', '') AS card_id,
        COUNT(DISTINCT GET_JSON_OBJECT(l.a_tar, '$.match_id')) AS total_bans
    FROM g23002013.daily_game_log l
    WHERE l.day BETWEEN 20260205 AND 20260406
      AND l.a_typ = 'peak_fight' -- In MyQuery, Rank Ban logic isn't explicit, but Peak uses peak_fight
    GROUP BY l.day, REGEXP_REPLACE(GET_JSON_OBJECT(l.a_tar, '$.ban'), '\\[|\\]|"', '')
) b_stats ON m.day = b_stats.day AND GET_JSON_OBJECT(m.player, '$.player') = b_stats.card_id
CROSS JOIN (
    SELECT COUNT(DISTINCT session) AS total_match_count
    FROM valid_rank_sessions
) v
WHERE m.day BETWEEN 20260205 AND 20260406
GROUP BY m.day, COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')), d.rank_id, d.rank_name, m.type, b_stats.total_bans, v.total_match_count
;

-- 1.5. 天赋50%_源 (Talent 50% Source)
SELECT /*+ MAPJOIN(d) */
    d.rank_id AS rank_id,         
    d.rank_name AS rank_name,     
    m.type AS match_type,         
    v.total_match_count AS total_matches, 
    COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')) AS card_name, 
    COUNT(*) AS appearances,      
    COUNT(DISTINCT m.user_id) AS user_count, 
    SUM(CASE WHEN m.result = 'true' THEN 1 ELSE 0 END) AS wins, 
    SUM(score) AS total_score,    
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoN') AS INT)) AS two_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoG') AS INT)) AS two_goals,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.layupN') AS INT)) AS layup_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.layupG') AS INT)) AS layup_goals,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.dunkN') AS INT)) AS dunk_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.dunkG') AS INT)) AS dunk_goals,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeN') AS INT)) AS three_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeG') AS INT)) AS three_goals,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.blockG') AS INT)) AS blocks,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.stealG') AS INT)) AS steals,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.rebG') AS INT)) AS rebounds,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.asitN') AS INT)) AS assists,
    
    AVG(CAST(GET_JSON_OBJECT(m.player, '$.mark') AS DOUBLE) / 10000) AS rating, 
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.intercept') AS INT)) AS intercepts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.groundN') AS INT)) AS floor_balls,  
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.ballT') AS INT)) AS ball_time,      
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoN_open') AS INT)) AS open_mid_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoG_open') AS INT)) AS open_mid_goals,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeN_open') AS INT)) AS open_three_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeG_open') AS INT)) AS open_three_goals,
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.downN') AS INT)) AS ankle_break,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.downND') AS INT)) AS ankle_broken,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.blockND') AS INT)) AS blocked,           

    m.day

FROM g23002013.daily_match_snapshot m
JOIN s28_active_users a ON m.user_id = a.user_id
JOIN valid_rank_sessions vs ON m.session = vs.session AND m.day = vs.day
JOIN high_talent_users tc ON m.day = tc.day AND m.user_id = tc.user_id AND GET_JSON_OBJECT(m.player, '$.player') = tc.card_id
LEFT JOIN (
    SELECT DISTINCT rank_id, rank_name, min_star, max_star 
    FROM g23002013.dim_rank
) d ON CAST(SPLIT(m.star, '#')[0] AS INT) BETWEEN d.min_star AND d.max_star
LEFT JOIN g23002013.dim_card dc ON GET_JSON_OBJECT(m.player, '$.player') = dc.id
CROSS JOIN (
    SELECT COUNT(DISTINCT session) AS total_match_count
    FROM valid_rank_sessions
) v
WHERE m.day BETWEEN 20260205 AND 20260406
GROUP BY m.day, COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')), d.rank_id, d.rank_name, m.type, v.total_match_count
;

-- 2. 巅峰赛_源 (Peak Source)
WITH s28_active_users AS (
    SELECT DISTINCT user_id
    FROM g23002013.daily_user_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND last_login >= 1770264000 
)

SELECT
    m.day,
    '巅峰赛' AS type,          
    COUNT(*) AS total_matches, 
    COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')) card_name,    
    COUNT(*) AS appearances,   
    COALESCE(b_stats.total_bans, 0) AS ban_count, 
    SUM(CASE WHEN m.mvp = 'true' THEN 1 ELSE 0 END) AS mvp_count, 
    SUM(CASE WHEN m.result = 'true' THEN 1 ELSE 0 END) AS wins,   
    
    SUM(score) AS total_score, 
    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoN') AS INT)) AS two_attempts,    
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.twoG') AS INT)) AS two_goals,       
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.layupN') AS INT)) AS layup_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.layupG') AS INT)) AS layup_goals,   
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.dunkN') AS INT)) AS dunk_attempts,  
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.dunkG') AS INT)) AS dunk_goals,     
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeN') AS INT)) AS three_attempts,
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.threeG') AS INT)) AS three_goals,   
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.blockG') AS INT)) AS blocks,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.stealG') AS INT)) AS steals,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.rebG') AS INT)) AS rebounds,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.asitN') AS INT)) AS assists,        
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.intercept') AS INT)) AS intercepts, 
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.ballT') AS INT)) AS ball_time,      
    SUM(CAST(GET_JSON_OBJECT(m.adata, '$.groundN') AS INT)) AS floor_balls,  
    AVG(CAST(GET_JSON_OBJECT(m.player, '$.mark') AS DOUBLE) / 10000) AS rating 

FROM g23002013.daily_match_snapshot m
JOIN s28_active_users a ON m.user_id = a.user_id
LEFT JOIN g23002013.dim_card dc ON GET_JSON_OBJECT(m.player, '$.player') = dc.id
LEFT JOIN (
    SELECT 
        l.day,
        REGEXP_REPLACE(GET_JSON_OBJECT(l.a_tar, '$.ban'), '\\[|\\]|"', '') AS card_id,
        COUNT(DISTINCT GET_JSON_OBJECT(l.a_tar, '$.match_id')) AS total_bans
    FROM g23002013.daily_game_log l
    WHERE l.day BETWEEN 20260205 AND 20260406
      AND l.a_typ = 'peak_fight'
    GROUP BY l.day, REGEXP_REPLACE(GET_JSON_OBJECT(l.a_tar, '$.ban'), '\\[|\\]|"', '')
) b_stats ON m.day = b_stats.day AND GET_JSON_OBJECT(m.player, '$.player') = b_stats.card_id
WHERE m.day BETWEEN 20260205 AND 20260406
  AND m.ai = 'false'
  AND m.type = 'SUMMITH3V3'
GROUP BY m.day, COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')), b_stats.total_bans
;


-- 6. 进攻技能_源 (Offensive Skills Source)
-- Columns: ['day', '段位', '球员', 'skillid', '技能使用', '技能成功', '空位出手', '空位进球',
--           '干扰出手', '干扰进球', '严重干扰出手', '严重干扰进球', '严重干扰2出手', '严重干扰2进球',
--           '被成功封盖次数', '被封盖次数', '技能', '段位序号']
-- 1. 首先定义活跃用户 CTE (必须包含在同一个 SQL 块中)
-- 1. 定义活跃用户 CTE
WITH s28_active_users AS (
    SELECT DISTINCT user_id
    FROM g23002013.daily_user_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND last_login >= 1770264000
)

-- 2. 执行主查询
SELECT
    t.day,
    t.rank_name,               -- 现在显示真实的段位名称
    COALESCE(dc.name, t.card_id) AS card_name,     
    t.skill_id,               
    SUM(t.skill_use) AS skill_use,           
    SUM(t.skill_success) AS skill_success,   
    SUM(t.open_attempt) AS open_attempt,     
    SUM(t.open_goal) AS open_goal,           
    SUM(t.contested_attempt) AS contested_attempt, 
    SUM(t.contested_goal) AS contested_goal,       
    SUM(t.heavy_attempt) AS heavy_attempt,         
    SUM(t.heavy_goal) AS heavy_goal,               
    SUM(t.severe_attempt) AS severe_attempt,       
    SUM(t.severe_goal) AS severe_goal,             
    SUM(t.blocked_success) AS blocked_success,     
    SUM(t.blocked_count) AS blocked_count,         
    NULL AS skill_name,       
    NULL AS rank_order        
FROM (
    -- Part A (基础技能)
    SELECT
        m.day,
        d.rank_name,           -- 提取段位
        GET_JSON_OBJECT(m.player, '$.player') AS card_id,
        GET_JSON_OBJECT(sk.skill_json, '$.skillid') AS skill_id,
        CAST(GET_JSON_OBJECT(sk.skill_json, '$.skillN') AS INT) AS skill_use,
        CAST(GET_JSON_OBJECT(sk.skill_json, '$.skillG') AS INT) AS skill_success,
        0 AS open_attempt, 0 AS open_goal,
        0 AS contested_attempt, 0 AS contested_goal,
        0 AS heavy_attempt, 0 AS heavy_goal,
        0 AS severe_attempt, 0 AS severe_goal,
        0 AS blocked_success, 0 AS blocked_count
    FROM g23002013.daily_match_snapshot m
    JOIN s28_active_users a ON m.user_id = a.user_id
    -- 关联段位维表
    LEFT JOIN (SELECT DISTINCT min_star, max_star, rank_name FROM g23002013.dim_rank) d 
      ON CAST(SPLIT(m.star, '#')[0] AS INT) BETWEEN d.min_star AND d.max_star
    LATERAL VIEW OUTER EXPLODE(SPLIT(REGEXP_REPLACE(SUBSTR(m.skill, 2, LENGTH(m.skill)-2), '\\}\\,\\{', '}||{'), '\\|\\|')) sk AS skill_json
    WHERE m.day BETWEEN 20260205 AND 20260406
      AND m.ai = 'false'
      AND m.type IN ('RankH3V3', 'HP3V3')
      AND m.skill IS NOT NULL AND m.skill <> '[]'

    UNION ALL

    -- Part B (详细技能)
    SELECT
        m.day,
        d.rank_name,           -- 提取段位
        GET_JSON_OBJECT(m.player, '$.player') AS card_id,
        GET_JSON_OBJECT(nsk.newskill_json, '$.skillid') AS skill_id,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.skillN') AS INT) AS skill_use,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.skillG') AS INT) AS skill_success,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.vacantN') AS INT) AS open_attempt,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.vacantG') AS INT) AS open_goal,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.beJamN') AS INT) AS contested_attempt,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.beJamG') AS INT) AS contested_goal,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.seriousN') AS INT) AS heavy_attempt,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.seriousG') AS INT) AS heavy_goal,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.serious2N') AS INT) AS severe_attempt,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.serious2G') AS INT) AS severe_goal,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.blockGD') AS INT) AS blocked_success,
        CAST(GET_JSON_OBJECT(nsk.newskill_json, '$.blockND') AS INT) AS blocked_count
    FROM g23002013.daily_match_snapshot m
    JOIN s28_active_users a ON m.user_id = a.user_id
    -- 关联段位维表
    LEFT JOIN (SELECT DISTINCT min_star, max_star, rank_name FROM g23002013.dim_rank) d 
      ON CAST(SPLIT(m.star, '#')[0] AS INT) BETWEEN d.min_star AND d.max_star
    LATERAL VIEW OUTER EXPLODE(SPLIT(REGEXP_REPLACE(SUBSTR(m.newskill, 2, LENGTH(m.newskill)-2), '\\}\\,\\{', '}||{'), '\\|\\|')) nsk AS newskill_json
    WHERE m.day BETWEEN 20260205 AND 20260406
      AND m.ai = 'false'
      AND m.type IN ('RankH3V3', 'HP3V3')
      AND m.newskill IS NOT NULL AND m.newskill <> '[]'
) t
LEFT JOIN g23002013.dim_card dc ON t.card_id = dc.id
WHERE LENGTH(t.skill_id) >= 8
GROUP BY t.day, t.rank_name, t.card_id, dc.name, t.skill_id
-- 过滤：只保留真正产生过使用的技能，且通过数据清洗 (使用次数 >= 被盖次数)
HAVING SUM(t.skill_use) > 0 AND SUM(t.skill_use) >= SUM(t.blocked_count)
;

-- 3. 球员养成 (Player Development)
-- Columns: ['vip', 'card_id', '近期付费', 'all_uu', 'get_uu', 'get_rate', '人均天赋进度', '天赋中位数', '满天赋比例', '球员', '付费类型']
-- 1. 定义活跃用户 CTE
WITH s28_active_users AS (
    SELECT DISTINCT user_id
    FROM g23002013.daily_user_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND last_login >= 1770264000
)

SELECT
    u_seg.vip AS vip,
    c.card_id,
    u_seg.recent_pay AS recent_pay,
    seg_stats.total_users AS all_uu,
    COUNT(DISTINCT c.user_id) AS get_uu,
    COUNT(DISTINCT c.user_id)/seg_stats.total_users AS get_rate,
    
    -- 人均天赋进度 (百分比)
    AVG( CAST(((LENGTH(c.skill) - LENGTH(REPLACE(c.skill, ',', ''))) - (LENGTH(c.skill) - LENGTH(REPLACE(c.skill, '[]', ''))) / 2 + 1) AS DOUBLE) / t.talent ) AS avg_talent_progress, 
    
    -- 天赋中位数 (百分比)
    PERCENTILE_APPROX( CAST(((LENGTH(c.skill) - LENGTH(REPLACE(c.skill, ',', ''))) - (LENGTH(c.skill) - LENGTH(REPLACE(c.skill, '[]', ''))) / 2 + 1) AS DOUBLE) / t.talent, 0.5 ) AS talent_median,
    
    -- 满天赋比例 (进度 >= 1.0)
    COUNT(CASE WHEN ((LENGTH(c.skill) - LENGTH(REPLACE(c.skill, ',', ''))) - (LENGTH(c.skill) - LENGTH(REPLACE(c.skill, '[]', ''))) / 2 + 1) / t.talent >= 1.0 THEN c.user_id ELSE NULL END) / COUNT(DISTINCT c.user_id) AS max_talent_ratio,
    
    COALESCE(dc.name, c.card_id) AS player_name,  
    NULL AS pay_type         

FROM g23002013.daily_user_card_snapshot c
JOIN s28_active_users a ON c.user_id = a.user_id
-- 关联天赋配置表获取总点数
LEFT JOIN g23002013.tmp_card_talent t ON c.card_id = t.card_id
-- 关联用户分段 (Vip & 付费状态)
JOIN (
    SELECT 
        user_id,
        CASE 
            WHEN total_pay = 0 THEN 'V0'
            WHEN total_pay BETWEEN 1 AND 6 THEN 'V1'
            WHEN total_pay BETWEEN 7 AND 30 THEN 'V2'
            WHEN total_pay BETWEEN 31 AND 100 THEN 'V3'
            WHEN total_pay BETWEEN 101 AND 500 THEN 'V4'
            WHEN total_pay BETWEEN 501 AND 1000 THEN 'V5'
            WHEN total_pay BETWEEN 1001 AND 3000 THEN 'V6' 
            WHEN total_pay BETWEEN 3001 AND 10000 THEN 'V7' 
            WHEN total_pay BETWEEN 10001 AND 30000 THEN 'V8' 
            WHEN total_pay >= 30001 THEN 'V9' 
        END AS vip,
        CASE WHEN total_pay > 0 THEN '近期付费' ELSE '近期无付费' END AS recent_pay
    FROM g23002013.daily_user_snapshot
    WHERE day = 20260406
) u_seg ON c.user_id = u_seg.user_id
-- 关联分段总人数全量 (分母)
JOIN (
    SELECT 
        CASE 
            WHEN u.total_pay = 0 THEN 'V0'
            WHEN u.total_pay BETWEEN 1 AND 6 THEN 'V1'
            WHEN u.total_pay BETWEEN 7 AND 30 THEN 'V2'
            WHEN u.total_pay BETWEEN 31 AND 100 THEN 'V3'
            WHEN u.total_pay BETWEEN 101 AND 500 THEN 'V4'
            WHEN u.total_pay BETWEEN 501 AND 1000 THEN 'V5'
            WHEN u.total_pay BETWEEN 1001 AND 3000 THEN 'V6' 
            WHEN u.total_pay BETWEEN 3001 AND 10000 THEN 'V7' 
            WHEN u.total_pay BETWEEN 10001 AND 30000 THEN 'V8' 
            WHEN u.total_pay >= 30001 THEN 'V9' 
        END AS vip,
        CASE WHEN u.total_pay > 0 THEN '近期付费' ELSE '近期无付费' END AS recent_pay,
        COUNT(DISTINCT u.user_id) AS total_users
    FROM g23002013.daily_user_snapshot u
    JOIN s28_active_users s ON u.user_id = s.user_id
    WHERE u.day = 20260406
    GROUP BY 
        CASE 
            WHEN u.total_pay = 0 THEN 'V0'
            WHEN u.total_pay BETWEEN 1 AND 6 THEN 'V1'
            WHEN u.total_pay BETWEEN 7 AND 30 THEN 'V2'
            WHEN u.total_pay BETWEEN 31 AND 100 THEN 'V3'
            WHEN u.total_pay BETWEEN 101 AND 500 THEN 'V4'
            WHEN u.total_pay BETWEEN 501 AND 1000 THEN 'V5'
            WHEN u.total_pay BETWEEN 1001 AND 3000 THEN 'V6' 
            WHEN u.total_pay BETWEEN 3001 AND 10000 THEN 'V7' 
            WHEN u.total_pay BETWEEN 10001 AND 30000 THEN 'V8' 
            WHEN u.total_pay >= 30001 THEN 'V9' 
        END,
        CASE WHEN u.total_pay > 0 THEN '近期付费' ELSE '近期无付费' END
) seg_stats ON u_seg.vip = seg_stats.vip AND u_seg.recent_pay = seg_stats.recent_pay

LEFT JOIN g23002013.dim_card dc ON c.card_id = dc.id
WHERE c.day BETWEEN 20260205 AND 20260406
  AND c.status = '1'
GROUP BY 
    u_seg.vip, 
    c.card_id, 
    dc.name,
    u_seg.recent_pay,
    seg_stats.total_users,
    t.talent
;



-- 4. 熟练度_源 (Proficiency Source) - Split into two parts as requested
-- Part 4a: Left Table (Talent >= 75%)
-- Columns: ['day', 'card_id', 'card_name', 'rank_name', '‘', '使用人数', '使用次数', '获胜', '段位']
-- Filter restriction: Talent > 75% (Note: Exact % depends on max talent. Assuming logic or placeholder)
WITH s28_active_users AS (
    SELECT DISTINCT user_id
    FROM g23002013.daily_user_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND last_login >= 1770264000
),

-- 2. 动态筛选天赋 >= 75% 的用户球员快照
-- 这里的逻辑参考了您提供的 tmp_card_talent 生成方式
talent_75_users AS (
    SELECT c.day, c.user_id, c.card_id, c.extra_info
    FROM (
        SELECT day, user_id, card_id, extra_info,
               COUNT(DISTINCT CASE WHEN LENGTH(s_id) BETWEEN 4 AND 6 THEN s_id END) AS node_count
        FROM g23002013.daily_user_card_snapshot
        LATERAL VIEW EXPLODE(SPLIT(skill, ',|\\\[|\\\]|\\"')) t AS s_id
        WHERE day BETWEEN 20260205 AND 20260406
          AND status = '1'
        GROUP BY day, user_id, card_id, extra_info
    ) c
    JOIN g23002013.tmp_card_talent t ON c.card_id = t.card_id
    WHERE c.node_count / t.talent >= 0.75
)

SELECT /*+ MAPJOIN(d, dc) */
    m.day,
    GET_JSON_OBJECT(m.player, '$.player') AS card_id,
    COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player')) AS card_name,
    d.rank_name AS rank_name, -- 段位名称
    CASE 
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 0 AND 99 THEN 'a入门'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 100 AND 499 THEN 'b见习'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 500 AND 1999 THEN 'c熟练'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 2000 AND 4999 THEN 'd精英'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 5000 AND 9999 THEN 'e大师'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) >= 10000 THEN 'f传说' 
        ELSE 'a入门'
    END AS proficiency, -- 熟练度
    COUNT(DISTINCT m.user_id) AS user_count, -- 使用人数
    COUNT(*) AS use_count,     -- 使用次数
    SUM(CASE WHEN m.result = 'true' THEN 1 ELSE 0 END) AS wins, -- 获胜
    d.rank_name AS rank       -- 段位
    
FROM g23002013.daily_match_snapshot m
JOIN s28_active_users a ON m.user_id = a.user_id
-- 关联动态计算的天赋 75% 结果集
JOIN talent_75_users c ON m.day = c.day 
    AND m.user_id = c.user_id 
    AND GET_JSON_OBJECT(m.player, '$.player') = c.card_id
LEFT JOIN g23002013.dim_card dc ON GET_JSON_OBJECT(m.player, '$.player') = dc.id
LEFT JOIN (
    SELECT DISTINCT rank_id, rank_name, min_star, max_star 
    FROM g23002013.dim_rank
) d ON CAST(SPLIT(m.star, '#')[0] AS INT) BETWEEN d.min_star AND d.max_star
WHERE m.day BETWEEN 20260205 AND 20260406
  AND m.ai = 'false'
GROUP BY 
    m.day, 
    GET_JSON_OBJECT(m.player, '$.player'), 
    dc.name, 
    d.rank_name,
    CASE 
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 0 AND 99 THEN 'a入门'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 100 AND 499 THEN 'b见习'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 500 AND 1999 THEN 'c熟练'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 2000 AND 4999 THEN 'd精英'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 5000 AND 9999 THEN 'e大师'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) >= 10000 THEN 'f传说' 
        ELSE 'a入门'
    END
;


-- Part 4b: Right Table (All Players / Proficiency Breakdown)
-- Columns: ['day.1', 'card_id.1', 'card_name.1', 'rank_name.1', '熟练度', '使用人数.1', '使用次数.1', '获胜.1', '段位.1']
WITH s28_active_users AS (
    SELECT DISTINCT user_id
    FROM g23002013.daily_user_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
      AND last_login >= 1770264000
)


SELECT /*+ MAPJOIN(d) */
    m.day AS day_1,
    GET_JSON_OBJECT(m.player, '$.player') AS card_id_1,
    COALESCE(dc.name, GET_JSON_OBJECT(m.player, '$.player'))  card_name_1,  -- card_name.1
    d.rank_name AS rank_name_1, -- 段位.1
    
    -- Proficiency Level Mapping
    CASE 
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 0 AND 99 THEN 'a入门'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 100 AND 499 THEN 'b见习'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 500 AND 1999 THEN 'c熟练'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 2000 AND 4999 THEN 'd精英'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 5000 AND 9999 THEN 'e大师'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) >= 10000 THEN 'f传说' 
        ELSE 'a入门'
    END AS proficiency, -- 熟练度
    
    COUNT(DISTINCT m.user_id) AS user_count_1, -- 使用人数.1
    COUNT(*) AS use_count_1,     -- 使用次数.1
    SUM(CASE WHEN m.result = 'true' THEN 1 ELSE 0 END) AS wins_1, -- 获胜.1
    d.rank_name AS rank_1       -- 段位.1

FROM g23002013.daily_match_snapshot m
JOIN s28_active_users a ON m.user_id = a.user_id
JOIN (
    SELECT day, user_id, card_id, extra_info
    FROM g23002013.daily_user_card_snapshot
    WHERE day BETWEEN 20260205 AND 20260406
) c ON m.day = c.day AND m.user_id = c.user_id AND GET_JSON_OBJECT(m.player, '$.player') = c.card_id
LEFT JOIN g23002013.dim_card dc ON GET_JSON_OBJECT(m.player, '$.player') = dc.id
LEFT JOIN (
    SELECT DISTINCT rank_id, rank_name, min_star, max_star 
    FROM g23002013.dim_rank
) d ON CAST(SPLIT(m.star, '#')[0] AS INT) BETWEEN d.min_star AND d.max_star
WHERE m.day BETWEEN 20260205 AND 20260406
  AND m.ai = 'false'
GROUP BY 
    m.day, 
    GET_JSON_OBJECT(m.player, '$.player'), 
    dc.name, 
    d.rank_name,
    CASE 
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 0 AND 99 THEN 'a入门'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 100 AND 499 THEN 'b见习'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 500 AND 1999 THEN 'c熟练'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 2000 AND 4999 THEN 'd精英'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) BETWEEN 5000 AND 9999 THEN 'e大师'
        WHEN CAST(GET_JSON_OBJECT(c.extra_info, '$.proficient') AS INT) >= 10000 THEN 'f传说' 
        ELSE 'a入门'
    END
;



