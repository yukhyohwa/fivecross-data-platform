/*
================================================================================
Game    : Jump Assemble
Report  : OBT S-card & A-card Growth and ARPU by Paying Groups (D+0 to D+2)
Purpose : Analyze Gojo (S-rank, 6/24) and Itadori (A-rank, 7/1) ownership, 
          awaken, level, talent, and ARPU across different paying groups 
          on their respective D+0, D+1, and D+2 dates.
================================================================================
*/

WITH char_dates AS (
    -- 五条悟 (Gojo)
    SELECT '五条悟 (Gojo)' AS char_name, 'S' AS char_quality, DATE '2026-06-24' AS release_date, 'd+0' AS day_label, DATE '2026-06-24' AS target_date UNION ALL
    SELECT '五条悟 (Gojo)' AS char_name, 'S' AS char_quality, DATE '2026-06-24' AS release_date, 'd+1' AS day_label, DATE '2026-06-25' AS target_date UNION ALL
    SELECT '五条悟 (Gojo)' AS char_name, 'S' AS char_quality, DATE '2026-06-24' AS release_date, 'd+2' AS day_label, DATE '2026-06-26' AS target_date UNION ALL
    -- 虎杖 (Itadori)
    SELECT '虎杖 (Itadori)' AS char_name, 'A' AS char_quality, DATE '2026-07-01' AS release_date, 'd+0' AS day_label, DATE '2026-07-01' AS target_date UNION ALL
    SELECT '虎杖 (Itadori)' AS char_name, 'A' AS char_quality, DATE '2026-07-01' AS release_date, 'd+1' AS day_label, DATE '2026-07-02' AS target_date UNION ALL
    SELECT '虎杖 (Itadori)' AS char_name, 'A' AS char_quality, DATE '2026-07-01' AS release_date, 'd+2' AS day_label, DATE '2026-07-03' AS target_date
),

-- 全局的购买记录，计算累积付费和当日付费
purchase_detail AS (
    SELECT
        v."#account_id" AS account_id,
        CAST(v."$part_date" AS DATE) AS event_date,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(ex.exchange, 1.0) AS revenue_usd
    FROM ta.v_event_23 v
    LEFT JOIN ta_dim.ta_exchange ex
        ON v."$part_date" = ex.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND CAST(v."$part_date" AS DATE) BETWEEN DATE '2026-06-24' AND DATE '2026-07-03'
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
),

-- 获取目标日期活跃且有每日卡牌快照的用户 (作为分母的活跃群体)
base_users AS (
    SELECT DISTINCT
        c.char_name,
        c.day_label,
        c.target_date,
        COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR)) AS account_id
    FROM ta.v_event_23 v
    JOIN char_dates c ON CAST(v."$part_date" AS DATE) = c.target_date + INTERVAL '1' DAY
    WHERE v."$part_event" = 'daily_role_card_snapshot'
),

-- 计算每个活跃用户在目标日期的历史累计付费(决定所在的付费群体)及当日付费(计算ARPU)
user_finances AS (
    SELECT
        b.char_name,
        b.day_label,
        b.target_date,
        b.account_id,
        COALESCE(SUM(pd.revenue_usd) FILTER (WHERE pd.event_date <= b.target_date), 0.0) AS cum_revenue_usd,
        COALESCE(SUM(pd.revenue_usd) FILTER (WHERE pd.event_date = b.target_date), 0.0) AS daily_revenue_usd
    FROM base_users b
    LEFT JOIN purchase_detail pd
        ON pd.account_id = b.account_id
    GROUP BY 1, 2, 3, 4
),

-- 提取特定角色的卡牌快照信息 (关联觉醒、等级、天赋等)
target_card_snapshot AS (
    SELECT * FROM (
        SELECT
            c.char_name,
            c.day_label,
            c.target_date,
            COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR)) AS account_id,
            card_level,
            cardinality(card_awake) AS awaken_count,
            cardinality(filter(card_talent_slot, x -> x <> '0' AND x <> '')) AS talent_count,
            ROW_NUMBER() OVER (
                PARTITION BY c.char_name, c.target_date, COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR))
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 v
        JOIN char_dates c ON CAST(v."$part_date" AS DATE) = c.target_date + INTERVAL '1' DAY
        WHERE v."$part_event" = 'daily_role_card_snapshot'
          AND (
              (c.char_name = '五条悟 (Gojo)' AND (CAST(card_id AS VARCHAR) IN ('145', '126') OR card_name LIKE '%五条悟%'))
              OR (c.char_name = '虎杖 (Itadori)' AND card_name LIKE '%虎杖%')
          )
    ) WHERE rn = 1
),

-- 提取活跃用户是否拥有五条悟 (用于对虎杖的群体进行区分)
gojo_snapshot AS (
    SELECT DISTINCT
        c.target_date,
        COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR)) AS account_id
    FROM ta.v_event_23 v
    JOIN (SELECT DISTINCT target_date FROM char_dates) c ON CAST(v."$part_date" AS DATE) = c.target_date + INTERVAL '1' DAY
    WHERE v."$part_event" = 'daily_role_card_snapshot'
      AND (CAST(card_id AS VARCHAR) IN ('145', '126') OR card_name LIKE '%五条悟%')
),

-- 合并财务和卡牌数据，划分付费群体
user_metrics AS (
    SELECT
        uf.char_name,
        uf.day_label,
        uf.target_date,
        uf.account_id,
        CASE
            WHEN uf.cum_revenue_usd = 0.0 THEN '0.免费用户'
            WHEN uf.cum_revenue_usd <= 10.0 THEN 'a.(0,10]'
            WHEN uf.cum_revenue_usd <= 50.0 THEN 'b.(10,50]'
            WHEN uf.cum_revenue_usd <= 100.0 THEN 'c.(50,100]'
            WHEN uf.cum_revenue_usd <= 300.0 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier,
        CASE 
            WHEN uf.char_name = '五条悟 (Gojo)' THEN '-' 
            WHEN gs.account_id IS NOT NULL THEN '1.有五条悟' 
            ELSE '0.无五条悟' 
        END AS gojo_ownership_group,
        uf.daily_revenue_usd,
        CASE WHEN tc.account_id IS NOT NULL THEN 1 ELSE 0 END AS is_owner,
        tc.card_level,
        tc.awaken_count,
        tc.talent_count
    FROM user_finances uf
    LEFT JOIN target_card_snapshot tc
        ON uf.char_name = tc.char_name
       AND uf.target_date = tc.target_date
       AND uf.account_id = tc.account_id
    LEFT JOIN gojo_snapshot gs
        ON uf.target_date = gs.target_date
       AND uf.account_id = gs.account_id
)

-- 最终聚合输出
SELECT
    char_name AS "目标角色",
    day_label AS "天数 (d+X)",
    target_date AS "日期",
    recharge_tier AS "截至当日_历史付费群体",
    gojo_ownership_group AS "是否拥有五条悟",
    COUNT(DISTINCT account_id) AS "群体活跃人数",
    SUM(is_owner) AS "持有_绝对数",
    ROUND(SUM(is_owner) * 1.0000 / NULLIF(COUNT(DISTINCT account_id), 0), 4) AS "持有_人均数(持有率)",
    ROUND(AVG(CAST(card_level AS DOUBLE)), 2) AS "持有者_平均等级",
    ROUND(AVG(CAST(awaken_count AS DOUBLE)), 2) AS "持有者_平均觉醒",
    ROUND(AVG(CAST(talent_count AS DOUBLE)), 2) AS "持有者_平均天赋",
    ROUND(SUM(daily_revenue_usd) / NULLIF(COUNT(DISTINCT account_id), 0), 2) AS "当日人均付费_ARPU",
    ROUND(SUM(daily_revenue_usd) / NULLIF(COUNT(DISTINCT CASE WHEN daily_revenue_usd > 0 THEN account_id END), 0), 2) AS "当日付费者人均_ARPPU"
FROM user_metrics
GROUP BY 1, 2, 3, 4, 5
ORDER BY
    char_name DESC,
    target_date ASC,
    recharge_tier ASC,
    gojo_ownership_group DESC;


-- ================================================================================
-- 补充分析：7月1日同时拥有“虎杖”和“五条悟”的玩家，在7月1日和7月2日的五条悟养成数据
-- ================================================================================
/*
WITH cohort_users AS (
    -- 筛选 7月1日 同时拥有虎杖和五条悟的用户 (7月1日的养成状态在 7月2日的每日快照中)
    SELECT 
        COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR)) AS account_id,
        MAX(CASE WHEN card_name LIKE '%虎杖%' THEN 1 ELSE 0 END) AS has_itadori,
        MAX(CASE WHEN CAST(card_id AS VARCHAR) IN ('145', '126') OR card_name LIKE '%五条悟%' THEN 1 ELSE 0 END) AS has_gojo
    FROM ta.v_event_23 v
    WHERE v."$part_event" = 'daily_role_card_snapshot'
      AND CAST(v."$part_date" AS DATE) = DATE '2026-07-02'
    GROUP BY 1
    HAVING MAX(CASE WHEN card_name LIKE '%虎杖%' THEN 1 ELSE 0 END) = 1
       AND MAX(CASE WHEN CAST(card_id AS VARCHAR) IN ('145', '126') OR card_name LIKE '%五条悟%' THEN 1 ELSE 0 END) = 1
),

dates AS (
    -- 需要观察的日期及其快照时间
    SELECT DATE '2026-07-01' AS target_date, DATE '2026-07-02' AS snapshot_date, '2026-07-01' AS day_label UNION ALL
    SELECT DATE '2026-07-02' AS target_date, DATE '2026-07-03' AS snapshot_date, '2026-07-02' AS day_label
),

user_target_dates AS (
    SELECT 
        c.account_id,
        d.target_date,
        d.snapshot_date,
        d.day_label
    FROM cohort_users c
    CROSS JOIN dates d
),

purchase_detail_part2 AS (
    SELECT
        v."#account_id" AS account_id,
        CAST(v."$part_date" AS DATE) AS event_date,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE) / COALESCE(ex.exchange, 1.0) AS revenue_usd
    FROM ta.v_event_23 v
    LEFT JOIN ta_dim.ta_exchange ex
        ON v."$part_date" = ex.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND CAST(v."$part_date" AS DATE) <= DATE '2026-07-02'
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
),

user_finances_part2 AS (
    SELECT
        ut.account_id,
        ut.target_date,
        ut.day_label,
        ut.snapshot_date,
        COALESCE(SUM(pd.revenue_usd), 0.0) AS cum_revenue_usd
    FROM user_target_dates ut
    LEFT JOIN purchase_detail_part2 pd
        ON pd.account_id = ut.account_id
       AND pd.event_date <= ut.target_date
    GROUP BY 1, 2, 3, 4
),

gojo_card_snapshot_part2 AS (
    SELECT * FROM (
        SELECT
            ut.target_date,
            COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR)) AS account_id,
            card_level,
            cardinality(card_awake) AS awaken_count,
            cardinality(filter(card_talent_slot, x -> x <> '0' AND x <> '')) AS talent_count,
            ROW_NUMBER() OVER (
                PARTITION BY ut.target_date, COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR))
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 v
        JOIN user_target_dates ut 
            ON COALESCE(v.sdkcommon.lcx_id, v.fc_sdk_common.lcx_id, CAST(v."#account_id" AS VARCHAR)) = ut.account_id
           AND CAST(v."$part_date" AS DATE) = ut.snapshot_date
        WHERE v."$part_event" = 'daily_role_card_snapshot'
          AND (CAST(card_id AS VARCHAR) IN ('145', '126') OR card_name LIKE '%五条悟%')
    ) WHERE rn = 1
)

SELECT
    uf.day_label AS "分析日期",
    CASE
        WHEN uf.cum_revenue_usd = 0.0 THEN '0.免费用户'
        WHEN uf.cum_revenue_usd <= 10.0 THEN 'a.(0,10]'
        WHEN uf.cum_revenue_usd <= 50.0 THEN 'b.(10,50]'
        WHEN uf.cum_revenue_usd <= 100.0 THEN 'c.(50,100]'
        WHEN uf.cum_revenue_usd <= 300.0 THEN 'd.(100,300]'
        ELSE 'e.(300,∞]'
    END AS "截至当日_历史付费群体",
    COUNT(DISTINCT uf.account_id) AS "双持有玩家数量",
    ROUND(AVG(CAST(g.card_level AS DOUBLE)), 2) AS "五条悟_平均等级",
    ROUND(AVG(CAST(g.awaken_count AS DOUBLE)), 2) AS "五条悟_平均觉醒",
    ROUND(AVG(CAST(g.talent_count AS DOUBLE)), 2) AS "五条悟_平均天赋"
FROM user_finances_part2 uf
LEFT JOIN gojo_card_snapshot_part2 g
    ON uf.account_id = g.account_id
   AND uf.target_date = g.target_date
GROUP BY 1, 2
ORDER BY 1 ASC, 2 ASC;
*/

