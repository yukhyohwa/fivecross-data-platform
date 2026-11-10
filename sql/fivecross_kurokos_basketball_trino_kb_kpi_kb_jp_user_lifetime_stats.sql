/* 
================================================================================
修正后的查询
================================================================================
*/

WITH account_stats AS (
    SELECT 
        s1."#account_id",
        MAX_BY(s1."#user_id", s1."#event_time") AS "#user_id",
        MAX_BY(CAST(s1.role_name AS VARCHAR), CASE WHEN s1.role_name IS NOT NULL AND CAST(s1.role_name AS VARCHAR) <> '' THEN s1."#event_time" ELSE NULL END) AS role_name,
        MAX_BY(CAST(s1.level AS INTEGER), CASE WHEN s1.level IS NOT NULL THEN s1."#event_time" ELSE NULL END) AS role_level,
        MAX(CAST(s1."$part_date" AS DATE)) AS last_active_date,
        SUM(
            CASE 
                WHEN s1."$part_event" = 'charge' 
                 AND (s1.sandbox = false OR s1.sandbox IS NULL) 
                 AND (s1.order_id NOT IN ('11') OR s1.order_id IS NULL) 
                THEN CAST(s1.pay_amount AS DOUBLE) / COALESCE(ex.exchange, 1)
                ELSE 0.0 
            END
        ) AS total_pay_amount
    FROM ta.v_event_9 s1
    LEFT JOIN (
        SELECT ex_date, currency, ANY_VALUE(exchange) as exchange 
        FROM ta_dim.ta_exchange 
        GROUP BY 1, 2
    ) ex ON s1."$part_date" = ex.ex_date AND s1.pay_currency = ex.currency
    WHERE s1."$part_event" IN ('login', 'new_role', 'charge', 'change_name')
      AND s1."#account_id" IS NOT NULL AND s1."#account_id" <> ''
    GROUP BY s1."#account_id"
)

SELECT 
    "#user_id" AS "用户ID(#user_id)",
    "#account_id" AS "角色ID(#account_id)",
    role_name AS "昵称(role_name)",
    DATE_DIFF('day', last_active_date, CURRENT_DATE) AS "至今未登录天数",
    COALESCE(total_pay_amount, 0) AS "氪金金额",
    role_level AS "角色等级(level)"
FROM account_stats
-- 核心修正：删除了多余的 DATE_DIFF 孤立项
WHERE DATE_DIFF('day', last_active_date, CURRENT_DATE) ${Number:number1}  -- 例如 BETWEEN 7 AND 12
  AND COALESCE(total_pay_amount, 0) ${Number:number2}                   -- 例如 BETWEEN 1000 AND 11111
  AND role_level ${Number:number3}                                      -- 例如 BETWEEN 14 AND 100
ORDER BY "氪金金额" DESC, "至今未登录天数" ASC;