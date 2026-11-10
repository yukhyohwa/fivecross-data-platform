/*
================================================================================
Report : Slam Dunk TC - Daily Card Talent Distribution
Project: ThinkingData Project 20 (Trino)

Parameter
  - ${PartDate:date1}: snapshot date range.

Talent definition
  - `skill` is a JSON-encoded map: card ID -> array of talent-node IDs.
  - Its eight-digit map keys must not be counted as talent nodes.
  - Flatten each map value array, then count only node IDs 4-6 digits long.
================================================================================
*/

WITH
UserVip AS (
    SELECT
        "$part_date",
        "user_id" AS role_id,
        CASE
            WHEN COALESCE(TRY_CAST(total_pay AS DOUBLE), 0) = 0 THEN 'V0'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 34 THEN 'V1'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 171 THEN 'V2'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 501 THEN 'V3'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 2501 THEN 'V4'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 5001 THEN 'V5'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 15001 THEN 'V6'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 50001 THEN 'V7'
            WHEN TRY_CAST(total_pay AS DOUBLE) < 200001 THEN 'V8'
            ELSE 'V9'
        END AS vip
    FROM (
        SELECT
            "$part_date",
            "user_id",
            total_pay,
            ROW_NUMBER() OVER (
                PARTITION BY "$part_date", "user_id"
                ORDER BY "#event_time" DESC
            ) AS rn
        FROM ta.v_event_20
        WHERE ${PartDate:date1}
          AND "$part_event" = 'user_snapshot'
    ) s
    WHERE rn = 1
),

CardTalent AS (
    SELECT
        v."$part_date",
        v."user_id" AS role_id,
        v.card_id,
        v.grade,
        COUNT(
            CASE
                WHEN LENGTH(TRIM(CAST(talent_node_id AS VARCHAR))) BETWEEN 4 AND 6 THEN 1
            END
        ) AS talent_node_count
    FROM ta.v_event_20 v
    CROSS JOIN UNNEST(
        map_values(
            CAST(
                json_parse(json_extract_scalar(CAST(v.skill AS JSON), '$'))
                AS MAP(VARCHAR, ARRAY(BIGINT))
            )
        )
    ) AS card_skill(talent_node_ids)
    CROSS JOIN UNNEST(talent_node_ids) AS node(talent_node_id)
    WHERE ${PartDate:date1}
      AND v."$part_event" = 'user_card_snapshot'
      AND TRY_CAST(v.status AS BIGINT) = 1
      AND v.skill IS NOT NULL
    GROUP BY 1, 2, 3, 4
)

SELECT
    '20' AS "遊戲ID",
    '灌籃繁體' AS "遊戲名稱",
    'TC' AS "地區",
    uv."$part_date" AS "$日期",
    COALESCE(uv.vip, 'V0') AS "VIP",
    c.card_id AS "球員ID",
    d."card_id@card_name" AS "球員名稱",
    d."card_id@team" AS "球員隊伍",
    CASE
        WHEN c.talent_node_count < 30 THEN '0~29'
        WHEN c.talent_node_count < 60 THEN '30~59'
        WHEN c.talent_node_count < 90 THEN '60~89'
        WHEN c.talent_node_count < 120 THEN '90~119'
        WHEN c.talent_node_count < 150 THEN '120~149'
        ELSE '150+'
    END AS "天賦區間",
    COUNT(DISTINCT c.role_id) AS "球員擁有人數",
    COUNT(DISTINCT CASE WHEN c.grade = '1' THEN c.role_id END) AS "D級",
    COUNT(DISTINCT CASE WHEN c.grade = '2' THEN c.role_id END) AS "C級",
    COUNT(DISTINCT CASE WHEN c.grade = '3' THEN c.role_id END) AS "B級",
    COUNT(DISTINCT CASE WHEN c.grade = '4' THEN c.role_id END) AS "A級",
    COUNT(DISTINCT CASE WHEN c.grade = '5' THEN c.role_id END) AS "S級"
FROM UserVip uv
INNER JOIN CardTalent c
    ON uv.role_id = c.role_id
   AND uv."$part_date" = c."$part_date"
LEFT JOIN ta_dim.dim_20_0_31407 d
    ON c.card_id = d."card_id@card_id"
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
ORDER BY "$日期" DESC, "VIP", "球員ID";
