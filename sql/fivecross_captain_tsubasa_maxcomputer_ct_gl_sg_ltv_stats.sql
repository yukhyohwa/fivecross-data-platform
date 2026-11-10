--odps sql
--********************************************************************--
--author: Gemini
--create time: 2025-12-18
--description: This query calculates the 30-day and 90-day LTV for new users registering in a specific period.
--             Rewritten for MaxCompute (ODPS) SQL syntax.
--********************************************************************--

-- This query calculates the average Lifetime Value (LTV) for a cohort of new users on MaxCompute.
-- It has been rewritten to use a more direct join structure.

-- Step 1: Define the cohort of new users who registered in the specified period.
WITH NewUserCohort AS (
    SELECT DISTINCT
        lcm_id,
        day regday-- Keep as YYYYMMDD string for date calculations later
    FROM
        dm_platform.daily_lcx_user_info
    WHERE
        day BETWEEN '20231205' AND '20240105' -- Registration period
        AND country_code = 'SG'
        AND app_id = 65002005
        AND is_water = '不是水' 
        AND reg_day=day-- Filter out test/fake users
),

-- Step 2: Join the cohort with their daily activities and calculate revenue for each user.
UserLTV AS (
    SELECT
        cohort.lcm_id,
        -- Calculate 30-day revenue for each user using DATEDIFF for MaxCompute.
        SUM(
            CASE
                WHEN DATEDIFF(
                    TO_DATE(CONCAT(SUBSTR(daily.day, 1, 4), '-', SUBSTR(daily.day, 5, 2), '-', SUBSTR(daily.day, 7, 2))),
                    TO_DATE(CONCAT(SUBSTR(cohort.regday, 1, 4), '-', SUBSTR(cohort.regday, 5, 2), '-', SUBSTR(cohort.regday, 7, 2))),
                    'dd'
                ) BETWEEN 0 AND 29 THEN daily.purchase -- NOTE: 'purchase' is the assumed revenue column.
                ELSE 0
            END
        ) AS revenue_30d,
        -- Calculate 90-day revenue for each user.
        SUM(
            CASE
                WHEN DATEDIFF(
                    TO_DATE(CONCAT(SUBSTR(daily.day, 1, 4), '-', SUBSTR(daily.day, 5, 2), '-', SUBSTR(daily.day, 7, 2))),
                    TO_DATE(CONCAT(SUBSTR(cohort.regday, 1, 4), '-', SUBSTR(cohort.regday, 5, 2), '-', SUBSTR(cohort.regday, 7, 2))),
                    'dd'
                ) BETWEEN 0 AND 89 THEN daily.purchase
                ELSE 0
            END
        ) AS revenue_90d
    FROM
        NewUserCohort cohort
    LEFT JOIN
        dm_platform.daily_lcx_user_info daily
    ON
        cohort.lcm_id = daily.lcm_id
        -- We use a LEFT JOIN and filter the right table in the ON clause.
        -- This ensures all users from the cohort are kept, even those with no activity.
        AND daily.day >= '20231205'
        AND daily.country_code = 'SG'
        AND daily.app_id = 65002005
    GROUP BY
        cohort.lcm_id
)

-- Step 3: Calculate the final average LTV across all users in the cohort.
SELECT
    COUNT(lcm_id) AS new_users_count,
    AVG(revenue_30d) AS ltv_30,
    AVG(revenue_90d) AS ltv_90
FROM
    UserLTV;