
/*
================================================================================
Game    : Slam Dunk  灌篮高手 (TC / KR / GL)
Report  : 各地区开服至今累计数据汇总
Metrics :
  - 累计注册用户数 (Total New Users)
  - 累计营收总额 (Total Revenue / RMB)
Engine  : MaxCompute (ODPS)
================================================================================
*/

WITH raw_data AS (
    SELECT 
        CASE 
            WHEN app_id = 23002013 THEN '灌篮繁体(TC)'
            WHEN app_id = 33002013 THEN '灌篮韩国(KR)'
            WHEN app_id = 63002013 THEN '灌篮全球(GL)'
            ELSE '其它'
        END AS game_region,
        app_id,
        lcm_id,
        reg_day,
        purchase
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id IN (23002013, 33002013, 63002013)
      AND is_water = '不是水'
      -- 过滤确保数据晚于各自开服日期
      AND (
          (app_id = 23002013 AND day >= 20200527) OR
          (app_id = 33002013 AND day >= 20200729) OR
          (app_id = 63002013 AND day >= 20201125)
      )
)

SELECT 
    game_region      AS "地区名称",
    app_id           AS "AppID",
    -- 开服至今注册用户总数
    COUNT(DISTINCT lcm_id) AS "累计注册用户数",
    -- 开服至今流水总额 (RMB)
    ROUND(SUM(purchase), 2) AS "累计营收(RMB)"
FROM raw_data
GROUP BY game_region,app_id;