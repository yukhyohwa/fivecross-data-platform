-- Calculate daily new users (new registrations + users inactive for >90 days) and their subsequent revenue (LTV)
-- Cohort Date: Daily
-- Metrics: Cohort Size, Day 0 to Day 6 Revenue (skipping Day 2 as requested)
-- Calculate daily new users (new registrations + users inactive for >90 days) and their subsequent revenue (LTV)
-- Cohort Date: Daily
-- Metrics: Cohort Size, Day 0 to Day 6 Revenue (skipping Day 2 as requested)

WITH 
    user_log AS (
        SELECT 
            lcm_id, 
            day, 
            purchase,
            reg_day,
            -- Get the previous login day for the user
            LAG(day, 1) OVER (PARTITION BY lcm_id ORDER BY day) as last_login_day
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 63002013 
          AND day >= 20250601 -- Look back ~6 months
          AND country_code IN ('TH','US','SG','AU','MY','CA')
    ),
    
    calculated_gap AS (
        SELECT
            lcm_id,
            day,
            purchase,
            last_login_day,
            reg_day,
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
            CASE 
                WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN 'New'
                ELSE 'Return_90d'
            END as specific_type
        FROM calculated_gap
        WHERE day >= 20260101
          -- Condition: New User (NULL last login in window) OR Returning User (>90 days gap)
          AND (last_login_day IS NULL OR days_since_last > 90)
    ),

    cohort_expanded AS (
        SELECT lcm_id, cohort_date, 'Total' as user_type FROM target_cohort
        UNION ALL
        SELECT lcm_id, cohort_date, 'New' as user_type FROM target_cohort WHERE specific_type = 'New'
        UNION ALL
        SELECT lcm_id, cohort_date, 'Return_90d' as user_type FROM target_cohort WHERE specific_type = 'Return_90d'
    )

SELECT
    t.cohort_date,
    t.user_type,
    COUNT(DISTINCT t.lcm_id) as cohort_size,
    
    -- LTV 1-7 (Cumulative Revenue per User)
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 0 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv1,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 1 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv2,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 2 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv3,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 3 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv4,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 4 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv5,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 5 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv6,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') BETWEEN 0 AND 6 THEN COALESCE(p.purchase, 0) ELSE 0 END) / COUNT(DISTINCT t.lcm_id) as ltv7,

    -- Retention 1-7 (Retention Rate)
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 1 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention1,
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 2 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention2,
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 3 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention3,
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 4 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention4,
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 5 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention5,
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 6 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention6,
    COUNT(DISTINCT CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 7 THEN t.lcm_id END) / COUNT(DISTINCT t.lcm_id) as retention7,

    -- Revenue Sums (Day 0 - Day 7)
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 0 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day0_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 1 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day1_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 2 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day2_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 3 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day3_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 4 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day4_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 5 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day5_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 6 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day6_revenue,
    SUM(CASE WHEN DATEDIFF(TO_DATE(CAST(p.day AS STRING), 'yyyymmdd'), TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 'dd') = 7 THEN COALESCE(p.purchase, 0) ELSE 0 END) as day7_revenue

FROM cohort_expanded t
LEFT JOIN dm_platform.daily_lcx_user_info p 
    ON t.lcm_id = p.lcm_id 
    AND p.app_id = 63002013
    AND p.day >= t.cohort_date
    -- Optimization: Limit join range to cover Day 7
    AND p.day <= CAST(to_char(dateadd(to_date(cast(t.cohort_date as string),'yyyymmdd'), 7, 'dd'), 'yyyymmdd') AS BIGINT)
GROUP BY t.cohort_date, t.user_type
ORDER BY t.cohort_date, t.user_type;
