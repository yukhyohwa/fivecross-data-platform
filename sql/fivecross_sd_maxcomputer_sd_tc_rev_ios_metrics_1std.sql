SELECT 
    '灌篮繁体(TC)' AS "游戏",
    t.target_day AS "日期",
    COALESCE(c.nu, 0) AS nu,
    COALESCE(dm.au, 0) AS au,
    COALESCE(dm.paying_users, 0) AS "付费用户",
    ROUND(COALESCE(dm.revenue, 0), 2)/6.9 AS "金额",
    ROUND((CAST(COALESCE(dm.paying_users, 0) AS DOUBLE) / NULLIF(dm.au, 0)), 4) AS "付费率",
    ROUND(COALESCE(dm.revenue, 0) / NULLIF(dm.au, 0), 2)/6.9 AS arpu,
    ROUND(COALESCE(dm.revenue, 0) / NULLIF(dm.paying_users, 0), 2)/6.9 AS arppu,
    -- 计算 LTV
    ROUND(c.rev_LTV1 / NULLIF(c.nu, 0), 2)/6.9 AS ltv1,
    ROUND(c.rev_LTV2 / NULLIF(c.nu, 0), 2)/6.9 AS ltv2,
    ROUND(c.rev_LTV3 / NULLIF(c.nu, 0), 2)/6.9 AS ltv3,
    ROUND(c.rev_LTV4 / NULLIF(c.nu, 0), 2)/6.9 AS ltv4,
    ROUND(c.rev_LTV5 / NULLIF(c.nu, 0), 2)/6.9 AS ltv5,
    ROUND(c.rev_LTV6 / NULLIF(c.nu, 0), 2)/6.9 AS ltv6,
    ROUND(c.rev_LTV7 / NULLIF(c.nu, 0), 2)/6.9 AS ltv7
FROM (
    SELECT 20200421 AS target_day
    UNION ALL 
    SELECT 20200527 AS target_day
) t
LEFT JOIN (
    -- 每日活跃与付费情况 (仅限 iOS)
    SELECT 
        day AS current_day,
        COUNT(DISTINCT lcm_id) AS au,
        COUNT(DISTINCT CASE WHEN purchase > 0 THEN lcm_id END) AS paying_users,
        SUM(COALESCE(purchase, 0)) AS revenue
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = '23002013'
      AND day IN (20200421, 20200527)
      AND LOWER(os) LIKE '%ios%'
      AND is_water = '不是水'
    GROUP BY day
) dm ON t.target_day = dm.current_day
LEFT JOIN (
    -- 新增用户以及后续 7 日内 LTV 追踪
    SELECT 
        c.reg_day,
        COUNT(DISTINCT c.lcm_id) AS nu,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') = 0 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV1,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 1 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV2,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 2 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV3,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 3 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV4,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 4 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV5,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 5 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV6,
        SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 6 THEN COALESCE(d.purchase, 0) ELSE 0 END) AS rev_LTV7
    FROM (
        SELECT DISTINCT
            reg_day,
            lcm_id,
            TO_DATE(CAST(reg_day AS STRING), 'yyyymmdd') AS reg_date
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = '23002013'
          AND day IN (20200421, 20200527)
          AND reg_day = day
          AND LOWER(os) LIKE '%ios%'
          AND is_water = '不是水'
    ) c
    LEFT JOIN dm_platform.daily_lcx_user_info d
      ON c.lcm_id = d.lcm_id
      AND d.app_id = '23002013'
      AND d.day >= c.reg_day 
      AND d.day BETWEEN 20200421 AND 20200605 -- 框定分区提升速度
      AND DATEDIFF(TO_DATE(CAST(d.day AS STRING), 'yyyymmdd'), c.reg_date, 'dd') <= 6
      AND d.is_water = '不是水'
    GROUP BY c.reg_day
) c ON t.target_day = c.reg_day
ORDER BY t.target_day ASC;
