/*
================================================================================
Game: Slam Dunk (灌篮高手) 
Region: TC (Taiwan 23002013) & KR (Korea 33002013)
Purpose: 评估《灌篮高手》电影上映影响 (2022.11 - 2023.02)
Metrics: 月活跃 (MAU), 月新增用户, 月回流用户
Definition: 
  - 月回流用户: 本月属于月活用户，并且上一个月没有活跃老用户（剔除当月新增用户）。
  - 需要提取前一个月即 2022-10 的活跃数据作为基础。
Environment: Hologres / MaxCompute
================================================================================
*/

WITH 
-- 1. 月活 (提取 2022年10月 到 2023年2月，10月用于左关联判定11月的状态)
monthly_active AS (
    SELECT '23002013' as app_id, month, lcm_id FROM g23002013.lcx_user_active WHERE month BETWEEN 202110 AND 202306
    UNION ALL
    SELECT '33002013' as app_id, month, lcm_id FROM g33002013.lcx_user_active WHERE month BETWEEN 202110 AND 202306
    UNION ALL
    SELECT '63002013' as app_id, month, lcm_id FROM g63002013.lcx_user_active WHERE month BETWEEN 202110 AND 202306
),
user_active_months AS (
    SELECT DISTINCT app_id, month, lcm_id FROM monthly_active
),

-- 2. 目标周期的新增 (仅扫描 2022年11月 到 2023年2月)
monthly_reg AS (
    SELECT '23002013' as app_id, day/100 AS month, lcm_id FROM g23002013.lcx_user_reg WHERE day/100 BETWEEN 202111 AND 202306
    UNION ALL 
    SELECT '33002013' as app_id, day/100 AS month, lcm_id FROM g33002013.lcx_user_reg WHERE day/100 BETWEEN 202111 AND 202306
    UNION ALL
    SELECT '63002013' as app_id, day/100 AS month, lcm_id FROM g63002013.lcx_user_reg WHERE day/100 BETWEEN 202111 AND 202306
),
user_reg_months AS (
    SELECT DISTINCT app_id, month, lcm_id FROM monthly_reg
),

-- 3. 计算 MAU 和 回流 (核心逻辑)
active_calc AS (
    SELECT 
        a.app_id, 
        a.month, 
        COUNT(DISTINCT a.lcm_id) AS mau,
        -- 如果"上个月未活跃"并且"本月并非新注册"，则是严格意义的老用户回流
        COUNT(DISTINCT CASE WHEN b.lcm_id IS NULL AND reg.lcm_id IS NULL THEN a.lcm_id END) AS returning_users
    FROM user_active_months a
    -- 关联判断【上个月】是否活跃 (利用跨年公式防止后续复用到跨越 12 月的年份发生 BUG)
    LEFT JOIN user_active_months b 
        ON a.app_id = b.app_id 
       AND a.lcm_id = b.lcm_id 
       AND b.month = CASE WHEN a.month % 100 = 1 THEN (a.month / 100 - 1) * 100 + 12 ELSE a.month - 1 END
    -- 关联判断是否属于【当月新增用户】
    LEFT JOIN user_reg_months reg
        ON a.app_id = reg.app_id AND a.month = reg.month AND a.lcm_id = reg.lcm_id
    WHERE a.month BETWEEN 202111 AND 202306
    GROUP BY 1, 2
),

-- 4. 统计月新增用户数
new_calc AS (
    SELECT 
        app_id,
        month,
        COUNT(DISTINCT lcm_id) as new_users
    FROM user_reg_months
    GROUP BY 1, 2
)

-- 5. 合并并输出格式化表格
SELECT 
    CASE 
        WHEN a.app_id = '23002013' THEN '灌篮台湾(TC)' 
        WHEN a.app_id = '33002013' THEN '灌篮韩国(KR)' 
        WHEN a.app_id = '63002013' THEN '灌篮全球(GL)' 
    END AS "地区",
    a.month AS "月份",
    a.mau AS "月活跃用户(MAU)",
    COALESCE(n.new_users, 0) AS "月新增用户",
    a.returning_users AS "月回流用户",
    a.mau - COALESCE(n.new_users, 0) - a.returning_users AS "连续活跃用户"
FROM active_calc a
LEFT JOIN new_calc n ON a.app_id = n.app_id AND a.month = n.month
ORDER BY 
    "地区" DESC, 
    "月份" ASC;
