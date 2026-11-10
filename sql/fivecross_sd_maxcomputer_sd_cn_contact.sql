WITH target_users AS (
    SELECT 
        mbga_uid,
        user_id,
        level,
        total_pay,
        from_unixtime(cast(last_login as int)) as last_login_time
    FROM g13002010.daily_user_snapshot 
    -- 动态获取昨天的分区日期，例如 20260812，避免手动改写导致没数据
    WHERE day = CAST(TO_CHAR(DATEADD(GETDATE(), -1, 'dd'), 'yyyymmdd') AS BIGINT) 
      AND from_unixtime(cast(last_login as int)) >= '2026-01-01 00:00:00' 
      AND from_unixtime(cast(last_login as int)) <= '2026-07-14 00:00:00'
),
user_map AS (
    SELECT
        lcm_id,
        MAX(did) AS did
    FROM dm_platform.lcx_user_info
    WHERE CAST(app_id AS STRING) = '13002010'
      AND lcm_id IS NOT NULL
      AND day >= 20170101
    GROUP BY lcm_id
),
reg_contact AS (
    SELECT
        account AS lcm_id,
        MAX(NULLIF(GET_JSON_OBJECT(contact_info, '$.encrypt_phone'), '<nil>')) AS encrypt_phone
    FROM dm_platform.dm_standard_reg_account_label
    WHERE CAST(app_id AS STRING) = '13002010'
      AND account IS NOT NULL
      AND (COALESCE(GET_JSON_OBJECT(contact_info, '$.encrypt_phone'), '') <> '' AND GET_JSON_OBJECT(contact_info, '$.encrypt_phone') <> '<nil>')
    GROUP BY account
),
store_contact AS (
    SELECT did, MAX(encrypt_phone) AS encrypt_phone
    FROM (
        SELECT CAST(user_id AS STRING) AS did, NULLIF(encrypt_phone, '<nil>') AS encrypt_phone
        FROM dm_platform.temp_user_account_history
        WHERE (COALESCE(encrypt_phone, '') <> '' AND encrypt_phone <> '<nil>')
        
        UNION ALL
        
        SELECT CAST(user_id AS STRING) AS did, NULLIF(encrypt_phone, '<nil>') AS encrypt_phone
        FROM dm_platform.user_account
        WHERE ds > 20191201 
          AND (COALESCE(encrypt_phone, '') <> '' AND encrypt_phone <> '<nil>')
        
        UNION ALL
        
        SELECT CAST(user_id AS STRING) AS did, NULLIF(encrypt_phone, '<nil>') AS encrypt_phone
        FROM dm_platform.temp_user_account
        WHERE hour > 20191201 
          AND (COALESCE(encrypt_phone, '') <> '' AND encrypt_phone <> '<nil>')
    ) t
    WHERE encrypt_phone IS NOT NULL
    GROUP BY did
)

SELECT 
    t.mbga_uid,
    t.user_id,
    t.level,
    t.total_pay,
    t.last_login_time,
    COALESCE(rc.encrypt_phone, sc.encrypt_phone) AS phone_number
FROM target_users t
JOIN user_map m ON CAST(t.mbga_uid AS STRING) = CAST(m.lcm_id AS STRING)
LEFT JOIN reg_contact rc ON CAST(m.lcm_id AS STRING) = CAST(rc.lcm_id AS STRING)
LEFT JOIN store_contact sc ON CAST(m.did AS STRING) = CAST(sc.did AS STRING)
WHERE COALESCE(rc.encrypt_phone, sc.encrypt_phone) IS NOT NULL;
