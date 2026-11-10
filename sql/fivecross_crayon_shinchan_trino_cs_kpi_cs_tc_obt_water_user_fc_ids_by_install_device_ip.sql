/*
蜡笔小新繁体 OBT：异常创角 IP 或通知类昵称关联的未付费账号。
固定统计 2026-10-14（含）起的 OBT 数据，最终只输出去重 fc_id。

每个 fc_id 只取 OBT 首条 new_role 的 #ip。
先取首条，再排除无效 IP；首条 IP 为空时不回填后续创角的 IP。
同 IP 账号数先包含全部创角账号，满足 >20 后再排除真实付费账号。
新增昵称规则：card_battlepower 事件中，昵称以“社團/社長/工會/聯盟”开头、
以“通知/通訊/訊息/傳音/告知”结尾，中间可有任意内容（含空字符串）。
兼容简繁体，例如：社團重要通知、社長L傳音、工會通知。
两条规则独立命中后 UNION 去重，统一排除 OBT 真实付费账号。
*/
WITH
AccountNewRoleRanked AS (
    SELECT
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        NULLIF(LOWER(TRIM(CAST(v."#ip" AS VARCHAR))), '') AS registration_ip,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(CAST(v.fc_id AS VARCHAR))
            ORDER BY v."#event_time" ASC NULLS LAST,
                     CAST(v."#account_id" AS VARCHAR) ASC NULLS LAST,
                     CAST(v."#te_event_id" AS VARCHAR) ASC NULLS LAST
        ) AS rn
    FROM ta.v_event_18 v
    WHERE v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'new_role'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
),
AccountFirstIP AS (
    SELECT fc_id, registration_ip
    FROM AccountNewRoleRanked
    WHERE rn = 1
      AND registration_ip IS NOT NULL
      AND registration_ip NOT IN ('unknown', 'null', 'none', '0', '0.0.0.0', '::')
),
SuspiciousIPs AS (
    SELECT registration_ip
    FROM AccountFirstIP
    GROUP BY registration_ip
    HAVING COUNT(DISTINCT fc_id) > 20
),
SuspiciousNicknameUsers AS (
    SELECT DISTINCT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id
    FROM ta.v_event_18 v
    WHERE v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'rge'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND REGEXP_LIKE(
          TRIM(CAST(v.new_name AS VARCHAR)),
          '^(社團|社团|社長|社长|工會|工会|聯盟|联盟|會長|会长).*(通知|通訊|通讯|訊息|讯息|傳音|传音|告知)$'
      )
),
SuspectAccounts AS (
    SELECT a.fc_id
    FROM AccountFirstIP a
    JOIN SuspiciousIPs i ON a.registration_ip = i.registration_ip
    UNION
    SELECT fc_id FROM SuspiciousNicknameUsers
),
PaidUsers AS (
    SELECT DISTINCT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id
    FROM ta.v_event_18 v
    WHERE v."$part_date" >= '2026-10-14'
      AND v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      AND COALESCE(UPPER(TRIM(CAST(v.pay_currency AS VARCHAR))), '') <> 'COIN'
      AND TRY_CAST(v.pay_amount AS DOUBLE) > 0
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
)
SELECT DISTINCT s.fc_id
FROM SuspectAccounts s
LEFT JOIN PaidUsers p ON s.fc_id = p.fc_id
WHERE p.fc_id IS NULL;
