/*
================================================================================
项目    : 蜡笔小新 (Crayon Shin-chan) - TC 繁体大区
表名    : ta.v_event_18, user_result_cluster_18
描述    : 游乐园活动 道具(430002)消耗与兑换获得道具统计 (按游乐园礼包专属付费档位拆分)
修正点  : 
  1. 不限制国家/地区 (无需过滤新加坡)，涵盖繁体大区所有有效用户
  2. pay_amount_usd 为空值，采用 CAST(v.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1) 关联 ta_dim.ta_exchange 计算 USD 流水
  3. 道具维表调整为繁体大区维表 ta_dim.dim_18_0_18269
================================================================================
*/

WITH UserBlacklist AS (
    SELECT DISTINCT "#user_id"
    FROM user_result_cluster_18
    WHERE cluster_name IN ('is_windows', 'internal_users', 'is_water')
),

-- 1. 繁体大区全量有效用户 (排除黑名单/水号)
ValidUsers AS (
    SELECT DISTINCT v."#user_id"
    FROM ta.v_event_18 v
    LEFT JOIN UserBlacklist ub ON v."#user_id" = ub."#user_id"
    WHERE ub."#user_id" IS NULL
),

-- 2. 计算“游乐园礼包”专属的累计充值 (使用 ta_exchange 动态换算 USD)
ParkRecharge AS (
    SELECT 
        v."#user_id",
        SUM(CAST(v.pay_amount AS DOUBLE) / COALESCE(s5.exchange, 1)) AS total_revenue_usd
    FROM ta.v_event_18 v
    INNER JOIN ValidUsers vu ON v."#user_id" = vu."#user_id"
    LEFT JOIN ta_dim.ta_exchange s5 
        ON v."$part_date" = s5.ex_date 
       AND v.pay_currency = s5.currency
    WHERE v."$part_event" = 'charge'
      AND (v.sandbox IS NULL OR v.sandbox = FALSE)
      AND (v.is_freebuy IS NULL OR v.is_freebuy = FALSE)
      -- 仅看游乐园礼包 product_id
      AND CAST(v.product_id AS BIGINT) IN (119201, 119202, 119203, 119204, 119205, 119206)
    GROUP BY 1
),

-- 3. 给有效账户打上专属充值档位标签
ValidUsersWithTier AS (
    SELECT 
        v."#user_id",
        CASE 
            WHEN COALESCE(r.total_revenue_usd, 0) = 0 THEN '0.免费用户'
            WHEN r.total_revenue_usd <= 10 THEN 'a.(0,10]'
            WHEN r.total_revenue_usd <= 50 THEN 'b.(10,50]'
            WHEN r.total_revenue_usd <= 100 THEN 'c.(50,100]'
            WHEN r.total_revenue_usd <= 300 THEN 'd.(100,300]'
            ELSE 'e.(300,∞]'
        END AS recharge_tier
    FROM ValidUsers v
    LEFT JOIN ParkRecharge r ON v."#user_id" = r."#user_id"
),

-- 4. 提取发生了 430002 消耗的事件
ConsumeEvents AS (
    SELECT 
        v."$part_date",
        vt.recharge_tier,
        v."#account_id",
        CAST(TO_UNIXTIME(CAST(v."#event_time" AS TIMESTAMP(3))) AS BIGINT) AS event_time,
        ABS(v.a_rst[1].diff) AS coumsue_nums
    FROM ta.v_event_18 v
    INNER JOIN ValidUsersWithTier vt ON v."#user_id" = vt."#user_id"
    WHERE v."$part_event" = 'item_change'
      AND v.${PartDate:date1}
      -- 找到本次事件中确实消耗了 430002 的记录
      AND ANY_MATCH(v.a_rst, x -> CAST(x.id AS BIGINT) = 430002 AND CAST(x.before AS BIGINT) > CAST(x.after AS BIGINT))
),

-- 5. 提取同次事件中兑换获得的具体道具
GainedItems AS (
    SELECT 
        v."$part_date",
        vt.recharge_tier,
        v."#account_id",
        CAST(TO_UNIXTIME(CAST(v."#event_time" AS TIMESTAMP(3))) AS BIGINT) AS event_time,
        v.a_rst[1].id AS gained_item_id,
        v.a_rst[1].diff AS gained_amount
    FROM ta.v_event_18 v
    INNER JOIN ValidUsersWithTier vt ON v."#user_id" = vt."#user_id"
    WHERE v."$part_event" = 'item_change'
      AND v.${PartDate:date1}
      AND CAST(v.a_rst[1].id AS BIGINT) <> 430002
)

-- 6. 报表汇总输出
SELECT 
    ce."$part_date" AS "日期",
    ce.recharge_tier AS "游乐园专属付费档位",
    COALESCE(dim."item_id@item_name", CAST(CAST(ga.gained_item_id AS INTEGER) AS VARCHAR)) AS "兑换获得的道具名称",
    COUNT(DISTINCT ce."#account_id") AS "兑换人数",
    SUM(ce.coumsue_nums) AS "消耗道具总数"
FROM ConsumeEvents ce
INNER JOIN GainedItems ga
    ON ce."$part_date" = ga."$part_date"
   AND ce."#account_id" = ga."#account_id"
   AND ce.event_time = ga.event_time
LEFT JOIN ta_dim.dim_18_0_18269 dim
    ON CAST(CAST(ga.gained_item_id AS INTEGER) AS VARCHAR) = CAST(CAST(dim."item_id@item_id" AS INTEGER) AS VARCHAR)
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 5 DESC;
