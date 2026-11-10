WITH 
AccountMetrics AS (
    SELECT "#user_id", os
    FROM ta.v_event_13
    WHERE "$part_date" >= '2026-02-01' 
      AND "$part_event" = 'new_role'
)

SELECT 
    am.os, 
    COUNT(DISTINCT am."#user_id") AS au
FROM AccountMetrics am 
GROUP BY 1
ORDER BY 2 DESC
