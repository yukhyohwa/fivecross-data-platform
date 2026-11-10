    SELECT mbga_uid,user_id,nickname
    FROM 
        g63002013.daily_user_snapshot
    WHERE 
        SUBSTR(zone, 1, 1) = '3' -- 取zone第一位为3的南美区域
        AND day = 20260128
