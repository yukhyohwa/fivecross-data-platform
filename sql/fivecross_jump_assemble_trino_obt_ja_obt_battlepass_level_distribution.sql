WITH user_bp_level AS (
    -- 1. 取用户在指定时间范围内的最高通行证等级
    -- 使用 UNNEST(bplevel) 将数组展开成多行，分别计算
    SELECT
        "#account_id",
        MAX(CAST(single_level AS INTEGER)) AS max_level
    FROM ta.v_event_23
    CROSS JOIN UNNEST(bplevel) AS t(single_level)
    WHERE "$part_event" = 'battlepass_reward'
      AND ${PartDate:date1}
    GROUP BY "#account_id"
),
user_bp_card AS (
    -- 2. 判断用户是否激活过大卡或小卡
    SELECT
        "#account_id",
        MAX(CASE WHEN CAST(indexid AS INTEGER) = 2 THEN 1 ELSE 0 END) AS has_big_card,
        MAX(CASE WHEN CAST(indexid AS INTEGER) = 1 THEN 1 ELSE 0 END) AS has_small_card
    FROM ta.v_event_23
    WHERE "$part_event" = 'battlepass_advance'
      AND ${PartDate:date1}
    GROUP BY "#account_id"
),
user_base AS (
    -- 3. 整合用户的通行证等级与卡类型，没领过奖但在advance出现过则默认为0级
    SELECT
        COALESCE(l."#account_id", c."#account_id") AS account_id,
        COALESCE(l.max_level, 0) AS max_bp_level,
        CASE
            WHEN c.has_big_card = 1 THEN '大卡'
            WHEN c.has_small_card = 1 THEN '小卡'
            ELSE '没卡'
        END AS bp_type
    FROM user_bp_level l
    FULL OUTER JOIN user_bp_card c ON l."#account_id" = c."#account_id"
),
type_stats AS (
    -- 4. 计算各通行证类型的大盘数据：该类型的总用户数、平均最高等级
    SELECT
        bp_type,
        COUNT(DISTINCT account_id) AS type_users_cnt,
        AVG(max_bp_level * 1.0) AS type_avg_max_level
    FROM user_base
    GROUP BY bp_type
),
level_stats AS (
    -- 5. 计算各通行证类型下，每个等级对应的用户数
    SELECT
        bp_type,
        max_bp_level,
        COUNT(DISTINCT account_id) AS level_users_cnt
    FROM user_base
    GROUP BY bp_type, max_bp_level
)
-- 6. 拼接最终报表结果，并处理展现顺序
SELECT
    l.bp_type AS "通行证类型",
    l.max_bp_level AS "最高通行证等级",
    t.type_users_cnt AS "类型用户数",
    l.level_users_cnt AS "等级用户数",
    (CAST(l.level_users_cnt AS DOUBLE) / t.type_users_cnt) AS "类型内占比",
    t.type_avg_max_level AS "类型平均最高等级"
FROM level_stats l
JOIN type_stats t ON l.bp_type = t.bp_type
ORDER BY
    CASE l.bp_type
        WHEN '大卡' THEN 1
        WHEN '小卡' THEN 2
        ELSE 3
    END,
    l.max_bp_level;
