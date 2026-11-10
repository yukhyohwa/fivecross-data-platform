/*
Skin gacha currency (id = 64), during the Namikaze Minato limited-magazine event.
Event window: 2026-08-12 through 2026-09-09 (inclusive).

Metric definitions
- id=64, nums < 0: skin-gacha coin consumption
- id=64, nums > 0: skin-gacha coin production
- Participation: distinct users with id=64 consumption
- paid Star: id=3, nums < 0, attributed to an id=64 consumption operation
  with the same user and second-level timestamp.
*/
WITH user_blacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),
resource_change AS (
    SELECT
        v."$part_date" AS part_date,
        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
        DATE_TRUNC('second', CAST(v."#event_time" AS timestamp(3))) AS event_time_sec,
        CAST(v.id AS BIGINT) AS resource_id,
        CAST(v.nums AS DOUBLE) AS nums
    FROM ta.v_event_23 v
    LEFT JOIN user_blacklist ub
        ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
    WHERE v."$part_event" = 'resource_change'
      AND v."$part_date" BETWEEN '2026-08-12' AND '2026-09-09'
      AND v.id IN (3, 64)
      AND ub.lcx_id IS NULL
),
skin_gacha_operations AS (
    SELECT
        part_date,
        lcx_id,
        event_time_sec,
        SUM(CASE WHEN nums < 0 THEN -nums ELSE 0 END) AS skin_coin_used,
        SUM(CASE WHEN nums > 0 THEN nums ELSE 0 END) AS skin_coin_produced
    FROM resource_change
    WHERE resource_id = 64
    GROUP BY 1, 2, 3
),
paid_star_operations AS (
    SELECT
        lcx_id,
        event_time_sec,
        SUM(CASE WHEN nums < 0 THEN -nums ELSE 0 END) AS paid_star_used
    FROM resource_change
    WHERE resource_id = 3
    GROUP BY 1, 2
),
operation_level AS (
    SELECT
        s.part_date,
        s.lcx_id,
        s.skin_coin_used,
        s.skin_coin_produced,
        COALESCE(p.paid_star_used, 0) AS paid_star_used
    FROM skin_gacha_operations s
    LEFT JOIN paid_star_operations p
        ON s.lcx_id = p.lcx_id
       AND s.event_time_sec = p.event_time_sec
),
daily_result AS (
    SELECT
        part_date,
        SUM(skin_coin_used) AS skin_coin_used_total,
        COUNT(DISTINCT CASE WHEN skin_coin_used > 0 THEN lcx_id END) AS participants,
        SUM(skin_coin_produced) AS skin_coin_produced_total,
        SUM(paid_star_used) AS paid_star_used_total,
        COUNT(DISTINCT CASE WHEN paid_star_used > 0 THEN lcx_id END) AS paid_star_users,
        COUNT(DISTINCT CASE
            WHEN skin_coin_produced > 0 AND paid_star_used > 0 THEN lcx_id
        END) AS paid_star_exchange_users,
        SUM(skin_coin_used) / NULLIF(COUNT(DISTINCT CASE WHEN skin_coin_used > 0 THEN lcx_id END), 0)
            AS avg_skin_coin_used_per_participant
    FROM operation_level
    GROUP BY 1
)
SELECT
    '分日' AS "统计类型",
    CAST(part_date AS VARCHAR) AS "日期",
    skin_coin_used_total AS "皮肤Gacha币消耗总数",
    participants AS "参与人数",
    skin_coin_produced_total AS "皮肤Gacha币产出总数",
    paid_star_used_total AS "关联付费跃之星消耗",
    paid_star_users AS "使用付费跃之星人数",
    paid_star_exchange_users AS "付费跃之星兑换皮肤Gacha币人数",
    avg_skin_coin_used_per_participant AS "人均皮肤Gacha币消耗"
FROM daily_result

UNION ALL

SELECT
    '累计汇总' AS "统计类型",
    '2026-08-12~' || CAST(MAX(part_date) AS VARCHAR) AS "日期",
    SUM(skin_coin_used) AS "皮肤Gacha币消耗总数",
    COUNT(DISTINCT CASE WHEN skin_coin_used > 0 THEN lcx_id END) AS "参与人数",
    SUM(skin_coin_produced) AS "皮肤Gacha币产出总数",
    SUM(paid_star_used) AS "关联付费跃之星消耗",
    COUNT(DISTINCT CASE WHEN paid_star_used > 0 THEN lcx_id END) AS "使用付费跃之星人数",
    COUNT(DISTINCT CASE
        WHEN skin_coin_produced > 0 AND paid_star_used > 0 THEN lcx_id
    END) AS "付费跃之星兑换皮肤Gacha币人数",
    SUM(skin_coin_used) / NULLIF(COUNT(DISTINCT CASE WHEN skin_coin_used > 0 THEN lcx_id END), 0)
        AS "人均皮肤Gacha币消耗"
FROM operation_level
ORDER BY CASE WHEN "统计类型" = '累计汇总' THEN 0 ELSE 1 END, "日期";
