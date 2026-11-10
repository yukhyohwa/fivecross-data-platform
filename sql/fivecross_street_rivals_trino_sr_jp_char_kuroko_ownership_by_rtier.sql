/* 街篮 JP / TA project 5 / Trino
看板二：登录用户分R的黑子联动角色持有率（日元）。
参数：${PartDate:login_date} 登录区间；${PartDate:pay_date} 充值区间。
两者都是完整日期筛选条件，直接用于各自事件源，不拆成起止日期参数。
每个 #user_id 在登录区间去重一次，充值区间 SUM(order_balance_price) 分R。
档位下限含、上限不含；2k以下 = 0<金额<2000；0氪仅指所选充值期内0元。
持有：登录区间内，每人最后一个已上报 user_player_snp 快照分区日，
同日 id 命中且 owntime>0 的角色。充值区间不筛选球员快照。
这是期内最后已观测持有，不保证恰好区间末日，亦未认证永久/试用区分。
快照不全会低估持有；快照覆盖用户数与缺失用户数必须保留用于看板质检。
分母始终为本档全部登录用户，非仅有快照者；空档比例NULL，人数0。
收入沿用街篮 order_finish / order_balance_price JPY，不复制黑篮 charge。
异常金额用户数>0时必须核查，负数/不可解析/空金额不会自动视作有效充值。
不引入未经确认的黑名单或 sandbox 字段；比例数值0~1，设百分比显示。
*/
WITH LoginUsers AS (
    SELECT DISTINCT v."#user_id" AS user_id
    FROM ta.v_event_5 v
    WHERE v."$part_event" = 'login'
      AND v.${PartDate:login_date}
      AND v."#user_id" IS NOT NULL
),
UserSpend AS (
    SELECT v."#user_id" AS user_id,
           SUM(CASE WHEN TRY_CAST(v.order_balance_price AS DECIMAL(20,2)) >= 0
                    THEN TRY_CAST(v.order_balance_price AS DECIMAL(20,2)) ELSE 0 END) AS spend_jpy,
           COUNT_IF(TRY_CAST(v.order_balance_price AS DECIMAL(20,2)) IS NULL
                    OR TRY_CAST(v.order_balance_price AS DECIMAL(20,2)) < 0) AS bad_orders
    FROM ta.v_event_5 v
    INNER JOIN LoginUsers u ON v."#user_id" = u.user_id
    WHERE v."$part_event" = 'order_finish'
      AND v.${PartDate:pay_date}
    GROUP BY 1
),
UserTier AS (
    SELECT user_id, bad_orders,
           CASE
            WHEN spend_jpy >= 2000000 THEN 1
            WHEN spend_jpy >= 1000000 THEN 2
            WHEN spend_jpy >= 500000 THEN 3
            WHEN spend_jpy >= 100000 THEN 4
            WHEN spend_jpy >= 30000 THEN 5
            WHEN spend_jpy >= 10000 THEN 6
            WHEN spend_jpy >= 2000 THEN 7
            WHEN spend_jpy > 0 THEN 8
            ELSE 9
           END AS tier_order
    FROM (
        SELECT u.user_id, COALESCE(p.spend_jpy, 0) AS spend_jpy,
               COALESCE(p.bad_orders, 0) AS bad_orders
        FROM LoginUsers u
        LEFT JOIN UserSpend p ON u.user_id = p.user_id
    ) t
),
SnapshotRows AS (
    SELECT v."#user_id" AS user_id, v."$part_date" AS snapshot_date, v.id, v.owntime,
           MAX(v."$part_date") OVER (PARTITION BY v."#user_id") AS last_snapshot_date
    FROM ta.v_event_5 v
    INNER JOIN LoginUsers u ON v."#user_id" = u.user_id
    WHERE v."$part_event" = 'user_player_snp'
      AND v.${PartDate:login_date}
    -- 此处不能先筛选目标角色，否则“最后快照”会退化为最后命中角色的日期。
),
UserHoldings AS (
    SELECT s.user_id,
           MAX(CASE WHEN s.id = 10071 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10071,
           MAX(CASE WHEN s.id = 10072 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10072,
           MAX(CASE WHEN s.id = 10073 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10073,
           MAX(CASE WHEN s.id = 10074 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10074,
           MAX(CASE WHEN s.id = 10080 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10080,
           MAX(CASE WHEN s.id = 10081 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10081,
           MAX(CASE WHEN s.id = 10082 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10082,
           MAX(CASE WHEN s.id = 10098 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10098,
           MAX(CASE WHEN s.id = 10099 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10099,
           MAX(CASE WHEN s.id = 10100 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10100,
           MAX(CASE WHEN s.id = 10101 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10101,
           MAX(CASE WHEN s.id = 10102 AND s.owntime > 0 THEN 1 ELSE 0 END) AS held_10102
    FROM SnapshotRows s
    WHERE s.snapshot_date = s.last_snapshot_date
    GROUP BY 1
),
Tiers(tier_order, tier_name) AS (
    VALUES
        (1, '200万以上'),
        (2, '100万~200万'),
        (3, '50万~100万'),
        (4, '10万~50万'),
        (5, '3万~10万'),
        (6, '1万~3万'),
        (7, '2k~1万'),
        (8, '2k以下'),
        (9, '0氪')
)
SELECT t.tier_name AS "付费档位（日元）",
       COUNT(u.user_id) AS "用户数",
       COUNT(h.user_id) AS "快照覆盖用户数",
       COUNT(u.user_id) - COUNT(h.user_id) AS "快照缺失用户数",
       COUNT_IF(u.bad_orders > 0) AS "充值金额异常用户数",
       COALESCE(SUM(h.held_10071), 0) AS "黑子哲也持有数",
       CAST(COALESCE(SUM(h.held_10071), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "黑子哲也持有比例",
       COALESCE(SUM(h.held_10072), 0) AS "火神大我持有数",
       CAST(COALESCE(SUM(h.held_10072), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "火神大我持有比例",
       COALESCE(SUM(h.held_10073), 0) AS "绿间真太郎持有数",
       CAST(COALESCE(SUM(h.held_10073), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "绿间真太郎持有比例",
       COALESCE(SUM(h.held_10074), 0) AS "黄濑凉太持有数",
       CAST(COALESCE(SUM(h.held_10074), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "黄濑凉太持有比例",
       COALESCE(SUM(h.held_10080), 0) AS "紫原敦持有数",
       CAST(COALESCE(SUM(h.held_10080), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "紫原敦持有比例",
       COALESCE(SUM(h.held_10081), 0) AS "青峰大辉持有数",
       CAST(COALESCE(SUM(h.held_10081), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "青峰大辉持有比例",
       COALESCE(SUM(h.held_10082), 0) AS "赤司征十郎持有数",
       CAST(COALESCE(SUM(h.held_10082), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "赤司征十郎持有比例",
       COALESCE(SUM(h.held_10098), 0) AS "木吉铁平持有数",
       CAST(COALESCE(SUM(h.held_10098), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "木吉铁平持有比例",
       COALESCE(SUM(h.held_10099), 0) AS "黛千寻持有数",
       CAST(COALESCE(SUM(h.held_10099), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "黛千寻持有比例",
       COALESCE(SUM(h.held_10100), 0) AS "高尾和成持有数",
       CAST(COALESCE(SUM(h.held_10100), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "高尾和成持有比例",
       COALESCE(SUM(h.held_10101), 0) AS "冰室辰也持有数",
       CAST(COALESCE(SUM(h.held_10101), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "冰室辰也持有比例",
       COALESCE(SUM(h.held_10102), 0) AS "笠松幸男持有数",
       CAST(COALESCE(SUM(h.held_10102), 0) AS DOUBLE) / NULLIF(COUNT(u.user_id), 0) AS "笠松幸男持有比例"
FROM Tiers t
LEFT JOIN UserTier u ON t.tier_order = u.tier_order
LEFT JOIN UserHoldings h ON u.user_id = h.user_id
GROUP BY t.tier_order, t.tier_name
ORDER BY t.tier_order;
