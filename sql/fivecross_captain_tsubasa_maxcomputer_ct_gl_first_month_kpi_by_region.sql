/*
================================================================================
Game    : Captain Tsubasa / 足球小将 GL (足小)
App ID  : 65002005
Engine  : MaxCompute (ODPS) / 阿里云 MaxCompute
Table   : dm_platform.daily_lcx_user_info
Purpose : 计算足小开服首月（分区域）的各项关键指标：
          1. 月活跃人数 (MAU)
          2. 付费金额 (Total Revenue)
          3. 首月月付费率 (月付费人数 / MAU)
          4. 首月月ARPU (Monthly ARPU = 付费金额 / MAU)
          5. 首月月ARPPU (Monthly ARPPU = 付费金额 / 月付费人数)
          6. 首月平均DAU (Average DAU = 总人天数 / 开服天数)
          7. 首月日加权付费率 (Weighted Daily Pay Rate = 总付费人天数 / 总人天数)
          8. 首月加权日ARPU (Weighted Daily ARPU = 付费金额 / 总人天数)
          9. 首月加权月ARPU (Weighted Monthly ARPU = 加权日ARPU * 30)

说明：
- 字段映射：使用 country_code 进行 ISO 2位国家代码映射
- 日期范围：开服首月默认 20231205 至 20240103（共30天，查明准确开服日期后修改 WHERE 里的 day 即可）
================================================================================
*/

WITH data_with_region AS (
    SELECT 
        t.lcm_id,
        t.day,
        COALESCE(CAST(t.purchase AS DOUBLE), 0.0) AS daily_purchase,
        CASE 
            -- 1. 简体字 (中国大陆)
            WHEN UPPER(COALESCE(t.country_code, '')) IN ('CN') THEN '简体字 (中国大陆)'

            -- 2. 繁体字圈·韩国
            WHEN UPPER(COALESCE(t.country_code, '')) IN ('TW', 'HK', 'MO', 'KR') THEN '繁体字圈·韩国'

            -- 3. 东南亚
            WHEN UPPER(COALESCE(t.country_code, '')) IN ('TH', 'VN', 'SG', 'MY', 'PH', 'ID', 'MM', 'LA', 'KH', 'BN', 'TL') THEN '东南亚'

            -- 4. 中东
            WHEN UPPER(COALESCE(t.country_code, '')) IN ('EG', 'SA', 'AE', 'QA', 'KW', 'BH', 'OM', 'TR', 'IQ', 'JO', 'IL', 'YE', 'IR', 'SY', 'LB', 'AF') THEN '中东'

            -- 5. 米州·ヨロッバ (美洲 & 欧洲)
            WHEN UPPER(COALESCE(t.country_code, '')) IN (
                -- 欧洲
                'PT', 'HR', 'UA', 'BY', 'RO', 'RS', 'HU', 'BG', 'SI', 'BA', 'LU', 'GR', 'MK', 'AT', 'SK', 'CZ', 'IE', 'AD', 'MT', 'SM', 'EE', 'LT', 'LV', 'CY', 'FI', 'CH', 'SE', 'NO', 'DK', 'NL', 'BE', 'GB', 'FR', 'DE', 'IT', 'ES', 'MC', 'MD', 'XK',
                -- 美洲
                'US', 'CA', 'EC', 'DO', 'DM', 'CR', 'BO', 'VE', 'NI', 'SV', 'PA', 'HN', 'CU', 'GT', 'UY', 'PY', 'PR', 'TT', 'JM', 'HT', 'SR', 'BB', 'BS', 'BZ', 'GY', 'LC', 'AW', 'BR', 'AR', 'MX', 'CL', 'PE', 'CO'
            ) THEN '米州·ヨロッバ'

            -- 6. 其他 (包含大洋洲、非洲、中亚、南亚等)
            ELSE 'その他' 
        END AS region
    FROM dm_platform.daily_lcx_user_info t
    WHERE t.app_id = 65002005
      -- AND t.is_water = '不是水'
      AND t.day >= 20231205
      AND t.day <= 20240103
),

region_summary AS (
    -- 分区域统计
    SELECT 
        region,
        COUNT(DISTINCT day) AS days_cnt,
        COUNT(DISTINCT lcm_id) AS mau,
        ROUND(SUM(daily_purchase), 2) AS total_revenue,
        COUNT(DISTINCT CASE WHEN daily_purchase > 0 THEN lcm_id END) AS paying_users,
        COUNT(1) AS total_user_days,
        SUM(CASE WHEN daily_purchase > 0 THEN 1 ELSE 0 END) AS total_pay_user_days
    FROM data_with_region
    GROUP BY region

    UNION ALL

    -- 全服汇总
    SELECT 
        '【全服汇总】' AS region,
        COUNT(DISTINCT day) AS days_cnt,
        COUNT(DISTINCT lcm_id) AS mau,
        ROUND(SUM(daily_purchase), 2) AS total_revenue,
        COUNT(DISTINCT CASE WHEN daily_purchase > 0 THEN lcm_id END) AS paying_users,
        COUNT(1) AS total_user_days,
        SUM(CASE WHEN daily_purchase > 0 THEN 1 ELSE 0 END) AS total_pay_user_days
    FROM data_with_region
)

SELECT 
    region AS `区域`,
    mau AS `首月月活跃人数(MAU)`,
    total_revenue AS `首月付费金额(RMB)`,
    paying_users AS `首月月付费人数`,
    ROUND(paying_users * 1.0 / NULLIF(mau, 0), 4) AS `首月月付费率`,
    ROUND(total_revenue * 1.0 / NULLIF(mau, 0), 2) AS `首月月ARPU`,
    ROUND(total_revenue * 1.0 / NULLIF(paying_users, 0), 2) AS `首月月ARPPU`,
    ROUND(total_user_days * 1.0 / NULLIF(days_cnt, 0), 2) AS `首月平均DAU`,
    total_user_days AS `首月总人天DAU`,
    ROUND(total_pay_user_days * 1.0 / NULLIF(total_user_days, 0), 4) AS `首月日加权付费率`,
    ROUND(total_revenue * 1.0 / NULLIF(total_user_days, 0), 4) AS `首月加权日ARPU`,
    ROUND((total_revenue * 1.0 / NULLIF(total_user_days, 0)) * 30, 2) AS `首月加权月ARPU`
FROM region_summary
ORDER BY 
    CASE WHEN region = '【全服汇总】' THEN 1 ELSE 0 END,
    total_revenue DESC;
