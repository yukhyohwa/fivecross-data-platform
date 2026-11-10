WITH CoreOldUsers AS (
    SELECT DISTINCT lcm_id
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = '63002013'
      AND (country_code = 'TH' OR country_name = 'Thailand')
      AND reg_day < '20260221'
      AND is_water = '不是水'  -- 关键点：去水
      AND day >= '20260301'
)
-- 统计这批真实核心玩家在 3月11日 前后的日活跃留存比率
SELECT 
    t1.day AS "日期",
    COUNT(DISTINCT t1.lcm_id) AS "活跃老玩家(当日)",
    COUNT(DISTINCT t2.lcm_id) AS "次日依然活跃数",
    ROUND(CAST(COUNT(DISTINCT t2.lcm_id) AS DOUBLE) / COUNT(DISTINCT t1.lcm_id), 4) AS "次日复登比率"
FROM dm_platform.daily_lcx_user_info t1
INNER JOIN CoreOldUsers c ON t1.lcm_id = c.lcm_id
LEFT JOIN dm_platform.daily_lcx_user_info t2 ON t1.lcm_id = t2.lcm_id 
    AND t2.app_id = '63002013'
    AND t2.day = TO_CHAR(DATEADD(TO_DATE(t1.day, 'yyyyMMdd'), 1, 'dd'), 'yyyyMMdd')
    AND t2.is_water = '不是水' -- 保证次日也是真实行为
WHERE t1.app_id = '63002013'
  AND t1.day BETWEEN '20260301' AND '20260322'
  AND t1.is_water = '不是水'
GROUP BY t1.day
ORDER BY t1.day ASC;
