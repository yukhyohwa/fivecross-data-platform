/* 街篮 JP / TA project 5 / Trino
看板一：指定登录区间用户的注册月份分布（最老月份优先）。
参数：${PartDate:login_date}，完整日期区间条件，仅筛选 login。
用户粒度：#user_id；注册日期：历史 register 事件的最早分区日期。
不以首登代替注册；未匹配 register 的用户单列“注册记录缺失”，置末。
注册事件已核验存在，历史可见起点 2021-09-29；更早/未上报记录不能推断。
不套用其他项目的黑名单。比例为 0~1 数值，请在看板设为百分比。
*/
WITH LoginUsers AS (
    SELECT DISTINCT v."#user_id" AS user_id
    FROM ta.v_event_5 v
    WHERE v."$part_event" = 'login'
      AND v.${PartDate:login_date}
      AND v."#user_id" IS NOT NULL
),
Registration AS (
    SELECT v."#user_id" AS user_id,
           MIN(CAST(v."$part_date" AS DATE)) AS registration_date
    FROM ta.v_event_5 v
    INNER JOIN LoginUsers u ON v."#user_id" = u.user_id
    WHERE v."$part_event" = 'register'
    GROUP BY 1
),
MonthlyUsers AS (
    SELECT DATE_TRUNC('month', r.registration_date) AS registration_month,
           COUNT(*) AS users
    FROM LoginUsers u
    LEFT JOIN Registration r ON u.user_id = r.user_id
    GROUP BY 1
)
SELECT COALESCE(SUBSTR(CAST(registration_month AS VARCHAR), 1, 7), '注册记录缺失') AS "注册月份",
       users AS "用户数",
       CAST(users AS DOUBLE) / NULLIF(SUM(users) OVER (), 0) AS "用户占比"
FROM MonthlyUsers
ORDER BY registration_month ASC NULLS LAST;
