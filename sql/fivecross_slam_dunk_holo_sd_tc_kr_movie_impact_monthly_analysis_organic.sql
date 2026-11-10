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
-- 1. 月活 (提取 2022年10月 到 2023年6月，10月用于左关联判定11月的状态)
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

-- 2. 目标周期的新增 (仅扫描 2022年11月 到 2023年6月)
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

-- 3. 提取用户的来源归因 (只扫描相同日期减轻大表压力)
user_source_raw AS (
    SELECT '23002013' AS app_id, lcm_id, source FROM g23002013.daily_lcx_user_info WHERE day BETWEEN 20211001 AND 20230630
    UNION ALL
    SELECT '33002013' AS app_id, lcm_id, source FROM g33002013.daily_lcx_user_info WHERE day BETWEEN 20211001 AND 20230630
    UNION ALL
    SELECT '63002013' AS app_id, lcm_id, source FROM g63002013.daily_lcx_user_info WHERE day BETWEEN 20211001 AND 20230630
),
user_source AS (
    SELECT 
        app_id, 
        lcm_id, 
        CASE 
            WHEN MAX(source) IN ('market', 'effect') THEN '买量市场用户(Market)' 
            ELSE '自然分发用户(Organic)' 
        END AS source_type
    FROM user_source_raw
    GROUP BY 1, 2
),

-- 4. 计算 MAU 和 回流 (核心逻辑, 按用户类型分组)
active_calc AS (
    SELECT 
        a.app_id, 
        a.month, 
        COALESCE(s.source_type, '自然分发用户(Organic)') AS source_type,
        COUNT(DISTINCT a.lcm_id) AS mau,
        -- 如果"上个月未活跃"并且"本月并非新注册"，则是严格意义的老用户回流
        COUNT(DISTINCT CASE WHEN b.lcm_id IS NULL AND reg.lcm_id IS NULL THEN a.lcm_id END) AS returning_users
    FROM user_active_months a
    -- 关联获取用户市场属性
    LEFT JOIN user_source s ON a.app_id = s.app_id AND a.lcm_id = s.lcm_id
    -- 关联判断【上个月】是否活跃 (利用跨年公式防止后续复用到跨越 12 月的年份发生 BUG)
    LEFT JOIN user_active_months b 
        ON a.app_id = b.app_id 
       AND a.lcm_id = b.lcm_id 
       AND b.month = CASE WHEN a.month % 100 = 1 THEN (a.month / 100 - 1) * 100 + 12 ELSE a.month - 1 END
    -- 关联判断是否属于【当月新增用户】
    LEFT JOIN user_reg_months reg
        ON a.app_id = reg.app_id AND a.month = reg.month AND a.lcm_id = reg.lcm_id
    WHERE a.month BETWEEN 202111 AND 202306
    GROUP BY 1, 2, 3
),

-- 5. 统计月新增用户数 (同样按来源拆分)
new_calc AS (
    SELECT 
        r.app_id,
        r.month,
        COALESCE(s.source_type, '自然分发用户(Organic)') AS source_type,
        COUNT(DISTINCT r.lcm_id) as new_users
    FROM user_reg_months r
    LEFT JOIN user_source s ON r.app_id = s.app_id AND r.lcm_id = s.lcm_id
    GROUP BY 1, 2, 3
)

-- 6. 合并并输出格式化表格
SELECT 
    CASE 
        WHEN COALESCE(a.app_id, n.app_id) = '23002013' THEN '灌篮台湾(TC)' 
        WHEN COALESCE(a.app_id, n.app_id) = '33002013' THEN '灌篮韩国(KR)' 
        WHEN COALESCE(a.app_id, n.app_id) = '63002013' THEN '灌篮全球(GL)' 
    END AS "地区",
    COALESCE(a.month, n.month) AS "月份",
    COALESCE(a.source_type, n.source_type) AS "用户类型",
    COALESCE(a.mau, 0) AS "月总活跃(MAU)",
    COALESCE(n.new_users, 0) AS "月新增用户",
    COALESCE(a.returning_users, 0) AS "月老回流用户",
    COALESCE(a.mau, 0) - COALESCE(n.new_users, 0) - COALESCE(a.returning_users, 0) AS "连月活跃的铁杆用户"
FROM active_calc a
FULL OUTER JOIN new_calc n 
    ON a.app_id = n.app_id AND a.month = n.month AND a.source_type = n.source_type
ORDER BY 
    "地区" DESC, 
    "月份" ASC, 
    "用户类型" ASC;
