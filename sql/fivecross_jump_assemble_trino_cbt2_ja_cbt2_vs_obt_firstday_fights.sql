/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region
Report  : CBT2 vs OBT 首日用户前7日人均战斗次数对比
Cohort  : CBT2 & OBT 首日注册的新增用户 (排除黑名单)
Window  : 首日 ~ D+7 (前8天)
Metrics :
  - 漫斗赛 (model_type = 5) 人均次数
  - 排位赛 (model_type = 2) 人均次数
================================================================================
*/

WITH
--------------------------------------------------------------------------------
-- 0. 黑名单过滤 (水军与内部测试号)
--------------------------------------------------------------------------------
Blacklist_16 AS (
    SELECT DISTINCT "#varchar_id" AS account_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),
Blacklist_23 AS (
    SELECT DISTINCT "#varchar_id" AS account_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 1. 指定 CBT2 和 OBT 的首日日期 (CBT2: 04-15, OBT: 06-24)
--------------------------------------------------------------------------------
Launch_16 AS (
    SELECT DATE '2026-04-15' AS launch_date
),
Launch_23 AS (
    SELECT DATE '2026-06-24' AS launch_date
),

--------------------------------------------------------------------------------
-- 2. 提取首日注册的新增用户
--------------------------------------------------------------------------------
Users_16 AS (
    SELECT DISTINCT 
        COALESCE(
            CASE WHEN LENGTH(CAST(sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(sdkcommon.lcx_id AS VARCHAR) END,
            CAST("#account_id" AS VARCHAR)
        ) AS account_id
    FROM ta.v_event_16
    WHERE "$part_event" = 'NUU'
      AND "$part_date" = CAST((SELECT launch_date FROM Launch_16) AS VARCHAR)
),
ValidUsers_16 AS (
    SELECT account_id FROM Users_16
    WHERE account_id NOT IN (SELECT account_id FROM Blacklist_16)
),

Users_23 AS (
    SELECT DISTINCT 
        COALESCE(
            CASE WHEN LENGTH(CAST(sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(sdkcommon.lcx_id AS VARCHAR) END,
            CAST("#account_id" AS VARCHAR)
        ) AS account_id
    FROM ta.v_event_23
    WHERE "$part_event" = 'NUU'
      AND "$part_date" = CAST((SELECT launch_date FROM Launch_23) AS VARCHAR)
),
ValidUsers_23 AS (
    SELECT account_id FROM Users_23
    WHERE account_id NOT IN (SELECT account_id FROM Blacklist_23)
),

--------------------------------------------------------------------------------
-- 3. 统计这些用户在前 7 日 (D+0 ~ D+7) 的漫斗赛与排位赛场次
--------------------------------------------------------------------------------
Fights_16 AS (
    SELECT 
        u.account_id,
        COUNT(CASE WHEN CAST(v.model_type AS VARCHAR) = '5' THEN 1 END) AS mandou_count,
        COUNT(CASE WHEN CAST(v.model_type AS VARCHAR) = '2' THEN 1 END) AS rank_count
    FROM ValidUsers_16 u
    JOIN ta.v_event_16 v 
      ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id AS VARCHAR) END,
            CAST(v."#account_id" AS VARCHAR)
         ) = u.account_id
    WHERE v."$part_event" = 'arena_fight'
      AND CAST(v."$part_date" AS DATE) >= (SELECT launch_date FROM Launch_16)
      AND CAST(v."$part_date" AS DATE) <= DATE_ADD('day', 7, (SELECT launch_date FROM Launch_16))
    GROUP BY u.account_id
),
Fights_23 AS (
    SELECT 
        u.account_id,
        COUNT(CASE WHEN CAST(v.model_type AS VARCHAR) = '5' THEN 1 END) AS mandou_count,
        COUNT(CASE WHEN CAST(v.model_type AS VARCHAR) = '2' THEN 1 END) AS rank_count
    FROM ValidUsers_23 u
    JOIN ta.v_event_23 v 
      ON COALESCE(
            CASE WHEN LENGTH(CAST(v.sdkcommon.lcx_id AS VARCHAR)) = 36 THEN CAST(v.sdkcommon.lcx_id AS VARCHAR) END,
            CAST(v."#account_id" AS VARCHAR)
         ) = u.account_id
    WHERE v."$part_event" = 'arena_fight'
      AND CAST(v."$part_date" AS DATE) >= (SELECT launch_date FROM Launch_23)
      AND CAST(v."$part_date" AS DATE) <= DATE_ADD('day', 7, (SELECT launch_date FROM Launch_23))
    GROUP BY u.account_id
),

--------------------------------------------------------------------------------
-- 4. 大盘汇总
--------------------------------------------------------------------------------
Agg_16 AS (
    SELECT 
        'CBT2' AS phase,
        (SELECT COUNT(account_id) FROM ValidUsers_16) AS cohort_users,
        SUM(mandou_count) AS total_mandou,
        SUM(rank_count) AS total_rank
    FROM Fights_16
),
Agg_23 AS (
    SELECT 
        'OBT' AS phase,
        (SELECT COUNT(account_id) FROM ValidUsers_23) AS cohort_users,
        SUM(mandou_count) AS total_mandou,
        SUM(rank_count) AS total_rank
    FROM Fights_23
)

--------------------------------------------------------------------------------
-- 5. 合并输出
--------------------------------------------------------------------------------
SELECT 
    phase AS "测试阶段",
    cohort_users AS "首日注册人数",
    ROUND(CAST(COALESCE(total_mandou, 0) AS DOUBLE) / NULLIF(cohort_users, 0), 2) AS "前7日人均漫斗赛次数",
    ROUND(CAST(COALESCE(total_rank, 0) AS DOUBLE) / NULLIF(cohort_users, 0), 2) AS "前7日人均排位赛次数"
FROM Agg_16

UNION ALL

SELECT 
    phase,
    cohort_users,
    ROUND(CAST(COALESCE(total_mandou, 0) AS DOUBLE) / NULLIF(cohort_users, 0), 2),
    ROUND(CAST(COALESCE(total_rank, 0) AS DOUBLE) / NULLIF(cohort_users, 0), 2)
FROM Agg_23

ORDER BY "测试阶段";
