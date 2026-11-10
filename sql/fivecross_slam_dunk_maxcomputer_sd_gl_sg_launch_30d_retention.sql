-- ================================================================================
-- 游戏: 灌篮高手 (Slam Dunk)
-- 区域: 全球版 GL (63002013)
-- 国家: 新加坡 (SG)
-- 描述: 新加坡开服首月（2020-11-25至2020-12-24）每日大盘与新增用户留存、LTV (区分 iOS / Android)
-- 指标: 新用户, 活跃用户, 付费率, ARPU, 留存2-7, LTV1-7
-- 引擎: MaxCompute (ODPS)
-- ================================================================================

SET odps.sql.hive.compatible = TRUE;

WITH 
-- 1. 每日活跃数据聚合 (计算 DAU, NUU, 活跃付费率, ARPU)
DailyAgg AS (
    SELECT 
        u.day AS stat_day,
        CASE WHEN LOWER(u.os) LIKE '%ios%' THEN 'iOS' ELSE 'Android' END AS os,
        COUNT(DISTINCT u.lcm_id) AS dau,
        COUNT(DISTINCT CASE WHEN CAST(u.reg_day AS BIGINT) = u.day THEN u.lcm_id END) AS nuu,
        COUNT(DISTINCT CASE WHEN u.purchase > 0 THEN u.lcm_id END) AS puu,
        SUM(u.purchase) AS revenue
    FROM dm_platform.daily_lcx_user_info u
    WHERE u.app_id = 63002013
      AND u.country_code = 'SG'
      AND u.day BETWEEN 20201125 AND 20201224
    GROUP BY 
        u.day, 
        CASE WHEN LOWER(u.os) LIKE '%ios%' THEN 'iOS' ELSE 'Android' END
),

-- 2. 新增用户留存及LTV基础明细
CohortBase AS (
    SELECT 
        u.lcm_id,
        CASE WHEN LOWER(u.os) LIKE '%ios%' THEN 'iOS' ELSE 'Android' END AS os,
        CAST(u.reg_day AS BIGINT) AS reg_day,
        u.day,
        u.purchase,
        DATEDIFF(
            TO_DATE(CAST(u.day AS STRING), 'yyyyMMdd'),
            TO_DATE(CAST(u.reg_day AS STRING), 'yyyyMMdd'),
            'dd'
        ) AS days_since_reg
    FROM dm_platform.daily_lcx_user_info u
    WHERE u.app_id = 63002013
      AND u.country_code = 'SG'
      -- 注册日在首月
      AND CAST(u.reg_day AS BIGINT) BETWEEN 20201125 AND 20201224
      -- 活跃日覆盖到注册后充分天数以保证7留和LTV7完整 (20201224 + 7天 = 20201231)
      AND u.day <= 20201231
),

-- 3. 按注册日聚合留存与LTV
CohortAgg AS (
    SELECT 
        reg_day,
        os,
        COUNT(DISTINCT lcm_id) AS cohort_size,
        
        -- 留存人数 (D2到D7)
        COUNT(DISTINCT CASE WHEN days_since_reg = 1 THEN lcm_id END) AS ret_d2,
        COUNT(DISTINCT CASE WHEN days_since_reg = 2 THEN lcm_id END) AS ret_d3,
        COUNT(DISTINCT CASE WHEN days_since_reg = 3 THEN lcm_id END) AS ret_d4,
        COUNT(DISTINCT CASE WHEN days_since_reg = 4 THEN lcm_id END) AS ret_d5,
        COUNT(DISTINCT CASE WHEN days_since_reg = 5 THEN lcm_id END) AS ret_d6,
        COUNT(DISTINCT CASE WHEN days_since_reg = 6 THEN lcm_id END) AS ret_d7,
        
        -- LTV 累计收入
        SUM(CASE WHEN days_since_reg < 1 THEN purchase ELSE 0 END) AS rev_ltv1,
        SUM(CASE WHEN days_since_reg < 2 THEN purchase ELSE 0 END) AS rev_ltv2,
        SUM(CASE WHEN days_since_reg < 3 THEN purchase ELSE 0 END) AS rev_ltv3,
        SUM(CASE WHEN days_since_reg < 4 THEN purchase ELSE 0 END) AS rev_ltv4,
        SUM(CASE WHEN days_since_reg < 5 THEN purchase ELSE 0 END) AS rev_ltv5,
        SUM(CASE WHEN days_since_reg < 6 THEN purchase ELSE 0 END) AS rev_ltv6,
        SUM(CASE WHEN days_since_reg < 7 THEN purchase ELSE 0 END) AS rev_ltv7
    FROM CohortBase
    GROUP BY 
        reg_day,
        os
)

-- 4. 汇总输出大盘与对应注册日期的 LTV/留存
SELECT 
    d.stat_day AS `日期`,
    d.os AS `系统(OS)`,
    d.dau AS `活跃用户(DAU)`,
    d.nuu AS `新用户(NUU)`,
    ROUND(d.puu * 1.0 / NULLIF(d.dau, 0), 4) AS `活跃付费率`,
    ROUND(d.revenue * 1.0 / NULLIF(d.dau, 0), 4) AS `ARPU`,
    
    -- 留存率
    ROUND(c.ret_d2 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `次留(D2)`,
    ROUND(c.ret_d3 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `3留(D3)`,
    ROUND(c.ret_d4 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `4留(D4)`,
    ROUND(c.ret_d5 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `5留(D5)`,
    ROUND(c.ret_d6 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `6留(D6)`,
    ROUND(c.ret_d7 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `7留(D7)`,
    
    -- LTV
    ROUND(c.rev_ltv1 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV1`,
    ROUND(c.rev_ltv2 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV2`,
    ROUND(c.rev_ltv3 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV3`,
    ROUND(c.rev_ltv4 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV4`,
    ROUND(c.rev_ltv5 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV5`,
    ROUND(c.rev_ltv6 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV6`,
    ROUND(c.rev_ltv7 * 1.0 / NULLIF(c.cohort_size, 0), 4) AS `LTV7`
FROM DailyAgg d
LEFT JOIN CohortAgg c
    ON d.stat_day = c.reg_day AND d.os = c.os
ORDER BY d.stat_day ASC, d.os ASC;
