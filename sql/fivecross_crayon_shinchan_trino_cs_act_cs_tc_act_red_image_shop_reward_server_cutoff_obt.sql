/*
繁体 App18 OBT：按区服批次截止时间汇总 shop_buy / active_reward 道具流水。
只读取 new_role（取角色创建名、fc_id、服务器）和两个指定事件，不使用 item_change。
截止时间按图中日期的 00:00:00，严格使用 event_time < cutoff_time，按事件原有时区比较。
固定需求不使用日期参数、动态截止日、日历或日期边界推算。
1001–1019：10/25；1020–1027：10/26；1028–1034：10/27；1035–1040：10/28；
1041–1045：10/29；1046–1047：10/30；1048–1049：10/31；1050：11/01；1051–1052：11/02。
追加第9天批次：1053–1054：10/31；1055–1056：11/01；1057：11/02；1058：11/03。

shop_buy 展开全部 shop_item，ID=item_id，数量=num（原始单位，不做晶钻 /100）。
注意 shop_item 通常描述支付/消耗项，不能把它的数量视为获得的红色影像数量。
active_reward 展开全部 a_rst，ID=id，数量优先 diff，缺失时用 after-before。
两类事件展开时均仅保留指定的20个红色影像ID；不限制正负数量。
按角色、创建名、fc_id、创角服务器、道具ID/名称、事件分组，输出最早/最后时间。
道具明细条数为展开后的条数，不是去重订单数；事件道具数量是两事件各自的原始字段口径。
未增加黑名单过滤；缺少有效 new_role 或未落入指定服务器批次的记录无法确定截止时间，不输出。
原参考文件保留，此文件单独提供新口径。
*/
WITH
ServerCutoffs (server_start, server_end, cutoff_time) AS (
    VALUES
        (1001, 1019, TIMESTAMP '2026-10-25 00:00:00'),
        (1020, 1027, TIMESTAMP '2026-10-26 00:00:00'),
        (1028, 1034, TIMESTAMP '2026-10-27 00:00:00'),
        (1035, 1040, TIMESTAMP '2026-10-28 00:00:00'),
        (1041, 1045, TIMESTAMP '2026-10-29 00:00:00'),
        (1046, 1047, TIMESTAMP '2026-10-30 00:00:00'),
        (1048, 1049, TIMESTAMP '2026-10-31 00:00:00'),
        (1050, 1050, TIMESTAMP '2026-11-01 00:00:00'),
        (1051, 1052, TIMESTAMP '2026-11-02 00:00:00'),
        (1053, 1054, TIMESTAMP '2026-10-31 00:00:00'),
        (1055, 1056, TIMESTAMP '2026-11-01 00:00:00'),
        (1057, 1057, TIMESTAMP '2026-11-02 00:00:00'),
        (1058, 1058, TIMESTAMP '2026-11-03 00:00:00')
),
NewRoleRanked AS (
    SELECT
        TRIM(CAST(v."#account_id" AS VARCHAR)) AS role_id,
        NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') AS fc_id,
        CAST(v.role_name AS VARCHAR) AS new_role_name,
        CAST(TRY_CAST(v.server_id AS BIGINT) AS VARCHAR) AS server_id,
        CAST(v."#event_time" AS TIMESTAMP) AS create_time,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v."#account_id" AS VARCHAR))
            ORDER BY v."#event_time" ASC,
                     CAST(v.fc_id AS VARCHAR) ASC NULLS LAST,
                     CAST(v.role_name AS VARCHAR) ASC NULLS LAST,
                     CAST(v.server_id AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    WHERE v."$part_event" = 'new_role'
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_date" < '2026-11-03'
      AND CAST(v."#event_time" AS TIMESTAMP) < TIMESTAMP '2026-11-03 00:00:00'
      AND NULLIF(TRIM(CAST(v."#account_id" AS VARCHAR)), '') IS NOT NULL
),
Roles AS (
    SELECT r.role_id, r.fc_id, r.new_role_name, r.server_id, c.cutoff_time
    FROM NewRoleRanked r
    INNER JOIN ServerCutoffs c
      ON TRY_CAST(r.server_id AS BIGINT) BETWEEN c.server_start AND c.server_end
    WHERE r.rn = 1
      AND r.create_time < c.cutoff_time
),
EventRows AS (
    SELECT
        r.role_id,
        r.new_role_name,
        COALESCE(NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), ''), r.fc_id) AS fc_id,
        r.server_id,
        r.cutoff_time,
        v."$part_event" AS event_name,
        CAST(v."#event_time" AS TIMESTAMP) AS event_time,
        v.shop_item,
        v.a_rst
    FROM ta.v_event_18 v
    INNER JOIN Roles r
      ON TRIM(CAST(v."#account_id" AS VARCHAR)) = r.role_id
    WHERE v."$part_event" IN ('shop_buy', 'active_reward')
      AND v."$part_date" >= '2026-10-14'
      AND v."$part_date" < '2026-11-03'
      AND CAST(v."#event_time" AS TIMESTAMP) < r.cutoff_time
),
ItemRows AS (
    SELECT
        e.role_id, e.new_role_name, e.fc_id, e.server_id, e.cutoff_time,
        e.event_name, e.event_time,
        u.item_id,
        CAST(NULL AS VARCHAR) AS item_name,
        u.item_quantity
    FROM EventRows e
    CROSS JOIN UNNEST(
        TRANSFORM(e.shop_item, x -> ROW(
            TRY_CAST(x.item_id AS BIGINT),
            TRY_CAST(x.num AS BIGINT)
        ))
    ) AS u(item_id, item_quantity)
    WHERE e.event_name = 'shop_buy'
      AND u.item_id IN (
          110033, 110034, 110035, 110036,
          110037, 110038, 110039, 110040,
          110041, 110042, 110043, 110044,
          110045, 110046, 110047, 110048,
          120019, 120020, 170001, 170002
      )

    UNION ALL

    SELECT
        e.role_id, e.new_role_name, e.fc_id, e.server_id, e.cutoff_time,
        e.event_name, e.event_time,
        u.item_id,
        u.item_name,
        u.item_quantity
    FROM EventRows e
    CROSS JOIN UNNEST(
        TRANSFORM(e.a_rst, x -> ROW(
            TRY_CAST(x.id AS BIGINT),
            NULLIF(TRIM(CAST(x.name AS VARCHAR)), ''),
            COALESCE(
                TRY_CAST(x.diff AS BIGINT),
                TRY_CAST(x.after AS BIGINT) - TRY_CAST(x.before AS BIGINT)
            )
        ))
    ) AS u(item_id, item_name, item_quantity)
    WHERE e.event_name = 'active_reward'
      AND u.item_id IN (
          110033, 110034, 110035, 110036,
          110037, 110038, 110039, 110040,
          110041, 110042, 110043, 110044,
          110045, 110046, 110047, 110048,
          120019, 120020, 170001, 170002
      )
),
ItemDim AS (
    SELECT
        TRY_CAST("item_id@item_id" AS BIGINT) AS item_id,
        MAX(NULLIF(TRIM(CAST("item_id@item_name" AS VARCHAR)), '')) AS item_name
    FROM ta_dim.dim_18_0_52781
    GROUP BY 1
),
NamedItems AS (
    SELECT
        g.*,
        COALESCE(d.item_name, g.item_name, '未映射道具_' || CAST(g.item_id AS VARCHAR)) AS resolved_name
    FROM ItemRows g
    LEFT JOIN ItemDim d ON g.item_id = d.item_id
    WHERE g.item_id IS NOT NULL
)
SELECT
    g.role_id AS "角色ID",
    g.new_role_name AS "创建角色时名称",
    g.fc_id AS "fc_id",
    g.server_id AS "server_id",
    g.item_id AS "红色影像ID",
    g.resolved_name AS "红色影像",
    g.event_name AS "$part_event",
    COUNT(*) AS "道具明细条数",
    CASE WHEN COUNT_IF(g.item_quantity IS NULL) > 0 THEN NULL
         ELSE SUM(g.item_quantity) END AS "事件道具数量",
    COUNT_IF(g.item_quantity IS NULL) AS "缺少数量的明细条数",
    MIN(g.event_time) AS "最早时间",
    MAX(g.event_time) AS "最后时间",
    g.cutoff_time AS "截止时间（不含）"
FROM NamedItems g
GROUP BY 1, 2, 3, 4, 5, 6, 7, 13
ORDER BY TRY_CAST(g.server_id AS BIGINT), g.role_id, g.item_id, g.event_name;
