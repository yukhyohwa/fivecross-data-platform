/*
================================================================================
Game    : Slam Dunk 灌篮高手
Region  : TC (繁体 23002013) 开服日 2020-05-27
          KR (韩国 33002013) 开服日 2020-07-29
          GL (全球 63002013) 开服日 2020-11-25
Purpose : 三个地区 近 1 年 & 近 2 年 整体活跃用户数（AU）
          去水 / 不去水 各一套
Metrics :
  - 近 1 年 AU : 20250401 ~ 20260331 期间有记录的去重用户数
  - 近 2 年 AU : 20240401 ~ 20260331 期间有记录的去重用户数
  - 去水    : is_water = '不是水'
  - 不去水  : 不加 is_water 过滤（含水号/内部账号）
Engine  : MaxCompute (ODPS)
Notes   :
  - 活跃定义: 统计期间内在 daily_lcx_user_info 有任意一条记录即视为活跃
  - 日期范围请按实际截止日调整上界（当前设为 20260331）
================================================================================
*/

SET odps.sql.hive.compatible = TRUE;

SELECT
    CASE CAST(app_id AS STRING)
        WHEN '23002013' THEN '灌篮繁体(TC)'
        WHEN '33002013' THEN '灌篮韩国(KR)'
        WHEN '63002013' THEN '灌篮全球(GL)'
    END                                                     AS "游戏",

    -- 近 1 年（去水）
    COUNT(DISTINCT CASE
        WHEN day BETWEEN 20250401 AND 20260331
         AND is_water = '不是水'
        THEN lcm_id END)                                    AS "近1年AU(去水)",

    -- 近 1 年（含水）
    COUNT(DISTINCT CASE
        WHEN day BETWEEN 20250401 AND 20260331
        THEN lcm_id END)                                    AS "近1年AU(含水)",

    -- 近 2 年（去水）
    COUNT(DISTINCT CASE
        WHEN day BETWEEN 20240401 AND 20260331
         AND is_water = '不是水'
        THEN lcm_id END)                                    AS "近2年AU(去水)",

    -- 近 2 年（含水）
    COUNT(DISTINCT CASE
        WHEN day BETWEEN 20240401 AND 20260331
        THEN lcm_id END)                                    AS "近2年AU(含水)"

FROM dm_platform.daily_lcx_user_info
WHERE app_id IN (23002013, 33002013, 63002013)
  AND day BETWEEN 20240401 AND 20260331   -- 分区谓词：覆盖近2年最大范围
GROUP BY
    CAST(app_id AS STRING)
ORDER BY
    CAST(app_id AS STRING) ASC;
