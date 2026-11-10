
    SELECT
        daily.lcm_id,
        -- Calculate 30-day revenue for each user using DATEDIFF for MaxCompute.
        SUM(daily.purchase) AS revenue
    FROM 
        dm_platform.daily_lcx_user_info daily
    WHERE 
        -- We use a LEFT JOIN and filter the right table in the ON clause.
        -- This ensures all users from the cohort are kept, even those with no activity.
            daily.day = '20251215'
        AND daily.app_id = 65002005
    GROUP BY
        daily.lcm_id
    ORDER BY revenue DESC
