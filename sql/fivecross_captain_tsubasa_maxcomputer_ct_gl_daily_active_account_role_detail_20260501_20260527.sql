WITH base AS (
    SELECT DISTINCT
        day,
        lcm_id,
        role_id
    FROM
        g65002005.daily_game_log
    WHERE
        day >= 20260501 AND day <= 20260527
        AND event_name IN ('client_hall_into', 'client_land_into', 'client_sdk_login')
        AND lcm_id IS NOT NULL
),

lcm_with_role AS (
    SELECT DISTINCT
        lcm_id
    FROM
        base
    WHERE
        role_id IS NOT NULL
        AND TRIM(CAST(role_id AS STRING)) <> ''
)

SELECT DISTINCT
    b.day,
    b.lcm_id,
    b.role_id
FROM
    base b
    LEFT JOIN lcm_with_role r ON b.lcm_id = r.lcm_id
WHERE
    -- lcm_id has any non-empty role_id, keep only non-empty role_id rows.
    (
        b.role_id IS NOT NULL
        AND TRIM(CAST(b.role_id AS STRING)) <> ''
    )
    -- Keep empty role_id rows only when the lcm_id never has a role_id.
    OR r.lcm_id IS NULL
ORDER BY
    b.day,
    b.lcm_id,
    b.role_id;
