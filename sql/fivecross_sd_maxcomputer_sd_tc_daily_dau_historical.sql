/*
================================================================================
游戏: 灌篮高手 (Slam Dunk)
区域: 繁体大区 (TC - Traditional Chinese, Taiwan/Hong Kong/Macao)
描述: 2019年至今的每日 DAU (Daily Active Users)
数据源: dm_platform.daily_lcx_user_info (标准 BI 汇总表)
App ID: 23002013
环境: MaxCompute (ODPS)
================================================================================
*/

-- 开启 Hive 兼容模式以支持标准 SQL 语法
SET odps.sql.hive.compatible = TRUE;

SELECT 
    day AS "日期",
    COUNT(DISTINCT device_id) AS "DAU"
FROM dm_platform.daily_lcx_user_info
WHERE app_id = 23002013
  AND day >= 20190101
GROUP BY day
ORDER BY day DESC;
