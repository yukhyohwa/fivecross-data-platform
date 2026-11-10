/*
================================================================================
项目    : 蜡笔小新 - TC 繁体大区 OBT
表名    : ta.v_event_18 / user_result_cluster_18 /
          ta_dim.ta_exchange / ta_dim.dim_18_0_52801
描述    : 按商品统计充值人数、订单数和 USD 收入，账号口径使用 fc_id。

口径：
1. 统计时间直接使用 ${PartDate:date1}，不关联注册事件，不额外限定开服日期。
2. 同一 fc_id 的多个角色合并为一个付费账号。
3. 充值黑名单为 is_water_new、is_windows_new，账号字段使用 #varchar_id。
4. 排除 sandbox 和 is_freebuy 订单。
5. 输出字段名称及顺序保持原 SQL 不变。
================================================================================
*/
WITH
UserBlacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_water_new', 'is_windows_new')
      AND NULLIF(TRIM(CAST("#varchar_id" AS VARCHAR)), '') IS NOT NULL
),

ChargeData AS (
    SELECT
        v."$part_date",
        TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
        v.product_id,
        v.pay_currency,
        CAST(v.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1) AS pay_amount_usd
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist b
        ON TRIM(CAST(v.fc_id AS VARCHAR)) = b.fc_id
    LEFT JOIN ta_dim.ta_exchange s5
        ON v."$part_date" = s5.ex_date
       AND v.pay_currency = s5.currency
    WHERE v.${PartDate:date1}
      AND v."$part_event" = 'charge'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)), '') IS NOT NULL
      AND b.fc_id IS NULL
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
)

SELECT
    ${Selector:timetype} AS time_dimension,
    s1.product_id,
    dp."product_id@product_name_tc" AS product_name,
    dp."product_id@product_type" AS product_category,
    COUNT(DISTINCT s1.fc_id) AS pu,
    COUNT(1) AS buy_count,
    SUM(COALESCE(s1.pay_amount_usd, 0)) AS revenue_usd,
    CONCAT(MIN(s1."$part_date"), ' - ', MAX(s1."$part_date")) AS date_range
FROM ChargeData s1
LEFT JOIN ta_dim.dim_18_0_52801 dp
    ON CAST(s1.product_id AS INTEGER) = CAST(dp."product_id@product_id" AS INTEGER)
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC;
