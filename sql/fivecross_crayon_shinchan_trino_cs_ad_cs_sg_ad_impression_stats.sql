/*
================================================================================
项目：蜡笔小新 - 广告观看转化与收益统计 (Ad Impression Stats)
描述：统计不同时间周期下，各个广告来源 (config_id) 的成功观看次数、未看完次数、人数及对应的广告收益 (USD)。
备注：包含内部及Windows测试账号的黑名单过滤。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

AdLogs AS (
    SELECT 
        CASE
            WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
            ELSE '已合并'
        END AS period,
        CAST(v.config_id AS VARCHAR) AS config_id,
        CAST(v.config_name AS VARCHAR) AS config_name,
        CAST(v.status AS INTEGER) AS status,
        CAST(v.value AS DOUBLE) AS ad_value_usd,
        v."#user_id"
    FROM ta.v_event_13 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'game_ad_impression'
      AND ub."#user_id" IS NULL
)

SELECT 
    COALESCE(period, '汇总') AS "时间周期",
    COALESCE(config_id, '全部') AS "广告来源ID(config_id)",
    MAX(config_name) AS "广告来源名称(config_name)",
    COUNT(CASE WHEN status = 1 THEN 1 END) AS "成功观看次数",
    COUNT(CASE WHEN status <> 1 THEN 1 END) AS "未看完次数",
    COUNT(DISTINCT CASE WHEN status = 1 THEN "#user_id" END) AS "成功观看人数",
    COUNT(DISTINCT CASE WHEN status <> 1 THEN "#user_id" END) AS "未看完人数",
    SUM(CASE WHEN status = 1 THEN ad_value_usd ELSE 0.0 END) AS "成功观看广告费(USD)"
FROM AdLogs
GROUP BY GROUPING SETS ((period, config_id), ())
ORDER BY 
    GROUPING(period),
    1 DESC, 
    8 DESC;
