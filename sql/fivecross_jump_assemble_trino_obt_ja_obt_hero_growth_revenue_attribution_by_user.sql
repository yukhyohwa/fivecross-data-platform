

WITH
SnapshotParam AS (
    SELECT MAX(CAST(v."$part_date" AS DATE)) AS snapshot_date
    FROM ta.v_event_23 v
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'daily_role_card_snapshot'
),

Params AS (
    SELECT
        DATE '2026-06-24' AS start_date,
        COALESCE(snapshot_date, CURRENT_DATE) AS snapshot_date,
        DATE_ADD('day', -1, COALESCE(snapshot_date, CURRENT_DATE)) AS as_of_date
    FROM SnapshotParam
),

UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('is_water')
),

PurchaseDetail AS (
    SELECT
        v."#account_id" AS lcx_id,
        CAST(v."$part_date" AS DATE) AS pay_date,
        CAST(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.curamt') AS DOUBLE)
            / COALESCE(ex.exchange, 1.0) AS revenue_usd
    FROM ta.v_event_23 v
    CROSS JOIN Params p
    LEFT JOIN UserBlacklist ub
        ON v."#account_id" = ub.lcx_id
    LEFT JOIN ta_dim.ta_exchange ex
        ON v."$part_date" = ex.ex_date
       AND JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.cur') = ex.currency
    WHERE v."$part_event" = 'PURCHASE'
      AND CAST(v."$part_date" AS DATE) BETWEEN p.start_date AND p.snapshot_date
      AND COALESCE(JSON_EXTRACT_SCALAR(CAST(v.payload AS JSON), '$.validationtype'), '') <> 'SANDBOX_RECEIPT'
      AND ub.lcx_id IS NULL
),

UserRevenue AS (
    SELECT
        lcx_id,
        SUM(revenue_usd) AS total_revenue_usd
    FROM PurchaseDetail
    GROUP BY 1
    HAVING SUM(revenue_usd) > 0
),

LatestCardSnapshot AS (
    SELECT *
    FROM (
        SELECT
            COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
            TRY_CAST(v.card_id AS INTEGER) AS card_id,
            v.card_name,
            CASE
                WHEN TRY_CAST(v.card_id AS INTEGER) IN (126, 145) THEN 'S'
                WHEN TRY_CAST(v.card_id AS INTEGER) IN (135, 125, 158, 122, 110, 134, 113, 127, 157, 159, 132) THEN 'A'
                ELSE 'R/B'
            END AS card_quality,
            LEAST(COALESCE(cardinality(v.card_awake), 0), 3) AS awaken_count,
            LEAST(
                COALESCE(cardinality(filter(v.card_talent_slot, x -> x <> '0' AND x <> '')), 0),
                32
            ) AS talent_count,
            ROW_NUMBER() OVER (
                PARTITION BY
                    COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id"),
                    TRY_CAST(v.card_id AS INTEGER)
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 v
        CROSS JOIN Params p
        LEFT JOIN UserBlacklist ub
            ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
        WHERE v."$part_event" = 'daily_role_card_snapshot'
          AND CAST(v."$part_date" AS DATE) BETWEEN p.start_date AND p.snapshot_date
          AND ub.lcx_id IS NULL
          AND TRY_CAST(v.card_id AS INTEGER) IS NOT NULL
    )
    WHERE rn = 1
),

UserHeroCost AS (
    SELECT
        lcs.lcx_id,
        lcs.card_id,
        COALESCE(lcs.card_name, CAST(lcs.card_id AS VARCHAR)) AS card_name,
        CASE
            WHEN lcs.card_quality = 'S' THEN 'S级角色'
            WHEN lcs.card_quality = 'A' THEN 'A级角色'
            ELSE 'R/B级角色'
        END AS quality_group,
        (
            CASE
                WHEN lcs.card_quality = 'S' THEN 6000
                WHEN lcs.card_quality = 'A' THEN 4000
                ELSE 2000
            END
            * (1 + lcs.awaken_count)
        )
        + (lcs.talent_count * 130) AS jump_star_cost
    FROM LatestCardSnapshot lcs
    INNER JOIN UserRevenue ur
        ON lcs.lcx_id = ur.lcx_id
    WHERE lcs.card_quality IN ('S','A')
),

UserTotalCost AS (
    SELECT 
        lcx_id,
        SUM(jump_star_cost) AS user_total_cost
    FROM UserHeroCost
    GROUP BY 1
),

UserHeroAttribution AS (
    SELECT
        uhc.lcx_id,
        uhc.card_id,
        uhc.card_name,
        uhc.quality_group,
        uhc.jump_star_cost,
        CAST(uhc.jump_star_cost AS DOUBLE) / NULLIF(utc.user_total_cost, 0) AS cost_ratio,
        (CAST(uhc.jump_star_cost AS DOUBLE) / NULLIF(utc.user_total_cost, 0)) * ur.total_revenue_usd AS attributed_usd
    FROM UserHeroCost uhc
    INNER JOIN UserTotalCost utc ON uhc.lcx_id = utc.lcx_id
    INNER JOIN UserRevenue ur ON uhc.lcx_id = ur.lcx_id
),

GlobalRevenue AS (
    SELECT
        SUM(total_revenue_usd) AS total_revenue_usd
    FROM UserRevenue
),

FinalAgg AS (
    SELECT
        uha.quality_group,
        uha.card_id,
        uha.card_name,
        COUNT(DISTINCT uha.lcx_id) AS paying_user_card_cnt,
        SUM(uha.jump_star_cost) AS total_jump_star_cost,
        SUM(uha.attributed_usd) AS total_attributed_usd
    FROM UserHeroAttribution uha
    GROUP BY 1, 2, 3
)

SELECT
    CAST(p.start_date AS VARCHAR) || ' ~ ' || CAST(p.snapshot_date AS VARCHAR) AS "业务统计区间",
    CAST(p.snapshot_date AS VARCHAR) AS "使用快照日期",
    f.quality_group AS "角色组",
    f.card_id AS "英雄ID",
    f.card_name AS "英雄名",
    '5.全部养成合计' AS "养成项",
    f.paying_user_card_cnt AS "持有该英雄的付费用户数",
    f.total_jump_star_cost AS "该英雄在付费用户群的总星耗",
    ROUND(f.total_attributed_usd, 2) AS "估算分摊收入USD",
    ROUND(f.total_attributed_usd / NULLIF(g.total_revenue_usd, 0), 4) AS "占大盘总收入比例"
FROM FinalAgg f
CROSS JOIN Params p
CROSS JOIN GlobalRevenue g
ORDER BY 
    CASE
        WHEN f.quality_group = 'R/B级角色' THEN 1
        WHEN f.quality_group = 'A级角色' THEN 2
        WHEN f.quality_group = 'S级角色' THEN 3
        ELSE 5
    END,
    f.total_attributed_usd DESC,
    f.card_id;
