WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_13
    WHERE cluster_name IN ('is_windows')
)

SELECT 
    CASE
        WHEN ${Selector:timetype} = 'D' THEN CAST(DATE_TRUNC('day', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'W' THEN CAST(DATE_TRUNC('week', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'M' THEN CAST(DATE_TRUNC('month', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'S' THEN CAST(DATE_TRUNC('quarter', CAST(v."$part_date" AS DATE)) AS VARCHAR)
        WHEN ${Selector:timetype} = 'A' THEN '已合并'
    END AS "时间维度",
    CASE 
        WHEN v."$part_event" = 'skill_get' THEN '技能抽卡'
        WHEN v."$part_event" = 'Companion_get' THEN '伙伴抽卡'
        WHEN v."$part_event" = 'movie_get' THEN '影像抽卡'
    END AS "抽卡类型",
    t.item AS "道具ID",
    COUNT(1) AS "产出总量",
    COUNT(DISTINCT v."#account_id") AS "获得人数"
FROM ta.v_event_13 v
LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
CROSS JOIN UNNEST(COALESCE(v.companion_list, v.skill_list)) AS t(item)
WHERE v."$part_event" IN ('skill_get', 'Companion_get', 'movie_get')
AND v.${PartDate:date1}
AND ub."#user_id" IS NULL
GROUP BY 1, 2, 3;
