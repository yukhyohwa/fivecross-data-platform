/*
小新繁体异常刷榜用户 App18｜OBT｜每角色一行。

日期参数：${PartDate:date}。
筛选：主线最高关卡ID > 4000 OR 限时最高成功关卡ID >= 10210。
限时：stage_fight，key=1027，result=0。
限时关数按原始ID-10000显示，因此10210对应210关。

Reg仅用于确认OBT创角和排除创角前记录。
昵称取所选期间最后login。
战力、神灯等级、角色等级取同一条最后battle_start。
角色与FC账号充值均仅统计所选日期。
风控标签只展示，不剔除用户。
URL:https://ss-web.5xgames.com/#/tga/ide/18_5209?tab=result&fromPanel=18_1002
*/

WITH
-- OBT角色首次创角
Reg AS (
    SELECT
        TRIM(CAST(v."#account_id" AS VARCHAR)) AS rid,
        MIN(CAST(v."#event_time" AS TIMESTAMP)) AS reg_tm
    FROM ta.v_event_18 v
    WHERE v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'new_role'
      AND v."#event_time" >= TIMESTAMP '2026-10-14 00:00:00'
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

-- 一次读取所选期间的角色行为
RoleEvents AS (
    SELECT
        TRIM(CAST(v."#account_id" AS VARCHAR)) AS rid,
        NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') AS fc_id,
        CAST(TRY_CAST(v.server_id AS BIGINT) AS VARCHAR) AS sid,
        CAST(v."#event_time" AS TIMESTAMP) AS tm,
        COALESCE(
            CAST(v."#server_time" AS TIMESTAMP),
            CAST(v."#event_time" AS TIMESTAMP)
        ) AS server_tm,
        v."$part_event" AS ev,
        NULLIF(TRIM(CAST(v.role_name AS VARCHAR)), '') AS nickname,

        -- 保持原进度统计范围，不额外使用battle_start中的主线字段
        CASE
            WHEN v."$part_event" <> 'battle_start'
            THEN TRY_CAST(v.mainstage_id AS BIGINT)
        END AS main_id,

        CASE
            WHEN v."$part_event" = 'stage_fight'
             AND TRY_CAST(v.a_rst[1].key AS INTEGER) = 1001
            THEN TRY_CAST(v.a_rst[1].id AS BIGINT)
        END AS fight_id,

        CASE
            WHEN v."$part_event" = 'stage_fight'
             AND TRY_CAST(v.a_rst[1].key AS INTEGER) = 1027
             AND TRY_CAST(v.result AS INTEGER) = 0
            THEN TRY_CAST(v.a_rst[1].id AS BIGINT)
        END AS limited_stage_id,

        TRY_CAST(v.battlepower AS BIGINT) AS power,
        TRY_CAST(v.lamp_level AS BIGINT) AS lamp_level,
        TRY_CAST(v.role_lev AS BIGINT) AS role_lev
    FROM ta.v_event_18 v
    INNER JOIN Reg g
        ON TRIM(CAST(v."#account_id" AS VARCHAR)) = g.rid
       AND CAST(v."#event_time" AS TIMESTAMP) >= g.reg_tm
    WHERE v.${PartDate:date}
      AND v."$part_event" IN (
          'login',
          'new_role',
          'stage_fight',
          'charge',
          'card_battlepower',
          'battle_start'
      )
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
),

-- 昵称、战力、进度在同一次角色聚合中完成
RoleStats AS (
    SELECT
        rid,
        MAX_BY(fc_id, ROW(tm, server_tm))
            FILTER (
                WHERE fc_id IS NOT NULL
                  AND ev <> 'battle_start'
            ) AS fc_id,

        MAX_BY(sid, ROW(tm, server_tm))
            FILTER (
                WHERE sid IS NOT NULL
                  AND ev <> 'battle_start'
            ) AS sid,

        MAX(
            GREATEST(
                COALESCE(main_id, 0),
                COALESCE(fight_id, 0)
            )
        ) AS max_stage,

        MAX_BY(main_id, ROW(tm, server_tm))
            FILTER (WHERE main_id > 0) AS latest_stage,

        MAX(limited_stage_id) AS max_limited_id,

        MAX(tm)
            FILTER (WHERE ev <> 'battle_start') AS latest_tm,

        -- 用ROW保证昵称及时间来自同一条login
        MAX_BY(
            CAST(
                ROW(nickname, tm)
                AS ROW(
                    nickname VARCHAR,
                    nickname_tm TIMESTAMP
                )
            ),
            ROW(tm, server_tm)
        ) FILTER (WHERE ev = 'login') AS login_record,

        -- 用ROW保证战力、神灯、等级及时间来自同一条battle_start
        MAX_BY(
            CAST(
                ROW(power, lamp_level, role_lev, tm)
                AS ROW(
                    power BIGINT,
                    lamp_level BIGINT,
                    role_lev BIGINT,
                    power_tm TIMESTAMP
                )
            ),
            ROW(tm, server_tm)
        ) FILTER (WHERE ev = 'battle_start') AS battle_record
    FROM RoleEvents
    GROUP BY rid
    HAVING
        MAX(
            GREATEST(
                COALESCE(main_id, 0),
                COALESCE(fight_id, 0)
            )
        ) > 4000
        OR MAX(limited_stage_id) >= 10210
),

-- 仅展示当前风控标记
Tags AS (
    SELECT
        TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id,
        MAX(
            CASE
                WHEN cluster_name = 'internal_users_new' THEN 1
                ELSE 0
            END
        ) AS internal
    FROM user_result_cluster_18
    WHERE cluster_name IN (
        'internal_users_new',
        'is_water_new',
        'is_windows_new'
    )
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
    GROUP BY 1
),

-- 日期、币种唯一汇率；异常或冲突汇率返回NULL
FX AS (
    SELECT
        CAST(ex_date AS VARCHAR) AS dt,
        UPPER(TRIM(CAST(currency AS VARCHAR))) AS currency,
        CASE
            WHEN COUNT(*) = COUNT(TRY_CAST(exchange AS DOUBLE))
             AND MIN(TRY_CAST(exchange AS DOUBLE)) > 0
             AND MIN(TRY_CAST(exchange AS DOUBLE))
                 = MAX(TRY_CAST(exchange AS DOUBLE))
            THEN MAX(TRY_CAST(exchange AS DOUBLE))
        END AS rate
    FROM ta_dim.ta_exchange
    GROUP BY 1, 2
),

-- 充值日志只读取一次
ChargeRows AS (
    SELECT
        NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') AS rid,
        NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') AS fc_id,
        TRY_CAST(v.pay_amount AS DOUBLE)
            / NULLIF(x.rate, 0) AS usd,
        CASE
            WHEN x.rate IS NULL THEN 1
            ELSE 0
        END AS fx_missing
    FROM ta.v_event_18 v
    LEFT JOIN FX x
        ON v."$part_date" = x.dt
       AND UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))) = x.currency
    WHERE v.${PartDate:date}
      AND v."$part_event" = 'charge'
      AND v."#event_time" >= TIMESTAMP '2026-10-14 00:00:00'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(
            UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))),
            ''
          ) <> 'COIN'
      AND TRY_CAST(v.pay_amount AS DOUBLE) > 0
),

-- 一次聚合同时计算角色充值和FC账号全服充值
Payments AS (
    SELECT
        CASE
            WHEN GROUPING(rid) = 0 THEN 'role'
            ELSE 'account'
        END AS metric_type,
        CASE
            WHEN GROUPING(rid) = 0 THEN rid
            ELSE fc_id
        END AS entity_id,
        SUM(usd) AS usd,
        SUM(fx_missing) AS fx_missing
    FROM ChargeRows
    GROUP BY GROUPING SETS (
        (rid),
        (fc_id)
    )
),

StageDim AS (
    SELECT
        TRY_CAST("stage_id@stage_id" AS BIGINT) AS id,
        MAX("stage_id@stage_name_real") AS name
    FROM ta_dim.dim_18_0_52765
    GROUP BY 1
),

-- 每个角色生成两个查询键，避免将Payments重复引用两次
RolePaymentKeys AS (
    SELECT
        r.*,
        k.metric_type,
        k.entity_id
    FROM RoleStats r
    CROSS JOIN UNNEST(
        ARRAY['role', 'account'],
        ARRAY[r.rid, r.fc_id]
    ) AS k(metric_type, entity_id)
)

SELECT
    r.rid AS "玩家ID",
    r.fc_id AS "5xid（fc_id）",
    r.login_record.nickname AS "所选时间范围最新登录昵称",
    r.sid AS "区服",

    CASE
        WHEN COALESCE(t.internal, 0) = 1 THEN '是'
        ELSE '否'
    END AS "是否内部用户（新）",

    r.battle_record.power AS "所选时间范围最新战斗力",
    r.battle_record.lamp_level AS "神灯等级（同条战斗记录）",
    r.battle_record.role_lev AS "角色等级（同条战斗记录）",
    CAST(r.login_record.nickname_tm AS VARCHAR) AS "昵称登录记录时间",

    CASE
        WHEN COALESCE(
            MAX(p.fx_missing) FILTER (WHERE r.metric_type = 'role'),
            0
        ) > 0
        THEN NULL
        ELSE COALESCE(
            MAX(p.usd) FILTER (WHERE r.metric_type = 'role'),
            0
        )
    END AS "所选时间范围角色充值USD",

    r.max_stage AS "所选时间范围最高主线ID",
    d.name AS "所选时间范围最高主线名称",
    r.max_limited_id AS "限时闯关最高成功关卡ID",

    CASE
        WHEN r.max_limited_id IS NOT NULL
        THEN CONCAT(
            '限时闯关 第',
            CAST(r.max_limited_id - 10000 AS VARCHAR),
            '关'
        )
    END AS "限时闯关关卡（派生显示）",

    CASE
        WHEN r.max_stage > 4000
         AND r.max_limited_id >= 10210
        THEN '两项均命中'
        WHEN r.max_stage > 4000
        THEN '主线>4000'
        ELSE '限时闯关成功关数>=210'
    END AS "名单命中条件",

    CASE
        WHEN COALESCE(
            MAX(p.fx_missing) FILTER (WHERE r.metric_type = 'account'),
            0
        ) > 0
        THEN NULL
        ELSE COALESCE(
            MAX(p.usd) FILTER (WHERE r.metric_type = 'account'),
            0
        )
    END AS "充值USD",

    r.latest_stage AS "最新上报主线ID",
    CAST(r.battle_record.power_tm AS VARCHAR) AS "战力记录时间",
    CAST(r.latest_tm AS VARCHAR) AS "角色最新记录时间"

FROM RolePaymentKeys r
LEFT JOIN Payments p
    ON r.metric_type = p.metric_type
   AND r.entity_id = p.entity_id
LEFT JOIN Tags t
    ON r.fc_id = t.fc_id
LEFT JOIN StageDim d
    ON r.max_stage = d.id

GROUP BY
    1, 2, 3, 4, 5, 6, 7, 8, 9,
    11, 12, 13, 14, 15, 17, 18, 19

ORDER BY
    r.max_stage DESC,
    r.battle_record.power DESC NULLS LAST;
