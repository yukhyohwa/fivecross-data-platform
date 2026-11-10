-- Calculate daily new users (new registrations + users inactive for >90 days) and their subsequent revenue (LTV)
-- Cohort Date: Daily (20260101 to 20260105)
-- Metrics: Cohort Size, Day 0 to Day 6 Revenue (skipping Day 2 as requested), Cumulative Revenue 3/7/14/30/90/150, LTV 3/7/14/30/90/150
-- Broken down by Country Group (All, Top_6_Summary, Individual Countries) and User Type (New, Return_90d, New+Return_90d)

WITH 
    user_log AS (
        SELECT 
            lcm_id, 
            day, 
            purchase,
            reg_day,
            country_code,
            -- Get the previous login day for the user
            LAG(day, 1) OVER (PARTITION BY lcm_id ORDER BY day) as last_login_day
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 63002013 
          AND day >= 20250601 -- Look back ~6 months to ensure valid 90-day gap check
    ),
    
    calculated_gap AS (
        SELECT
            lcm_id,
            day,
            purchase,
            last_login_day,
            reg_day,
            country_code,
            -- Calculate days since last login
            DATEDIFF(
                TO_DATE(CAST(day AS STRING), 'yyyymmdd'), 
                TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 
                'dd'
            ) as days_since_last
        FROM user_log
    ),

    target_cohort AS (
        SELECT 
            lcm_id,
            day as cohort_date,
            country_code,
            CASE 
                WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN 'New' 
                ELSE 'Return_90d' 
            END as user_type
        FROM calculated_gap
        WHERE day BETWEEN 20260101 AND 20260105
          -- Condition: New User (NULL last login in window) OR Returning User (>90 days gap)
          AND (last_login_day IS NULL OR days_since_last > 90)
    ),

    target_cohort_user_type AS (
        -- Original breakdown (New or Return_90d)
        SELECT lcm_id, cohort_date, country_code, user_type 
        FROM target_cohort
        
        UNION ALL
        
        -- Combined user type (New + Return_90d)
        SELECT lcm_id, cohort_date, country_code, 'New+Return_90d' AS user_type 
        FROM target_cohort
    ),
    
    target_cohort_exploded AS (
        -- 1. All countries summary
        SELECT lcm_id, cohort_date, 'All' AS country_group, user_type 
        FROM target_cohort_user_type
        
        UNION ALL
        
        -- 2. 6 Countries Summary
        SELECT lcm_id, cohort_date, 'Top_6_Summary' AS country_group, user_type 
        FROM target_cohort_user_type 
        WHERE country_code IN ('TH','US','SG','AU','MY','CA')
        
        UNION ALL
        
        -- 3. Individual 6 Countries
        SELECT lcm_id, cohort_date, country_code AS country_group, user_type 
        FROM target_cohort_user_type 
        WHERE country_code IN ('TH','US','SG','AU','MY','CA')
    )

SELECT
    t.cohort_date,
    t.country_group,
    t.user_type,
    COUNT(DISTINCT t.lcm_id) as users_count,
    -- Day 0 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 0 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day0_revenue,
    -- Day 1 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 1 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day1_revenue,
    -- Day 2 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 2 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day2_revenue,
    -- Day 3 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 3 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day3_revenue,
    -- Day 4 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 4 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day4_revenue,
    -- Day 5 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 5 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day5_revenue,
    -- Day 6 Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 6 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day6_revenue,

    -- Cumulative Revenue
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 2 THEN COALESCE(p.purchase, 0) ELSE 0 END) as cumulative_rev_3,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 6 THEN COALESCE(p.purchase, 0) ELSE 0 END) as cumulative_rev_7,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 13 THEN COALESCE(p.purchase, 0) ELSE 0 END) as cumulative_rev_14,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 29 THEN COALESCE(p.purchase, 0) ELSE 0 END) as cumulative_rev_30,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 89 THEN COALESCE(p.purchase, 0) ELSE 0 END) as cumulative_rev_90,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 149 THEN COALESCE(p.purchase, 0) ELSE 0 END) as cumulative_rev_150,

    -- LTV (Cumulative Revenue / Users Count)
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 2 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv_3,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 6 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv_7,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 13 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv_14,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 29 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv_30,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 89 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv_90,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') <= 149 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv_150

FROM target_cohort_exploded t
LEFT JOIN dm_platform.daily_lcx_user_info p 
    ON t.lcm_id = p.lcm_id 
    AND p.app_id = 63002013
    AND p.day >= t.cohort_date
GROUP BY t.cohort_date, t.country_group, t.user_type
ORDER BY t.cohort_date, t.country_group, t.user_type;
