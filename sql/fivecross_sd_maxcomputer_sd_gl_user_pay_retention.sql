-- Paying User Retention Analysis for New/Return Users (Jan 1-5, 2026)
-- Purpose: Track retention rates for new users and 90d-return users who made at least one purchase in Jan 2026+
-- Cohort Period: 2026-01-01 to 2026-01-05
-- Paying User Definition: Users with purchase > 0 at any time from Jan 2026 onwards
-- Metrics: Cohort Size, Day 1 to Day 30 Retention Rates (by user type)

WITH 
    user_log AS (
        SELECT 
            lcm_id, 
            day, 
            reg_day,
            purchase,
            -- Get the previous login day for the user
            LAG(day, 1) OVER (PARTITION BY lcm_id ORDER BY day) as last_login_day
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 63002013 
          AND day >= 20250601 -- Look back ~6 months to calculate gaps
          AND country_code IN ('TH','US','SG','AU','MY','CA')
    ),
    
    calculated_gap AS (
        SELECT
            lcm_id,
            day,
            last_login_day,
            reg_day,
            purchase,
            -- Calculate days since last login
            DATEDIFF(
                TO_DATE(CAST(day AS STRING), 'yyyymmdd'), 
                TO_DATE(CAST(last_login_day AS STRING), 'yyyymmdd'), 
                'dd'
            ) as days_since_last
        FROM user_log
    ),

    -- Define cohort: Users who are either new or returning after 90+ days during Jan 1-5, 2026
    target_cohort AS (
        SELECT 
            lcm_id,
            day as cohort_date,
            CASE 
                WHEN CAST(reg_day AS BIGINT) = CAST(day AS BIGINT) THEN 'New'
                ELSE 'Return_90d'
            END as specific_type
        FROM calculated_gap
        WHERE day BETWEEN 20260101 AND 20260105  -- Jan 1-5, 2026
          -- Condition: New User (NULL last login in window) OR Returning User (>90 days gap)
          AND (last_login_day IS NULL OR days_since_last > 90)
    ),
    
    -- Identify paying users: Users with at least one purchase from Jan 2026 onwards
    paying_users AS (
        SELECT DISTINCT
            lcm_id
        FROM dm_platform.daily_lcx_user_info
        WHERE app_id = 63002013
          AND day >= 20260101  -- Jan 2026 onwards
          AND purchase > 0
          AND country_code IN ('TH','US','SG','AU','MY','CA')
    ),
    
    -- Filter cohort to only include paying users
    paying_cohort AS (
        SELECT 
            t.lcm_id,
            t.cohort_date,
            t.specific_type
        FROM target_cohort t
        INNER JOIN paying_users p
            ON t.lcm_id = p.lcm_id
    ),

    -- Expand cohort to include Total, New, and Return_90d segments
    cohort_expanded AS (
        SELECT lcm_id, cohort_date, 'Total' as user_type FROM paying_cohort
        UNION ALL
        SELECT lcm_id, cohort_date, 'New' as user_type FROM paying_cohort WHERE specific_type = 'New'
        UNION ALL
        SELECT lcm_id, cohort_date, 'Return_90d' as user_type FROM paying_cohort WHERE specific_type = 'Return_90d'
    ),
    
    -- Get all activity for cohort users (up to 30 days after cohort date)
    user_activity AS (
        SELECT 
            t.lcm_id,
            t.cohort_date,
            t.user_type,
            u.day as activity_day
        FROM cohort_expanded t
        INNER JOIN dm_platform.daily_lcx_user_info u
            ON t.lcm_id = u.lcm_id
            AND u.app_id = 63002013
            AND u.day >= t.cohort_date
            -- Limit to 30 days after cohort date
            AND u.day <= CAST(
                to_char(
                    dateadd(to_date(cast(t.cohort_date as string),'yyyymmdd'), 30, 'dd'), 
                    'yyyymmdd'
                ) AS BIGINT
            )
    )

-- Final Output: Retention metrics by cohort date and user type (paying users only)
SELECT
    t.cohort_date,
    t.user_type,
    COUNT(DISTINCT t.lcm_id) as cohort_size,
    
    -- Day 1-7 Retention (Daily)
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 1 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day1,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 2 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day2,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 3 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day3,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 4 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day4,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 5 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day5,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 6 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day6,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 7 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day7,
    
    -- Day 14, 21, 30 Retention (Weekly milestones)
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 14 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day14,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 21 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day21,
    
    COUNT(DISTINCT CASE 
        WHEN DATEDIFF(
            TO_DATE(CAST(a.activity_day AS STRING), 'yyyymmdd'), 
            TO_DATE(CAST(t.cohort_date AS STRING), 'yyyymmdd'), 
            'dd'
        ) = 30 THEN t.lcm_id 
    END) * 1.0 / NULLIF(COUNT(DISTINCT t.lcm_id), 0) as retention_day30

FROM cohort_expanded t
LEFT JOIN user_activity a
    ON t.lcm_id = a.lcm_id
    AND t.cohort_date = a.cohort_date
    AND t.user_type = a.user_type
GROUP BY t.cohort_date, t.user_type
ORDER BY t.cohort_date, t.user_type;
