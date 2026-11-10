-- odps sql
-- ====================================================================================
-- 游戏名称 : 灌篮高手 (Slam Dunk)
-- 适用大区 : 韩国 (Korea, AppID = 33002013)
-- 需求描述 : 统计每天 1.新用户、2.老用户、3.回流用户（60天）的人数 (DAU) 与 收入（人民币 RMB）
-- 数据来源 : 数数 / 平台 BI 汇总表 dm_platform.daily_lcx_user_info
-- 引擎平台 : MaxCompute (ODPS)
--
-- 用户分类定义 (互斥且完备):
--   1. 新用户 (New Users)           : 当日注册并登录的用户 (reg_day = day)
--   2. 回流用户(60天) (Return Users) : 非当日注册，且距离上次登录间隔 >= 60 天的用户
--   3. 老用户 (Existing Old Users)  : 非当日注册，且距离上次登录间隔 < 60 天的常规活跃老用户
-- ====================================================================================

SET odps.sql.hive.compatible = TRUE;

WITH user_log AS (
    -- 1. 提取灌篮韩国区 (33002013) 用户的每日登录与付费记录，利用 Window 窗口函数计算上次登录日期
    SELECT
        lcm_id,
        day,
        CAST(reg_day AS BIGINT) AS reg_day,
        COALESCE(purchase, 0.0) AS daily_purchase,
        -- 取用户上一次登录的日期
        LAG(day, 1) OVER (PARTITION BY lcm_id ORDER BY day) AS last_login_day
    FROM dm_platform.daily_lcx_user_info
    WHERE app_id = 33002013
      AND is_water = '不是水'
      AND day >= 20200501 -- 向前追溯以准确计算开服初期及后续60天未登录间隔
),

calculated_user_type AS (
    -- 2. 计算登录间隔天数，并划分用户类型 (新用户 / 60天回流用户 / 老用户)
    SELECT
        lcm_id,
        day,
        reg_day,
        daily_purchase,
        DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 'dd') AS days_since_last,
        DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(reg_day AS STRING), 'yyyymmdd'), 'dd') AS days_since_reg,
        CASE
            -- 当日新注册用户
            WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN '1.新用户'
            -- 未登录间隔 >= 60 天，或无历史登录记录且注册满 60 天
            WHEN (DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 'dd') >= 60
                  OR (last_login_day IS NULL AND DATEDIFF(TO_DATE(CAST(day AS STRING), 'yyyymmdd'), TO_DATE(CAST(reg_day AS STRING), 'yyyymmdd'), 'dd') >= 60)) THEN '2.回流用户(60天)'
            -- 其余为常规活跃老用户
            ELSE '3.老用户'
        END AS user_type
    FROM user_log
    WHERE day >= 20200729 -- 韩国正式开服时间 2020-07-29 至今
),

daily_agg AS (
    -- 3. 按日期聚合各类型用户的人数(DAU)、付费人数(PU)与收入(RMB)
    SELECT
        day,
        -- 人数 (DAU)
        COUNT(DISTINCT CASE WHEN user_type = '1.新用户' THEN lcm_id END)       AS new_dau,
        COUNT(DISTINCT CASE WHEN user_type = '2.回流用户(60天)' THEN lcm_id END) AS return_dau,
        COUNT(DISTINCT CASE WHEN user_type = '3.老用户' THEN lcm_id END)     AS old_dau,
        COUNT(DISTINCT lcm_id)                                               AS total_dau,

        -- 收入 (RMB 人民币)
        SUM(CASE WHEN user_type = '1.新用户' THEN daily_purchase ELSE 0 END)       AS new_rev_rmb,
        SUM(CASE WHEN user_type = '2.回流用户(60天)' THEN daily_purchase ELSE 0 END) AS return_rev_rmb,
        SUM(CASE WHEN user_type = '3.老用户' THEN daily_purchase ELSE 0 END)     AS old_rev_rmb,
        SUM(daily_purchase)                                                        AS total_rev_rmb,

        -- 付费人数 (PU)
        COUNT(DISTINCT CASE WHEN user_type = '1.新用户' AND daily_purchase > 0 THEN lcm_id END)       AS new_pu,
        COUNT(DISTINCT CASE WHEN user_type = '2.回流用户(60天)' AND daily_purchase > 0 THEN lcm_id END) AS return_pu,
        COUNT(DISTINCT CASE WHEN user_type = '3.老用户' AND daily_purchase > 0 THEN lcm_id END)     AS old_pu,
        COUNT(DISTINCT CASE WHEN daily_purchase > 0 THEN lcm_id END)                                  AS total_pu
    FROM calculated_user_type
    GROUP BY day
)

-- 4. 宽表输出：按日展示新用户、老用户、60天回流用户的人数、收入及相关衍生 KPI
SELECT
    day AS "日期",
    
    -- 人数
    new_dau AS "新用户人数",
    old_dau AS "老用户人数",
    return_dau AS "回流用户人数(60天)",
    total_dau AS "总活跃人数(DAU)",
    
    -- 收入 (人民币 RMB)
    ROUND(new_rev_rmb, 2) AS "新用户收入(RMB)",
    ROUND(old_rev_rmb, 2) AS "老用户收入(RMB)",
    ROUND(return_rev_rmb, 2) AS "回流用户收入(RMB)",
    ROUND(total_rev_rmb, 2) AS "总收入(RMB)",
    
    -- 占比 (收入占比)
    ROUND(new_rev_rmb * 100.0 / NULLIF(total_rev_rmb, 0), 2) AS "新用户收入占比(%)",
    ROUND(old_rev_rmb * 100.0 / NULLIF(total_rev_rmb, 0), 2) AS "老用户收入占比(%)",
    ROUND(return_rev_rmb * 100.0 / NULLIF(total_rev_rmb, 0), 2) AS "回流用户收入占比(%)",

    -- ARPU (人均贡献 RMB)
    ROUND(new_rev_rmb / NULLIF(new_dau, 0), 2) AS "新用户ARPU(RMB)",
    ROUND(old_rev_rmb / NULLIF(old_dau, 0), 2) AS "老用户ARPU(RMB)",
    ROUND(return_rev_rmb / NULLIF(return_dau, 0), 2) AS "回流用户ARPU(RMB)",
    ROUND(total_rev_rmb / NULLIF(total_dau, 0), 2) AS "总ARPU(RMB)"

FROM daily_agg
ORDER BY day DESC;

/*
-- 附录：如需要【分行/长表格式】(按 日期 x 用户类型 输出):
SELECT
    day AS "日期",
    user_type AS "用户类型",
    COUNT(DISTINCT lcm_id) AS "人数",
    ROUND(SUM(daily_purchase), 2) AS "收入(RMB)",
    COUNT(DISTINCT CASE WHEN daily_purchase > 0 THEN lcm_id END) AS "付费人数",
    ROUND(SUM(daily_purchase) / NULLIF(COUNT(DISTINCT lcm_id), 0), 2) AS "ARPU(RMB)"
FROM calculated_user_type
GROUP BY day, user_type
ORDER BY day DESC, user_type;
*/
