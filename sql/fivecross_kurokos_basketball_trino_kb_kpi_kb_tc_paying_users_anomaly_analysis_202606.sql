/*
================================================================================
Game: Kuroko's Basketball (黑子的籃球)
Region: TC (Traditional Chinese / TW)
Description: 針對 2026-06-13 與 2026-06-19 兩日 ARPPU 偏高進行異常分析的 SQL 模板。
             1. 查詢這兩天付費玩家的組成比例與付費概況 (新用戶、回歸用戶、常規老用戶)
             2. 查詢這兩天的主要付費玩家 (大課玩家/鯨魚用戶) 清單、其登入狀態與儲值金額
             3. 查詢這兩天主要付費玩家所購買的商品品項、金額與訂單數
================================================================================
*/

-- ================================================================================
-- Query 1: 這兩天付費玩家的登入狀況與大盤付費概況 (新用戶 vs 回歸用戶 vs 老用戶)
-- ================================================================================
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

product_prices AS (
    -- 獲取實體貨幣的商品價格映射，用於虛擬貨幣 kuroko_pay 的流水估值
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) as rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND "$part_date" BETWEEN '2026-05-01' AND '2026-06-22'
),

PayingRecords AS (
    -- 提取兩天內所有的真實儲值記錄
    SELECT 
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id,
        evt.cfg_id AS product_id,
        CASE 
            WHEN evt.pay_currency IN ('kuroko_pay') THEN COALESCE(pp.pay_amount, 0.0) / COALESCE(ex_pp.exchange, 1.0)
            ELSE evt.pay_amount / COALESCE(ex.exchange, 1.0) 
        END AS revenue_usd
    FROM ta.v_event_10 AS evt
    LEFT JOIN ta_dim.ta_exchange AS ex
        ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
    -- 關聯商品參考價格 (虛擬幣轉 USD)
    LEFT JOIN product_prices pp 
        ON evt.cfg_id = pp.cfg_id AND pp.rnk = 1
    LEFT JOIN ta_dim.ta_exchange AS ex_pp 
        ON pp.pay_currency = ex_pp.currency AND evt."$part_date" = ex_pp.ex_date
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt."#user_id" NOT IN (SELECT user_id FROM FinalBlacklist)
),

UniquePayingUsers AS (
    SELECT DISTINCT user_id FROM PayingRecords
),

UserRegDate AS (
    -- 計算付費玩家的註冊日期 (系統內首次登入日)
    SELECT 
        l."#user_id" AS user_id,
        MIN(CAST(l."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10 l
    INNER JOIN UniquePayingUsers u ON l."#user_id" = u.user_id
    WHERE l."$part_event" = 'login'
    GROUP BY 1
),

PriorLogins AS (
    -- 計算付費玩家在目標日期前 30 天內的登入天數
    SELECT 
        u.user_id,
        d.target_date,
        COUNT(DISTINCT l."$part_date") AS login_days_30d_prior
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN ta.v_event_10 l ON u.user_id = l."#user_id"
        AND l."$part_event" = 'login'
        AND CAST(l."$part_date" AS DATE) BETWEEN DATE_ADD('day', -30, d.target_date) AND DATE_ADD('day', -1, d.target_date)
    GROUP BY 1, 2
),

UserStatus AS (
    -- 定義玩家登入狀態：
    -- 1. 新用戶 (New User)：註冊日期等於儲值當天
    -- 2. 回歸用戶 (Return User)：註冊日期在儲值前，且前 30 天無登入記錄
    -- 3. 老用戶 (Regular User)：註冊日期在儲值前，且前 30 天有登入記錄
    SELECT 
        u.user_id,
        d.target_date,
        r.reg_date,
        COALESCE(pl.login_days_30d_prior, 0) AS login_days_30d_prior,
        CASE 
            WHEN r.reg_date = d.target_date THEN 'New User (新用戶)'
            WHEN r.reg_date < d.target_date AND COALESCE(pl.login_days_30d_prior, 0) = 0 THEN 'Return User (回歸用戶)'
            ELSE 'Regular User (老用戶)'
        END AS user_type
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN UserRegDate r ON u.user_id = r.user_id
    LEFT JOIN PriorLogins pl ON u.user_id = pl.user_id AND d.target_date = pl.target_date
)

SELECT 
    p.part_date AS "日期",
    s.user_type AS "用戶登入狀況",
    COUNT(DISTINCT p.user_id) AS "付費人數",
    COUNT(1) AS "訂單總數",
    ROUND(SUM(p.revenue_usd), 2) AS "總流水/USD",
    ROUND(SUM(p.revenue_usd) / NULLIF(COUNT(DISTINCT p.user_id), 0), 2) AS "ARPPU/USD"
FROM PayingRecords p
LEFT JOIN UserStatus s ON p.user_id = s.user_id AND CAST(p.part_date AS DATE) = s.target_date
GROUP BY 1, 2
ORDER BY 1 ASC, "總流水/USD" DESC;


-- ================================================================================
-- Query 2: 目標日期主要的付費玩家清單 (Top Paying Players) 及其登入狀態
-- ================================================================================
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

product_prices AS (
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) as rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND "$part_date" BETWEEN '2026-05-01' AND '2026-06-22'
),

PayingRecords AS (
    SELECT 
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id,
        evt."gid" AS role_id,
        evt.cfg_id AS product_id,
        CASE 
            WHEN evt.pay_currency IN ('kuroko_pay') THEN COALESCE(pp.pay_amount, 0.0) / COALESCE(ex_pp.exchange, 1.0)
            ELSE evt.pay_amount / COALESCE(ex.exchange, 1.0) 
        END AS revenue_usd
    FROM ta.v_event_10 AS evt
    LEFT JOIN ta_dim.ta_exchange AS ex
        ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
    LEFT JOIN product_prices pp 
        ON evt.cfg_id = pp.cfg_id AND pp.rnk = 1
    LEFT JOIN ta_dim.ta_exchange AS ex_pp 
        ON pp.pay_currency = ex_pp.currency AND evt."$part_date" = ex_pp.ex_date
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt."#user_id" NOT IN (SELECT user_id FROM FinalBlacklist)
),

UniquePayingUsers AS (
    SELECT DISTINCT user_id FROM PayingRecords
),

UserRegDate AS (
    SELECT 
        l."#user_id" AS user_id,
        MIN(CAST(l."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10 l
    INNER JOIN UniquePayingUsers u ON l."#user_id" = u.user_id
    WHERE l."$part_event" = 'login'
    GROUP BY 1
),

PriorLogins AS (
    SELECT 
        u.user_id,
        d.target_date,
        COUNT(DISTINCT l."$part_date") AS login_days_30d_prior
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN ta.v_event_10 l ON u.user_id = l."#user_id"
        AND l."$part_event" = 'login'
        AND CAST(l."$part_date" AS DATE) BETWEEN DATE_ADD('day', -30, d.target_date) AND DATE_ADD('day', -1, d.target_date)
    GROUP BY 1, 2
),

UserStatus AS (
    SELECT 
        u.user_id,
        d.target_date,
        r.reg_date,
        COALESCE(pl.login_days_30d_prior, 0) AS login_days_30d_prior,
        CASE 
            WHEN r.reg_date = d.target_date THEN 'New User (新用戶)'
            WHEN r.reg_date < d.target_date AND COALESCE(pl.login_days_30d_prior, 0) = 0 THEN 'Return User (回歸用戶)'
            ELSE 'Regular User (老用戶)'
        END AS user_type
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN UserRegDate r ON u.user_id = r.user_id
    LEFT JOIN PriorLogins pl ON u.user_id = pl.user_id AND d.target_date = pl.target_date
)

SELECT 
    p.part_date AS "日期",
    CAST(p.user_id AS VARCHAR)||'a' AS "玩家ID",
    s.user_type AS "用戶登入狀況",
    CAST(s.reg_date AS VARCHAR) AS "註冊日期",
    s.login_days_30d_prior AS "儲值前30天登入天數",
    COUNT(1) AS "訂單數量",
    ROUND(SUM(p.revenue_usd), 2) AS "儲值金額/USD",
    MAX(role_id) role_id
FROM PayingRecords p
LEFT JOIN UserStatus s ON p.user_id = s.user_id AND CAST(p.part_date AS DATE) = s.target_date
GROUP BY 1, 2, 3, 4, 5
HAVING SUM(p.revenue_usd) >= 50.0  -- 可根據需要篩選高額付費玩家的閾值 (例如 >= 50 USD)
ORDER BY 1 ASC, "儲值金額/USD" DESC;


-- ================================================================================
-- Query 3: 付費玩家在這些日期購買的商品品項與金額詳情
-- ================================================================================
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

product_prices AS (
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) as rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND "$part_date" BETWEEN '2026-05-01' AND '2026-06-22'
),

PayingRecords AS (
    SELECT 
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id,
        evt.cfg_id AS product_id,
        dim."cfg_id@name" AS product_name,
        CASE 
            WHEN evt.pay_currency IN ('kuroko_pay') THEN COALESCE(pp.pay_amount, 0.0) / COALESCE(ex_pp.exchange, 1.0)
            ELSE evt.pay_amount / COALESCE(ex.exchange, 1.0) 
        END AS revenue_usd
    FROM ta.v_event_10 AS evt
    LEFT JOIN ta_dim.dim_10_0_12842 AS dim
        ON evt.cfg_id = dim."cfg_id@shop_item_id"
    LEFT JOIN ta_dim.ta_exchange AS ex
        ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
    LEFT JOIN product_prices pp 
        ON evt.cfg_id = pp.cfg_id AND pp.rnk = 1
    LEFT JOIN ta_dim.ta_exchange AS ex_pp 
        ON pp.pay_currency = ex_pp.currency AND evt."$part_date" = ex_pp.ex_date
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt."#user_id" NOT IN (SELECT user_id FROM FinalBlacklist)
),

UniquePayingUsers AS (
    SELECT DISTINCT user_id FROM PayingRecords
),

UserRegDate AS (
    SELECT 
        l."#user_id" AS user_id,
        MIN(CAST(l."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10 l
    INNER JOIN UniquePayingUsers u ON l."#user_id" = u.user_id
    WHERE l."$part_event" = 'login'
    GROUP BY 1
),

PriorLogins AS (
    SELECT 
        u.user_id,
        d.target_date,
        COUNT(DISTINCT l."$part_date") AS login_days_30d_prior
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN ta.v_event_10 l ON u.user_id = l."#user_id"
        AND l."$part_event" = 'login'
        AND CAST(l."$part_date" AS DATE) BETWEEN DATE_ADD('day', -30, d.target_date) AND DATE_ADD('day', -1, d.target_date)
    GROUP BY 1, 2
),

UserStatus AS (
    SELECT 
        u.user_id,
        d.target_date,
        r.reg_date,
        CASE 
            WHEN r.reg_date = d.target_date THEN 'New User (新用戶)'
            WHEN r.reg_date < d.target_date AND COALESCE(pl.login_days_30d_prior, 0) = 0 THEN 'Return User (回歸用戶)'
            ELSE 'Regular User (老用戶)'
        END AS user_type
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN UserRegDate r ON u.user_id = r.user_id
    LEFT JOIN PriorLogins pl ON u.user_id = pl.user_id AND d.target_date = pl.target_date
)

SELECT 
    p.part_date AS "日期",
    s.user_type AS "用戶登入狀況",
    p.product_id AS "商品ID",
    p.product_name AS "商品名稱",
    COUNT(DISTINCT p.user_id) AS "購買人數",
    COUNT(1) AS "訂單數量",
    ROUND(SUM(p.revenue_usd), 2) AS "銷售總額/USD"
FROM PayingRecords p
LEFT JOIN UserStatus s ON p.user_id = s.user_id AND CAST(p.part_date AS DATE) = s.target_date
GROUP BY 1, 2, 3, 4
ORDER BY 1 ASC, "銷售總額/USD" DESC;


-- ================================================================================
-- Query 4: 這兩天的付費玩家，其點券消耗購買了什麼 (按商品與用戶狀況聚合)
-- ================================================================================
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

product_prices AS (
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) as rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND "$part_date" BETWEEN '2026-05-01' AND '2026-06-22'
),

PayingRecords AS (
    SELECT DISTINCT
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id
    FROM ta.v_event_10 AS evt
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt."#user_id" NOT IN (SELECT user_id FROM FinalBlacklist)
),

UniquePayingUsers AS (
    SELECT DISTINCT user_id FROM PayingRecords
),

UserRegDate AS (
    SELECT 
        l."#user_id" AS user_id,
        MIN(CAST(l."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10 l
    INNER JOIN UniquePayingUsers u ON l."#user_id" = u.user_id
    WHERE l."$part_event" = 'login'
    GROUP BY 1
),

PriorLogins AS (
    SELECT 
        u.user_id,
        d.target_date,
        COUNT(DISTINCT l."$part_date") AS login_days_30d_prior
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN ta.v_event_10 l ON u.user_id = l."#user_id"
        AND l."$part_event" = 'login'
        AND CAST(l."$part_date" AS DATE) BETWEEN DATE_ADD('day', -30, d.target_date) AND DATE_ADD('day', -1, d.target_date)
    GROUP BY 1, 2
),

UserStatus AS (
    SELECT 
        u.user_id,
        d.target_date,
        r.reg_date,
        CASE 
            WHEN r.reg_date = d.target_date THEN 'New User (新用戶)'
            WHEN r.reg_date < d.target_date AND COALESCE(pl.login_days_30d_prior, 0) = 0 THEN 'Return User (回歸用戶)'
            ELSE 'Regular User (老用戶)'
        END AS user_type
    FROM UniquePayingUsers u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN UserRegDate r ON u.user_id = r.user_id
    LEFT JOIN PriorLogins pl ON u.user_id = pl.user_id AND d.target_date = pl.target_date
),

StampsEvents AS (
    SELECT 
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id,
        evt.gid,
        evt.role_name,
        evt.a_rst,
        ABS(
            REDUCE(
                FILTER(evt.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS stamps_consumed
    FROM ta.v_event_10 evt
    -- 僅篩選這兩天的付費玩家在當天的消耗
    INNER JOIN PayingRecords p 
        ON evt."#user_id" = p.user_id AND evt."$part_date" = p.part_date
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND ANY_MATCH(evt.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0)
),

ItemsObtained AS (
    SELECT 
        part_date,
        user_id,
        gid,
        role_name,
        stamps_consumed,
        t.item_id AS obtained_item_id,
        t.item_diff AS obtained_amount
    FROM StampsEvents
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE CAST(t.item_id AS INTEGER) NOT IN (10000000, 19000000)
        AND t.item_diff > 0
)

SELECT 
    s1.part_date AS "日期",
    s.user_type AS "用戶登入狀況",
    s1.obtained_item_id AS "消耗點券獲得商品ID",
    s2."shop_item.item_id@name" AS "商品名稱",
    SUM(s1.obtained_amount) AS "獲得總量",
    SUM(s1.stamps_consumed) AS "消耗點券總數",
    COUNT(DISTINCT s1.user_id) AS "付費玩家消耗人數"
FROM ItemsObtained s1
LEFT JOIN UserStatus s 
    ON s1.user_id = s.user_id AND CAST(s1.part_date AS DATE) = s.target_date
LEFT JOIN ta_dim.dim_10_0_12928 s2 
    ON s1.obtained_item_id = s2."shop_item.item_id@shop_item_id"
GROUP BY 1, 2, 3, 4
ORDER BY 1 ASC, "消耗點券總數" DESC;


-- ================================================================================
-- Query 5: 這兩天大額付費玩家個別的點券消耗明細 (Top Spenders' Stamps Consumption Details)
-- ================================================================================
WITH FinalBlacklist AS (
    SELECT DISTINCT "#user_id" AS user_id
    FROM user_result_cluster_10
    WHERE cluster_name IN ('cohort_20231116_224917', 'cohort_waternew')
),

product_prices AS (
    SELECT 
        cfg_id,
        pay_amount,
        pay_currency,
        ROW_NUMBER() OVER (PARTITION BY cfg_id ORDER BY pay_amount DESC) as rnk
    FROM ta.v_event_10
    WHERE "$part_event" = 'charge'
      AND pay_currency NOT IN ('COIN', 'kuroko_pay')
      AND (sandbox = FALSE OR sandbox IS NULL)
      AND "$part_date" BETWEEN '2026-05-01' AND '2026-06-22'
),

PayingRecords AS (
    SELECT 
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id,
        CASE 
            WHEN evt.pay_currency IN ('kuroko_pay') THEN COALESCE(pp.pay_amount, 0.0) / COALESCE(ex_pp.exchange, 1.0)
            ELSE evt.pay_amount / COALESCE(ex.exchange, 1.0) 
        END AS revenue_usd
    FROM ta.v_event_10 AS evt
    LEFT JOIN ta_dim.ta_exchange AS ex
        ON evt.pay_currency = ex.currency AND evt."$part_date" = ex.ex_date
    LEFT JOIN product_prices pp 
        ON evt.cfg_id = pp.cfg_id AND pp.rnk = 1
    LEFT JOIN ta_dim.ta_exchange AS ex_pp 
        ON pp.pay_currency = ex_pp.currency AND evt."$part_date" = ex_pp.ex_date
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND evt."$part_event" = 'charge'
      AND (evt.sandbox = FALSE OR evt.sandbox IS NULL)
      AND (evt.order_id NOT IN ('11') OR evt.order_id IS NULL)
      AND evt.pay_currency <> 'COIN'
      AND evt."#user_id" NOT IN (SELECT user_id FROM FinalBlacklist)
),

TopPayingUsers AS (
    -- 獲取這兩天內儲值 >= 50 USD 的大額付費玩家
    SELECT 
        part_date,
        user_id,
        SUM(revenue_usd) AS total_charge_usd
    FROM PayingRecords
    GROUP BY 1, 2
    HAVING SUM(revenue_usd) >= 50.0
),

UserRegDate AS (
    SELECT 
        l."#user_id" AS user_id,
        MIN(CAST(l."$part_date" AS DATE)) AS reg_date
    FROM ta.v_event_10 l
    INNER JOIN (SELECT DISTINCT user_id FROM TopPayingUsers) u ON l."#user_id" = u.user_id
    WHERE l."$part_event" = 'login'
    GROUP BY 1
),

PriorLogins AS (
    SELECT 
        u.user_id,
        d.target_date,
        COUNT(DISTINCT l."$part_date") AS login_days_30d_prior
    FROM (SELECT DISTINCT user_id FROM TopPayingUsers) u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN ta.v_event_10 l ON u.user_id = l."#user_id"
        AND l."$part_event" = 'login'
        AND CAST(l."$part_date" AS DATE) BETWEEN DATE_ADD('day', -30, d.target_date) AND DATE_ADD('day', -1, d.target_date)
    GROUP BY 1, 2
),

UserStatus AS (
    SELECT 
        u.user_id,
        d.target_date,
        r.reg_date,
        CASE 
            WHEN r.reg_date = d.target_date THEN 'New User (新用戶)'
            WHEN r.reg_date < d.target_date AND COALESCE(pl.login_days_30d_prior, 0) = 0 THEN 'Return User (回歸用戶)'
            ELSE 'Regular User (老用戶)'
        END AS user_type
    FROM (SELECT DISTINCT user_id FROM TopPayingUsers) u
    CROSS JOIN (
        SELECT DATE '2026-06-13' AS target_date UNION ALL
        SELECT DATE '2026-06-19' AS target_date
    ) d
    LEFT JOIN UserRegDate r ON u.user_id = r.user_id
    LEFT JOIN PriorLogins pl ON u.user_id = pl.user_id AND d.target_date = pl.target_date
),

StampsEvents AS (
    SELECT 
        evt."$part_date" AS part_date,
        evt."#user_id" AS user_id,
        evt.gid,
        evt.role_name,
        evt.a_rst,
        ABS(
            REDUCE(
                FILTER(evt.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0),
                0.0,
                (s, x) -> s + x.diff,
                s -> s
            )
        ) AS stamps_consumed
    FROM ta.v_event_10 evt
    INNER JOIN TopPayingUsers t 
        ON evt."#user_id" = t.user_id AND evt."$part_date" = t.part_date
    WHERE evt."$part_date" IN ('2026-06-13', '2026-06-19')
      AND ANY_MATCH(evt.a_rst, x -> CAST(x.id AS INTEGER) IN (10000000, 19000000) AND x.diff < 0)
),

ItemsObtained AS (
    SELECT 
        part_date,
        user_id,
        gid,
        role_name,
        stamps_consumed,
        t.item_id AS obtained_item_id,
        t.item_diff AS obtained_amount
    FROM StampsEvents
    CROSS JOIN UNNEST(a_rst) AS t(item_id, item_before, item_diff, item_after, item_key)
    WHERE CAST(t.item_id AS INTEGER) NOT IN (10000000, 19000000)
        AND t.item_diff > 0
)

SELECT 
    s1.part_date AS "日期",
    CAST(s1.user_id AS VARCHAR)||'a' AS "玩家ID",
    s1.role_name AS "角色名稱",
    s.user_type AS "用戶登入狀況",
    ROUND(t.total_charge_usd, 2) AS "當日儲值金額/USD",
    s1.obtained_item_id AS "消耗點券獲得商品ID",
    s2."shop_item.item_id@name" AS "商品名稱",
    s1.obtained_amount AS "獲得數量",
    s1.stamps_consumed AS "消耗點券數量"
FROM ItemsObtained s1
INNER JOIN TopPayingUsers t 
    ON s1.user_id = t.user_id AND s1.part_date = t.part_date
LEFT JOIN UserStatus s 
    ON s1.user_id = s.user_id AND CAST(s1.part_date AS DATE) = s.target_date
LEFT JOIN ta_dim.dim_10_0_12928 s2 
    ON s1.obtained_item_id = s2."shop_item.item_id@shop_item_id"
ORDER BY s1.part_date ASC, t.total_charge_usd DESC, s1.stamps_consumed DESC;

