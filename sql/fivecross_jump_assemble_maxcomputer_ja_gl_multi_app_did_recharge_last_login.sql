/*
================================================================================
Game    : Multi App Account Lookup
Report  : did / dena_id 累计充值与最后登录时间
Apps    : 23002013, 65002005, 23000113, 65002007
Period  : 2017-01-01 至今
Env     : MaxCompute / ODPS

口径:
  1. 充值金额使用 dm_platform.daily_lcx_user_info.purchase
  2. 最后登录时间使用 dm_platform.daily_lcx_user_info.day 的最大值
  3. did / dena_id 使用 dm_platform.lcx_user_info 映射
  4. 先按 app_id + lcm_id 聚合，再关联账号映射，避免 lcx_user_info 多分区导致金额被放大
================================================================================
*/

WITH AppList AS (
    SELECT '23002013' AS app_id UNION ALL
    SELECT '65002005' AS app_id UNION ALL
    SELECT '23000113' AS app_id UNION ALL
    SELECT '65002007' AS app_id
),

UserAgg AS (
    SELECT
        CAST(app_id AS STRING) AS app_id,
        lcm_id,
        ROUND(SUM(COALESCE(CAST(purchase AS DOUBLE), 0)), 2) AS total_recharge_amount,
        MAX(`day`) AS last_login_day
    FROM dm_platform.daily_lcx_user_info
    WHERE CAST(app_id AS STRING) IN (SELECT app_id FROM AppList)
      AND `day` >= 20170101
      AND lcm_id IS NOT NULL
    GROUP BY
        CAST(app_id AS STRING),
        lcm_id
),

UserMap AS (
    SELECT
        CAST(app_id AS STRING) AS app_id,
        lcm_id,
        MAX(did) AS did,
        MAX(dena_id) AS dena_id
    FROM dm_platform.lcx_user_info
    WHERE CAST(app_id AS STRING) IN (SELECT app_id FROM AppList)
      AND `day` >= 20170101
      AND lcm_id IS NOT NULL
    GROUP BY
        CAST(app_id AS STRING),
        lcm_id
),

MappedUserAgg AS (
    SELECT
        um.did,
        um.dena_id,
        ua.total_recharge_amount,
        ua.last_login_day
    FROM UserAgg ua
    INNER JOIN UserMap um
        ON ua.app_id = um.app_id
       AND ua.lcm_id = um.lcm_id
    WHERE um.did IS NOT NULL
       OR um.dena_id IS NOT NULL
)

SELECT
    did,
    dena_id,
    ROUND(SUM(total_recharge_amount), 2) AS total_recharge_amount,
    MAX(last_login_day) AS last_login_day
FROM MappedUserAgg
GROUP BY
    did,
    dena_id
ORDER BY
    total_recharge_amount DESC,
    last_login_day DESC;
