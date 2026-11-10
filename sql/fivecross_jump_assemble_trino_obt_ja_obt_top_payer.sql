/*
================================================================================
Game    : Jump Assemble - OBT Region
Report  : 充值排行榜 (Top Payer Leaderboard)
Description: 统计 OBT 期间，在指定日期段内玩家的真实充值金额 (排除沙盒充值)，
             并关联其最新的角色信息 (角色名、角色ID、区服) 以及固定注册标签属性 (注册时间、系统、渠道)。
Environment: Trino (TA)
================================================================================
*/

WITH NewUsers AS (
    -- 1. 获取玩家固定的注册时间、操作系统、渠道等标签属性 (源自 user_result_cluster_23)
    SELECT 
        "#varchar_id" AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_regdate', 'fixed_os', 'fixed_affcode')
    GROUP BY 1
),

UsersInfo AS (
    -- 2. 获取每个用户最新的角色信息 (角色名、角色ID、区服ID)
    SELECT *
    FROM (
        SELECT 
            COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id) AS lcx_id,
            e.rolecommon.role_id AS role_id,
            e.rolecommon.role_name AS role_name,
            e.rolecommon.zone_id AS zone_id,
            ROW_NUMBER() OVER(PARTITION BY COALESCE(e.sdkcommon.lcx_id, e.fc_sdk_common.lcx_id,"#account_id") ORDER BY e."#event_time" DESC) rn
        FROM ta.v_event_23 e
        WHERE e."$part_date" >= '2026-06-24' -- OBT 开始至今
          -- AND e.rolecommon.role_name IS NOT NULL
          AND e."$part_event" IN ('NUU','PURCHASE','LOGIN_SUCCESS','hero_choose','resource_change')
          -- AND e.rolecommon.role_name <> ''
    )
    WHERE rn = 1
)

-- 3. 统计指定日期段内的充值总额并生成排行榜
SELECT 
    ROW_NUMBER() OVER(ORDER BY SUM(CAST(s1.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0)) DESC) AS "排名",
    s1."#account_id" AS "用户ID (lcx_id)",
    s3.role_id AS "角色ID",
    s3.role_name AS "角色名称",
    s3.zone_id AS "区服ID",
    s2.fixed_regdate AS "注册时间",
    s2.fixed_os AS "系统",
    s2.fixed_affcode AS "渠道",
    ROUND(SUM(CAST(s1.payload.curamt AS DOUBLE) / COALESCE(s5.exchange, 1.0)), 2) AS "充值金额 (USD)"
FROM ta.v_event_23 s1
LEFT JOIN ta_dim.ta_exchange s5 
    ON s1."$part_date" = s5.ex_date 
    AND s1.payload.cur = s5.currency
LEFT JOIN NewUsers s2 
    ON s1."#account_id" = s2.lcx_id
LEFT JOIN UsersInfo s3 
    ON s1."#account_id" = s3.lcx_id
WHERE s1.${PartDate:date} 
  AND s1."$part_event" = 'PURCHASE'
  AND COALESCE(s1.payload.validationtype, '') <> 'SANDBOX_RECEIPT'
GROUP BY 2, 3, 4, 5, 6, 7, 8
ORDER BY 1 ASC;
