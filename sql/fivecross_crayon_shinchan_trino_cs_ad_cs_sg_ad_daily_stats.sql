/*
================================================================================
项目：蜡笔小新 - 广告观看与收益并列分组统计 (含 #distinct_id 映射)
描述：以平级、并列的方式输出大盘、首日、各系统、各国家、付费类型的独立表现。
      解决广告事件缺少 #user_id 的问题。
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows')
),

UserProfileDetail AS (
    SELECT 
        "#user_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_13
    WHERE cluster_name IN ('fixed_country', 'fixed_os', 'fixed_regdate')
    GROUP BY 1
),

UserType AS (
    SELECT DISTINCT "#user_id"
    FROM ta.v_event_13 v
    WHERE ${PartDate:date1}
      AND v."$part_event" IN ('charge')
      AND (sandbox IS NULL OR sandbox = FALSE)
      AND (is_freebuy IS NULL OR is_freebuy = FALSE)
),

-- 账号映射：找回广告事件丢失的 #user_id
UserMapping AS (
    SELECT "#user_id", "#distinct_id"
    FROM (
        SELECT 
            "#user_id", 
            "#distinct_id",
            ROW_NUMBER() OVER(PARTITION BY "#distinct_id" ORDER BY "#event_time") as rn
        FROM ta.v_event_13 v
        WHERE ${PartDate:date1}
          AND v."$part_event" IN ('login','new_role') 
          AND "#user_id" IS NOT NULL
    ) 
    WHERE rn = 1
),

-- 底层数据提取：补齐 #user_id 并按用户每天聚合活跃和广告数据
BaseData AS (
    SELECT 
        v."$part_date" AS log_date,
        COALESCE(um."#user_id", v."#user_id") AS mapped_user_id,
        COALESCE(up.fixed_os, '未知') AS os_type,
        CASE WHEN up.fixed_country = '新加坡' THEN '新加坡' ELSE '非新加坡' END AS country_group,
        CASE WHEN ut."#user_id" IS NOT NULL THEN '付费' ELSE '免费' END AS paid_type,
        CASE WHEN v."$part_date" = up.fixed_regdate THEN 1 ELSE 0 END AS is_new_user,
        
        COUNT(CASE WHEN v."$part_event" = 'game_ad_impression' AND v.status = 1 THEN 1 END) AS ad_clicks,
        SUM(CASE WHEN v."$part_event" = 'game_ad_impression' AND v.status = 1 THEN 
                CASE WHEN v."#os"='Android' THEN CAST(v.value AS DOUBLE)/1000 ELSE CAST(v.value AS DOUBLE) END 
            ELSE 0.0 END) AS ad_value_usd
    FROM ta.v_event_13 v
    LEFT JOIN UserMapping um ON v."#distinct_id" = um."#distinct_id"
    -- 统一使用 mapped_user_id 进行后续标签关联
    LEFT JOIN UserBlacklist ub ON COALESCE(um."#user_id", v."#user_id") = ub."#user_id"
    LEFT JOIN UserProfileDetail up ON COALESCE(um."#user_id", v."#user_id") = up."#user_id"
    LEFT JOIN UserType ut ON COALESCE(um."#user_id", v."#user_id") = ut."#user_id"
    WHERE ${PartDate:date1}
      AND ub."#user_id" IS NULL
      AND v."$part_event" IN ('login', 'game_ad_impression', 'new_role') 
      -- 过滤掉确实没有任何绑定关系的纯匿名事件（保护数据准确度）
      AND COALESCE(um."#user_id", v."#user_id") IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6
),

-- 将用户数据扇出到平行标签
FannedOut AS (
    SELECT 
        log_date,
        group_name,
        mapped_user_id AS "#user_id",
        ad_clicks,
        ad_value_usd
    FROM BaseData
    CROSS JOIN UNNEST(
        FILTER(
            ARRAY[
                '1_每日大盘总计',
                CASE WHEN is_new_user = 1 THEN '2_首日新增用户' ELSE NULL END,
                '3_系统: ' || os_type,
                '4_国家: ' || country_group,
                '5_类型: ' || paid_type
            ],
            x -> x IS NOT NULL
        )
    ) AS t(group_name)
)

-- 分组聚合
SELECT 
    log_date AS "日期",
    SUBSTR(group_name, 3) AS "分组",
    COUNT(DISTINCT "#user_id") AS "活跃人数",
    SUM(ad_clicks) AS "成功看广告次数",
    COUNT(DISTINCT CASE WHEN ad_clicks > 0 THEN "#user_id" END) AS "成功看广告人数",
    ROUND(SUM(ad_value_usd), 4) AS "广告收入(USD)"
FROM FannedOut
GROUP BY log_date, group_name
ORDER BY log_date DESC, group_name;
