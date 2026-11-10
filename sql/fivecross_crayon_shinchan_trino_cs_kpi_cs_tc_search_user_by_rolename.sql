/*
蜡笔小新繁体 OBT 用户画像搜索。参数：${roleinfo}。
在 RoleSearch 中直接按 fc_id / 角色名 / 角色ID / SDK UUID / distinct_id 模糊搜索。
OBT 自 2026-10-14 起；每个 fc_id + 角色ID 一行。
充值、登录、SDK 按 fc_id 汇总；等级、注册、主线按角色统计。
新增 new_role_role_name：该 fc_id + 角色ID 首次 new_role 上报的角色名，保留原角色名列。
不查询广告事件，不输出广告次数或广告收入。
搜索、画像、等级、SDK 仅扫描 login/new_role；充值仅扫描 charge；主线仅扫描 stage_fight。
所有事件读取均显式限制 OBT 日期，并按命中 fc_id 或角色关联；没有全事件扫描入口。
国家、系统取该角色 login/new_role 最新非空事件值，不使用旧画像标签。
设备ID保留原列名，因实际事件设备字段尚未确认，暂返回 NULL，不以 distinct_id 代替。
同账号多角色行会重复展示账号指标，不能跨角色累加这些账号指标。
黑名单沿用传入查询的 notneed（默认不排除）；需要排除时改为 OBT 标签：
internal_users_new、is_windows_new、is_water_new。
缺失有效汇率的充值金额返回 NULL，不按汇率 1 或收入 0 猜测。
URL:https://ss-web.5xgames.com/#/tga/ide/18_4785?tab=result&fromPanel=18_921
*/
WITH
Config AS (
    SELECT DATE '2026-10-14' AS obt_start_date
),
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('notneed')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),
RoleSearch AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        v."#user_id",
        v.role_name,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR)), CAST(v."#account_id" AS VARCHAR)
            ORDER BY
                CASE WHEN NULLIF(TRIM(CAST(v.role_name AS VARCHAR)), '') IS NULL THEN 1 ELSE 0 END,
                v."#event_time" DESC, CAST(v."#te_event_id" AS VARCHAR) DESC
        ) AS rn
    FROM ta.v_event_18 v
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
      AND (
           CAST(v.fc_id AS VARCHAR) LIKE '%${roleinfo}%'
        OR CAST(v.role_name AS VARCHAR) LIKE '%${roleinfo}%'
        OR CAST(v."#account_id" AS VARCHAR) LIKE '%${roleinfo}%'
       -- OR COALESCE(
       --        TRY(JSON_EXTRACT_SCALAR(v.fcsdk_info, '$.uuid')),
       --       REGEXP_EXTRACT(CAST(v.fcsdk_info AS VARCHAR), '"uuid"\s*:\s*"([^"]+)"', 1)
       --    ) LIKE '%${roleinfo}%'
       -- OR CAST(v."#distinct_id" AS VARCHAR) LIKE '%${roleinfo}%'
    )
),
MatchedAccounts AS (
    SELECT s.fc_id, s.account_id, s."#user_id", s.role_name
    FROM RoleSearch s
    LEFT JOIN UserBlacklist b ON s.fc_id = b.fc_id
    WHERE s.rn = 1 AND b.fc_id IS NULL
),
MatchedFcIds AS (
    SELECT DISTINCT fc_id FROM MatchedAccounts
),
NewUsers AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        MIN(CAST(v."#event_time" AS TIMESTAMP)) AS reg_time,
        MIN(v."$part_date") AS reg_date,
        MIN_BY(CAST(v.role_name AS VARCHAR), v."#event_time") AS new_role_role_name,
        MIN_BY(CAST(v.server_id AS VARCHAR), v."#event_time")
            FILTER (WHERE v.server_id IS NOT NULL) AS server_id
    FROM ta.v_event_18 v
    JOIN MatchedFcIds m ON TRIM(CAST(v.fc_id AS VARCHAR)) = m.fc_id
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'new_role'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1, 2
),
-- Event attributes for each matching role; no fixed_* profile tags.
UserProfile AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        MAX_BY(NULLIF(TRIM(CAST(v.country AS VARCHAR)), ''), v."#event_time")
            FILTER (WHERE NULLIF(TRIM(CAST(v.country AS VARCHAR)), '') IS NOT NULL) AS country,
        MAX_BY(NULLIF(TRIM(CAST(v.os AS VARCHAR)), ''), v."#event_time")
            FILTER (WHERE NULLIF(TRIM(CAST(v.os AS VARCHAR)), '') IS NOT NULL) AS os_type,
        CAST(NULL AS VARCHAR) AS deviceid
    FROM ta.v_event_18 v
    JOIN MatchedAccounts m
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = m.fc_id
     AND CAST(v."#account_id" AS VARCHAR) = m.account_id
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
    GROUP BY 1, 2
),
ExchangeRate AS (
    SELECT
        CAST(ex_date AS VARCHAR) AS dt,
        UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
        MAX(TRY_CAST(exchange AS DOUBLE)) AS exchange
    FROM ta_dim.ta_exchange
    CROSS JOIN Config c
    WHERE CAST(ex_date AS VARCHAR) >= CAST(c.obt_start_date AS VARCHAR)
    GROUP BY 1, 2
),
ChargeSum AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CASE
            WHEN COUNT_IF(x.exchange IS NULL OR x.exchange <= 0
                          OR TRY_CAST(v.pay_amount AS DOUBLE) IS NULL) > 0 THEN NULL
            ELSE ROUND(SUM(TRY_CAST(v.pay_amount AS DOUBLE) / NULLIF(x.exchange, 0)), 2)
        END AS revenue_usd
    FROM ta.v_event_18 v
    JOIN NewUsers r
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = r.fc_id
     AND CAST(v."#account_id" AS VARCHAR) = r.account_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= r.reg_time
    CROSS JOIN Config c
    LEFT JOIN ExchangeRate x
      ON v."$part_date" = x.dt
     AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = x.currency
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
    GROUP BY 1
),
StageFurthest AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        CAST(v."#account_id" AS VARCHAR) AS account_id,
        MAX(COALESCE(TRY_CAST(v.a_rst[1].id AS BIGINT),
                     TRY_CAST(v.stage_id AS BIGINT))) AS max_stage_id
    FROM ta.v_event_18 v
    JOIN NewUsers r
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = r.fc_id
     AND CAST(v."#account_id" AS VARCHAR) = r.account_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= r.reg_time
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'stage_fight'
      AND TRY_CAST(v.a_rst[1].key AS INTEGER) = 1001
    GROUP BY 1, 2
),
StageDim AS (
    SELECT
        TRY_CAST("stage_id@stage_id" AS BIGINT) AS stage_id,
        MAX("stage_id@stage_name_real") AS stage_name
    FROM ta_dim.dim_18_0_52765
    GROUP BY 1
),
LastLogin AS (
    SELECT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
           MAX(v."$part_date") AS last_login_date
    FROM ta.v_event_18 v
    JOIN NewUsers r
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = r.fc_id
     AND CAST(v."#account_id" AS VARCHAR) = r.account_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= r.reg_time
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" = 'login'
    GROUP BY 1
),
UserLevel AS (
    SELECT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
           CAST(v."#account_id" AS VARCHAR) AS account_id,
           MAX(TRY_CAST(v.role_lev AS INTEGER)) AS role_level
    FROM ta.v_event_18 v
    JOIN NewUsers r
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = r.fc_id
     AND CAST(v."#account_id" AS VARCHAR) = r.account_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= r.reg_time
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
    GROUP BY 1, 2
),
SdkRows AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        COALESCE(
            TRY(JSON_EXTRACT_SCALAR(v.fcsdk_info, '$.uuid')),
            REGEXP_EXTRACT(CAST(v.fcsdk_info AS VARCHAR), '"uuid"\s*:\s*"([^"]+)"', 1)
        ) AS sdk_uuid,
        COALESCE(
            TRY(JSON_EXTRACT_SCALAR(v.fcsdk_info, '$.profiles.apple.email')),
            TRY(JSON_EXTRACT_SCALAR(v.fcsdk_info, '$.profiles.google.email')),
            REGEXP_EXTRACT(CAST(v.fcsdk_info AS VARCHAR), '"email"\s*:\s*"([^"]+)"', 1)
        ) AS sdk_email,
        COALESCE(
            TRY(JSON_EXTRACT_SCALAR(v.fcsdk_info, '$.profiles.apple.name')),
            TRY(JSON_EXTRACT_SCALAR(v.fcsdk_info, '$.profiles.google.name'))
        ) AS sdk_name,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time
    FROM ta.v_event_18 v
    JOIN NewUsers r
      ON TRIM(CAST(v.fc_id AS VARCHAR)) = r.fc_id
     AND CAST(v."#account_id" AS VARCHAR) = r.account_id
     AND CAST(v."#event_time" AS TIMESTAMP) >= r.reg_time
    CROSS JOIN Config c
    WHERE v."$part_date" >= CAST(c.obt_start_date AS VARCHAR)
      AND v."$part_event" IN ('login', 'new_role')
      AND v.fcsdk_info IS NOT NULL
),
UserSdkInfo AS (
    SELECT fc_id,
           MAX_BY(sdk_uuid, event_time) FILTER (WHERE sdk_uuid IS NOT NULL) AS sdk_uuid,
           MAX_BY(sdk_email, event_time) FILTER (WHERE sdk_email IS NOT NULL) AS sdk_email,
           MAX_BY(sdk_name, event_time) FILTER (WHERE sdk_name IS NOT NULL) AS sdk_name
    FROM SdkRows
    GROUP BY 1
)
SELECT
    ma.fc_id AS fc_id,
    CAST(ma."#user_id" AS VARCHAR) AS user_id,
    ma.account_id AS account_id,
   -- sdk.sdk_uuid AS uuid,
    sdk.sdk_email AS email,
    sdk.sdk_name AS name,
    ma.role_name AS "角色名",
    nu.new_role_role_name AS new_role_role_name,
    COALESCE(ul.role_level, 1) AS "角色等级",
    nu.server_id AS server_id,
    nu.reg_date AS "注册时间",
    COALESCE(ll.last_login_date, '未知') AS "最后登陆日期",
    COALESCE(up.country, '未知') AS "国家",
    COALESCE(up.os_type, '未知') AS "系统",
    COALESCE(up.deviceid, '未知') AS "设备ID",
    CASE WHEN cs.fc_id IS NULL THEN 0 ELSE cs.revenue_usd END AS "充值金额_USD",
    sf.max_stage_id AS "主线最远关卡ID",
    TRY(SPLIT(ds.stage_name, ':')[1]) AS "关卡大章",
    ds.stage_name AS "关卡全名"
FROM MatchedAccounts ma
JOIN NewUsers nu ON ma.fc_id = nu.fc_id AND ma.account_id = nu.account_id
LEFT JOIN UserProfile up ON ma.fc_id = up.fc_id AND ma.account_id = up.account_id
LEFT JOIN ChargeSum cs ON ma.fc_id = cs.fc_id
LEFT JOIN StageFurthest sf ON ma.fc_id = sf.fc_id AND ma.account_id = sf.account_id
LEFT JOIN LastLogin ll ON ma.fc_id = ll.fc_id
LEFT JOIN UserLevel ul ON ma.fc_id = ul.fc_id AND ma.account_id = ul.account_id
LEFT JOIN UserSdkInfo sdk ON ma.fc_id = sdk.fc_id
LEFT JOIN StageDim ds ON sf.max_stage_id = ds.stage_id
ORDER BY "充值金额_USD" DESC NULLS LAST, ma.fc_id, ma.account_id;
