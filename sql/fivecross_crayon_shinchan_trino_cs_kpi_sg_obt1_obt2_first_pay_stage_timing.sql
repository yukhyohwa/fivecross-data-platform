/*
新加坡 OBT 首充路径（按首次创角时间分批，不按停服/付费日期切分）。
OBT1: 2026-05-08~2026-05-14（开服首周）
OBT2: 2026-06-15~2026-06-21（开服首周）
范围：fixed_country=新加坡且 fixed_os=Android。
首充：账号维度、首次有效 charge；剔除内部/Windows/水军、sandbox 与免费订单。
*/
WITH Cfg AS (
    SELECT
        DATE '2026-05-08' AS obt1_start,
        DATE '2026-05-14' AS obt1_end,
        DATE '2026-06-15' AS obt2_start,
        DATE '2026-06-21' AS obt2_end
),
BlockedUsers AS (
    SELECT DISTINCT CAST("#user_id" AS VARCHAR) AS user_id
    FROM user_result_cluster_13
    WHERE cluster_name IN ('internal_users', 'is_windows', 'is_water')
),
TargetUsers AS (
    SELECT CAST("#user_id" AS VARCHAR) AS user_id
    FROM user_result_cluster_13
    GROUP BY 1
    HAVING MAX(CASE WHEN cluster_name = 'fixed_country' AND tag_value = '新加坡' THEN 1 ELSE 0 END) = 1
       AND MAX(CASE WHEN cluster_name = 'fixed_os' AND tag_value = 'Android' THEN 1 ELSE 0 END) = 1
),
Registration AS (
    SELECT
        CAST(e."#account_id" AS VARCHAR) AS account_id,
        MIN(e."#event_time") AS register_time
    FROM ta.v_event_13 e
    CROSS JOIN Cfg c
    INNER JOIN TargetUsers t ON CAST(e."#user_id" AS VARCHAR) = t.user_id
    LEFT JOIN BlockedUsers b ON CAST(e."#user_id" AS VARCHAR) = b.user_id
    WHERE e."$part_event" = 'new_role'
      AND (
          CAST(e."$part_date" AS DATE) BETWEEN c.obt1_start AND c.obt1_end
          OR CAST(e."$part_date" AS DATE) BETWEEN c.obt2_start AND c.obt2_end
      )
      AND e."#account_id" IS NOT NULL
      AND b.user_id IS NULL
    GROUP BY 1
),
Cohort AS (
    SELECT
        r.account_id,
        r.register_time,
        CASE WHEN CAST(r.register_time AS DATE) BETWEEN c.obt1_start AND c.obt1_end
             THEN 'OBT1（2026-05-08~05-14）'
             ELSE 'OBT2（2026-06-15~06-21）'
        END AS test_group
    FROM Registration r
    CROSS JOIN Cfg c
),
FirstPayRaw AS (
    SELECT
        c.account_id,
        c.test_group,
        c.register_time,
        e."#event_time" AS first_pay_time,
        ROW_NUMBER() OVER (PARTITION BY c.account_id ORDER BY e."#event_time") AS rn
    FROM Cohort c
    JOIN ta.v_event_13 e
     ON CAST(e."#account_id" AS VARCHAR) = c.account_id
     AND CAST(e."#event_time" AS TIMESTAMP) >= CAST(c.register_time AS TIMESTAMP)
    LEFT JOIN BlockedUsers b ON CAST(e."#user_id" AS VARCHAR) = b.user_id
    WHERE e."$part_event" = 'charge'
      AND b.user_id IS NULL
      AND (e.sandbox IS NULL OR e.sandbox = FALSE)
      AND (e.is_freebuy IS NULL OR e.is_freebuy = FALSE)
      AND COALESCE(TRY_CAST(e.pay_amount_usd AS DOUBLE), 0) > 0
      AND (
          (c.test_group = 'OBT1（2026-05-08~05-14）' AND CAST(e."$part_date" AS DATE) BETWEEN DATE '2026-05-08' AND DATE '2026-05-14')
          OR (c.test_group = 'OBT2（2026-06-15~06-21）' AND CAST(e."$part_date" AS DATE) BETWEEN DATE '2026-06-15' AND DATE '2026-06-21')
      )
),
FirstPay AS (
    SELECT * FROM FirstPayRaw WHERE rn = 1
),
LastMainlineBeforePay AS (
    SELECT account_id, stage_id
    FROM (
        SELECT
            p.account_id,
            TRY_CAST(e.a_rst[1].id AS BIGINT) AS stage_id,
            ROW_NUMBER() OVER (PARTITION BY p.account_id ORDER BY e."#event_time" DESC) AS rn
        FROM FirstPay p
        JOIN ta.v_event_13 e
          ON CAST(e."#account_id" AS VARCHAR) = p.account_id
         AND CAST(e."#event_time" AS TIMESTAMP) >= CAST(p.register_time AS TIMESTAMP)
         AND CAST(e."#event_time" AS TIMESTAMP) <= CAST(p.first_pay_time AS TIMESTAMP)
        WHERE e."#event_name" = 'stage_fight'
          AND TRY_CAST(e.a_rst[1].key AS INTEGER) = 1001
    ) x
    WHERE rn = 1
),
StageDim AS (
    SELECT
        TRY_CAST("stage_id@stage_id" AS BIGINT) AS stage_id,
        MAX("stage_id@stage_name_show") AS stage_name
    FROM ta_dim.dim_13_0_18203
    GROUP BY 1
),
UserFirstPay AS (
    SELECT
        p.account_id,
        p.test_group,
        DATE_DIFF('minute', CAST(p.register_time AS TIMESTAMP), CAST(p.first_pay_time AS TIMESTAMP)) AS minutes_to_first_pay,
        COALESCE(d.stage_name, '创角后尚未挑战主线') AS first_pay_stage
    FROM FirstPay p
    LEFT JOIN LastMainlineBeforePay s ON p.account_id = s.account_id
    LEFT JOIN StageDim d ON s.stage_id = d.stage_id
),
Distribution AS (
    SELECT test_group, '首充关卡' AS metric, first_pay_stage AS bucket, COUNT(*) AS users
    FROM UserFirstPay
    GROUP BY 1, 2, 3
    UNION ALL
    SELECT
        test_group,
        '注册后首充时间' AS metric,
        CASE
            WHEN minutes_to_first_pay BETWEEN 0 AND 10 THEN '01. 0-10分钟'
            WHEN minutes_to_first_pay BETWEEN 11 AND 30 THEN '02. 11-30分钟'
            WHEN minutes_to_first_pay BETWEEN 31 AND 60 THEN '03. 31-60分钟'
            WHEN minutes_to_first_pay BETWEEN 61 AND 120 THEN '04. 61-120分钟'
            WHEN minutes_to_first_pay BETWEEN 121 AND 180 THEN '05. 121-180分钟'
            WHEN minutes_to_first_pay BETWEEN 181 AND 240 THEN '06. 181-240分钟'
            WHEN minutes_to_first_pay > 240 THEN '07. 240分钟以上'
            ELSE '08. 异常（付费早于注册）'
        END AS bucket,
        COUNT(*) AS users
    FROM UserFirstPay
    GROUP BY 1, 2, 3
)
SELECT
    test_group AS "测试批次",
    metric AS "分布维度",
    bucket AS "分布项",
    users AS "首充人数",
    ROUND(users * 100.0 / SUM(users) OVER (PARTITION BY test_group, metric), 2) AS "占该批首充用户比(%)"
FROM Distribution
ORDER BY "测试批次", "分布维度", "首充人数" DESC, "分布项";
